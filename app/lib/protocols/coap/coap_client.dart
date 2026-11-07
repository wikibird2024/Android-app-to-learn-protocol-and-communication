import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../../core/log/session_log.dart';
import '../../core/transport/link.dart';
import 'coap_codec.dart';

/// CoAP request/response over a UDP link, with the RFC 7252 reliability
/// rules a UDP protocol must bring itself:
///
///   CON request ──▶   no ACK in 2 s? resend, wait 4 s, 8 s, 16 s (4 resends)
///   ◀── ACK + response ("piggybacked")
///   or ◀── empty ACK ... later ◀── CON response ──▶ we ACK it ("separate")
///   Observe: the server keeps sending notifications with the same token.
class CoapClient {
  CoapClient({required this.link, required this.log, Random? random, this.ackTimeout = const Duration(seconds: 2)})
    : _random = random ?? Random.secure() {
    _nextMessageId = _random.nextInt(0x10000);
    _subscription = link.incoming.listen(_onDatagram);
  }

  static const maxRetransmit = 4;

  final Link link;
  final SessionLog log;
  final Duration ackTimeout;
  final Random _random;
  late int _nextMessageId;
  late final StreamSubscription<Uint8List> _subscription;
  final _waitingAcks = <int, Completer<CoapMessage>>{};
  final _waitingTokens = <String, StreamController<CoapMessage>>{};

  String _key(Uint8List token) => token.join(',');

  int _takeMessageId() {
    final id = _nextMessageId;
    _nextMessageId = (_nextMessageId + 1) & 0xffff;
    return id;
  }

  Uint8List _newToken() => Uint8List.fromList(List.generate(4, (_) => _random.nextInt(256)));

  /// Sends a request; the stream gives the response (one item) or, with
  /// [observe], every notification until cancelled.
  Stream<CoapMessage> request({
    required int method,
    required String path,
    Uint8List? payload,
    int? contentFormat,
    bool confirmable = true,
    bool observe = false,
  }) {
    final token = _newToken();
    final key = _key(token);
    late final StreamController<CoapMessage> responses;
    responses = StreamController<CoapMessage>(onCancel: () => _waitingTokens.remove(key));
    _waitingTokens[key] = responses;
    final message = CoapMessage.request(
      method: method,
      path: path,
      messageId: _takeMessageId(),
      token: token,
      confirmable: confirmable,
      payload: payload,
      contentFormat: contentFormat,
      observe: observe,
    );
    unawaited(_sendReliably(message).catchError((Object error) {
      if (!responses.isClosed) {
        responses.addError(error);
        unawaited(responses.close());
      }
    }));
    return responses.stream;
  }

  Future<void> _send(CoapMessage message) async {
    final bytes = encodeCoap(message);
    log.sent(decodeCoap(bytes).frame);
    await link.send(bytes);
  }

  Future<void> _sendReliably(CoapMessage message) async {
    if (message.type != CoapType.confirmable) {
      await _send(message);
      return;
    }
    // Spec: first timeout is random in [ACK_TIMEOUT, 1.5 × ACK_TIMEOUT], so
    // many devices rebooting together do not resend in lockstep.
    var timeout = ackTimeout * (1 + _random.nextDouble() / 2);
    for (var attempt = 0; attempt <= maxRetransmit; attempt++) {
      final ack = _waitingAcks[message.messageId] = Completer<CoapMessage>();
      await _send(message);
      try {
        await ack.future.timeout(timeout);
        return;
      } on TimeoutException {
        if (attempt < maxRetransmit) log.note('no ACK for #${message.messageId} in ${timeout.inMilliseconds} ms, resending');
        timeout *= 2;
      } finally {
        _waitingAcks.remove(message.messageId);
      }
    }
    throw TimeoutException('no ACK after $maxRetransmit resends');
  }

  void _onDatagram(Uint8List bytes) {
    final decoded = decodeCoap(bytes);
    log.received(decoded.frame);
    final message = decoded.message;
    if (message == null) return;
    if (message.type == CoapType.acknowledgement || message.type == CoapType.reset) {
      _waitingAcks[message.messageId]?.complete(message);
    }
    if (message.type == CoapType.confirmable) {
      // Separate response or observe notification: we must ACK it.
      unawaited(_send(CoapMessage(type: CoapType.acknowledgement, code: 0, messageId: message.messageId, token: Uint8List(0))));
    }
    if (message.code == 0) return; // empty ACK: the response comes later
    final responses = _waitingTokens[_key(message.token)];
    if (responses == null || responses.isClosed) return;
    responses.add(message);
    final isObserving = message.options.any((option) => option.number == 6);
    if (!isObserving) {
      _waitingTokens.remove(_key(message.token));
      unawaited(responses.close());
    }
  }

  Future<void> close() async {
    for (final responses in _waitingTokens.values) {
      unawaited(responses.close());
    }
    _waitingTokens.clear();
    await _subscription.cancel();
    await link.close();
  }
}
