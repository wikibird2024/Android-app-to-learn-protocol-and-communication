import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../core/log/session_log.dart';
import '../../core/transport/link.dart';
import '../http/http_codec.dart';
import 'ws_codec.dart';

class WsError implements Exception {
  const WsError(this.message);
  final String message;

  @override
  String toString() => 'WebSocket: $message';
}

typedef WsMessage = ({bool isText, Uint8List payload});

/// A WebSocket client on any [Link]: the HTTP upgrade, then masked frames,
/// ping/pong and the close handshake, every byte through [log].
class WsClient {
  WsClient({required this.link, required this.log, Random? random, this.pingInterval = const Duration(seconds: 20)})
    : _random = random ?? Random.secure();

  final Link link;
  final SessionLog log;
  final Duration pingInterval;
  final Random _random;
  final _splitter = WsFrameSplitter();
  final _messages = StreamController<WsMessage>.broadcast();
  final _fragments = BytesBuilder();
  StreamSubscription<Uint8List>? _subscription;
  Timer? _pingTimer;
  bool _isText = false;
  bool _isClosing = false;
  int? closeCode;

  /// Text and binary messages, fragments joined. Closes with the link.
  Stream<WsMessage> get messages => _messages.stream;

  List<int> _maskKey() => [for (var index = 0; index < 4; index++) _random.nextInt(256)];

  /// Sends the upgrade request and checks the 101 answer and its
  /// Sec-WebSocket-Accept. Throws [WsError] when the server refuses.
  Future<String?> handshake(Uri url, {String? protocol}) async {
    final key = base64.encode([for (var index = 0; index < 16; index++) _random.nextInt(256)]);
    final hostHeader = url.hasPort ? '${url.host}:${url.port}' : url.host;
    final request = Uint8List.fromList(utf8.encode(
      'GET ${url.path.isEmpty ? '/' : url.path}${url.hasQuery ? '?${url.query}' : ''} HTTP/1.1\r\n'
      'Host: $hostHeader\r\n'
      'Upgrade: websocket\r\n'
      'Connection: Upgrade\r\n'
      'Sec-WebSocket-Key: $key\r\n'
      'Sec-WebSocket-Version: 13\r\n'
      '${protocol == null || protocol.isEmpty ? '' : 'Sec-WebSocket-Protocol: $protocol\r\n'}'
      '\r\n',
    ));
    final response = Completer<Uint8List>();
    final head = BytesBuilder();
    _subscription = link.incoming.listen(
      (chunk) {
        if (response.isCompleted) return _onBytes(chunk);
        head.add(chunk);
        final bytes = head.toBytes();
        final end = _indexOfBlankLine(bytes);
        if (end < 0) return;
        response.complete(Uint8List.sublistView(bytes, 0, end));
        if (bytes.length > end) _onBytes(Uint8List.sublistView(bytes, end));
      },
      onDone: () {
        if (!response.isCompleted) response.completeError(const WsError('closed during the handshake'));
        _finish();
      },
    );
    log.sent(describeHttpMessage(request, isRequest: true));
    await link.send(request);
    final answer = await response.future.timeout(const Duration(seconds: 10));
    log.received(describeHttpMessage(answer, isRequest: false));
    final text = utf8.decode(answer, allowMalformed: true);
    final lines = text.split('\r\n');
    if (!lines.first.contains(' 101 ')) throw WsError('server answered "${lines.first}", not 101 Switching Protocols');
    String? header(String name) {
      for (final line in lines.skip(1)) {
        final colon = line.indexOf(':');
        if (colon > 0 && line.substring(0, colon).trim().toLowerCase() == name) return line.substring(colon + 1).trim();
      }
      return null;
    }

    final accept = header('sec-websocket-accept');
    if (accept != wsAcceptFor(key)) throw WsError('Sec-WebSocket-Accept is "$accept", expected "${wsAcceptFor(key)}"');
    log.note('upgrade ok: Accept = base64(SHA-1(key + GUID)) matches');
    _pingTimer = Timer.periodic(pingInterval, (_) => unawaited(_sendFrame(WsOpcode.ping, utf8.encode('keepalive')).catchError((Object _) {})));
    return header('sec-websocket-protocol');
  }

  static int _indexOfBlankLine(Uint8List bytes) {
    for (var index = 0; index + 3 < bytes.length; index++) {
      if (bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10) return index + 4;
    }
    return -1;
  }

  Future<void> _sendFrame(WsOpcode opcode, List<int> payload) async {
    final bytes = encodeWsFrame(opcode, payload, maskKey: _maskKey());
    log.sent(decodeWsFrame(bytes).frame);
    await link.send(bytes);
  }

  Future<void> send(Uint8List payload, {required bool isText}) => _sendFrame(isText ? WsOpcode.text : WsOpcode.binary, payload);

  void _onBytes(Uint8List chunk) {
    for (final bytes in _splitter.add(chunk)) {
      final decoded = decodeWsFrame(bytes);
      log.received(decoded.frame);
      final payload = decoded.payload;
      final opcode = decoded.opcode;
      if (payload == null || opcode == null) continue;
      switch (opcode) {
        case WsOpcode.text || WsOpcode.binary || WsOpcode.continuation:
          if (opcode != WsOpcode.continuation) _isText = opcode == WsOpcode.text;
          _fragments.add(payload);
          if (decoded.isFinal) _messages.add((isText: _isText, payload: _fragments.takeBytes()));
        case WsOpcode.ping:
          unawaited(_sendFrame(WsOpcode.pong, payload).catchError((Object _) {})); // must echo the payload
        case WsOpcode.pong:
          break;
        case WsOpcode.close:
          closeCode = payload.length >= 2 ? payload[0] << 8 | payload[1] : 1005;
          if (!_isClosing) {
            _isClosing = true;
            unawaited(_sendFrame(WsOpcode.close, payload.length >= 2 ? payload.sublist(0, 2) : const []).catchError((Object _) {}));
          }
          unawaited(link.close());
      }
    }
  }

  /// The close handshake: send close (1000 = normal), wait briefly for the
  /// server's close, then drop TCP.
  Future<void> close({int code = 1000}) async {
    if (!_isClosing) {
      _isClosing = true;
      try {
        await _sendFrame(WsOpcode.close, [code >> 8, code & 0xff]);
        await _messages.done.timeout(const Duration(seconds: 2), onTimeout: () {});
      } on Object {
        // Link already gone: nothing to wait for.
      }
    }
    await link.close();
    _finish();
  }

  void _finish() {
    _pingTimer?.cancel();
    if (!_messages.isClosed) unawaited(_messages.close());
    unawaited(_subscription?.cancel());
  }
}
