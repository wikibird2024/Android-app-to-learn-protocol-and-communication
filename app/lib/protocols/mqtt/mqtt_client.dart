import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/inspect/frame.dart';
import '../../core/log/session_log.dart';
import '../../core/transport/link.dart';
import 'mqtt_packet.dart';

enum MqttClientState { disconnected, connecting, connected }

/// A small MQTT 3.1.1 client written to be read: every rule of the
/// protocol it follows is one visible step below.
///
///   connect ──CONNECT──▶ broker ──CONNACK──▶ connected
///   publish QoS 0: PUBLISH                            (fire and forget)
///   publish QoS 1: PUBLISH ──▶ ◀── PUBACK              (at least once)
///   publish QoS 2: PUBLISH ──▶ ◀── PUBREC ──PUBREL──▶ ◀── PUBCOMP (once)
///   keep alive   : nothing sent for keepAlive s → PINGREQ ──▶ ◀── PINGRESP
class MqttClient {
  MqttClient({
    required this.link,
    required this.log,
    this.ackTimeout = const Duration(seconds: 10),
  }) {
    _subscription = link.incoming.listen(
      _onBytes,
      onDone: () => _closed('link closed'),
      onError: (Object error) => _closed('link error: $error'),
    );
  }

  final Link link;
  final SessionLog log;
  final Duration ackTimeout;

  final state = ValueNotifier(MqttClientState.disconnected);
  final _messages = StreamController<MqttPublish>.broadcast();
  final _splitter = MqttStreamSplitter();
  late final StreamSubscription<Uint8List> _subscription;

  Completer<MqttConnAck>? _connAck;
  final _pendingAcks = <int, Completer<MqttPacket>>{};
  final _receivedQos2Ids = <int>{};
  var _nextPacketId = 1;
  Timer? _keepAliveTimer;
  Duration _keepAlive = Duration.zero;
  bool _isPingPending = false;

  /// PUBLISH packets from the broker, for topics we subscribed to.
  Stream<MqttPublish> get messages => _messages.stream;

  /// Sends CONNECT and waits for CONNACK. Throws [StateError] when the
  /// broker refuses (return code ≠ 0) and [TimeoutException] when it is
  /// silent.
  Future<MqttConnAck> connect(MqttConnect packet) async {
    state.value = MqttClientState.connecting;
    _keepAlive = Duration(seconds: packet.keepAliveSeconds);
    final completer = _connAck = Completer<MqttConnAck>();
    await _send(packet);
    try {
      final ack = await completer.future.timeout(ackTimeout);
      if (ack.returnCode != 0) {
        throw StateError(mqttConnectReturnCodes[ack.returnCode] ?? 'refused');
      }
      state.value = MqttClientState.connected;
      _restartKeepAlive();
      return ack;
    } catch (_) {
      await close();
      rethrow;
    } finally {
      _connAck = null;
    }
  }

  /// QoS 0 completes once sent; QoS 1 after PUBACK; QoS 2 after PUBCOMP.
  Future<void> publish(
    String topic,
    Uint8List payload, {
    int qos = 0,
    bool retain = false,
  }) async {
    if (qos == 0) {
      await _send(MqttPublish(topic: topic, payload: payload, retain: retain));
      return;
    }
    final packetId = _takePacketId();
    final ack = _waitFor(packetId);
    await _send(MqttPublish(topic: topic, payload: payload, qos: qos, retain: retain, packetId: packetId));
    final first = await ack;
    if (qos == 2) {
      if (first.type != MqttPacketType.pubrec) throw StateError('expected PUBREC, got ${first.type.label}');
      final complete = _waitFor(packetId);
      await _send(MqttPacketIdOnly(MqttPacketType.pubrel, packetId));
      await complete;
    }
  }

  Future<MqttSubAck> subscribe(List<MqttSubscription> subscriptions) async {
    final packetId = _takePacketId();
    final ack = _waitFor(packetId);
    await _send(MqttSubscribe(packetId: packetId, subscriptions: subscriptions));
    return await ack as MqttSubAck;
  }

  Future<void> unsubscribe(List<String> topicFilters) async {
    final packetId = _takePacketId();
    final ack = _waitFor(packetId);
    await _send(MqttUnsubscribe(packetId: packetId, topicFilters: topicFilters));
    await ack;
  }

  /// A clean DISCONNECT: the broker does not publish our will.
  Future<void> disconnect() async {
    if (state.value == MqttClientState.connected) {
      await _send(const MqttEmpty(MqttPacketType.disconnect));
    }
    await close();
  }

  /// Drops the connection without DISCONNECT, like a power cut: the broker
  /// will publish our will message.
  Future<void> close() async {
    _closed('closed');
    // Not awaited: a broadcast subscription's cancel future can lag behind,
    // and nothing here depends on it.
    unawaited(_subscription.cancel());
    await link.close();
  }

  int _takePacketId() {
    // Ids 1..65535, skipping ones still waiting for an answer.
    for (var tries = 0; tries < 65535; tries++) {
      final packetId = _nextPacketId;
      _nextPacketId = _nextPacketId == 65535 ? 1 : _nextPacketId + 1;
      if (!_pendingAcks.containsKey(packetId)) return packetId;
    }
    throw StateError('all 65535 packet ids are in use');
  }

  Future<MqttPacket> _waitFor(int packetId) {
    final completer = Completer<MqttPacket>();
    _pendingAcks[packetId] = completer;
    final future = completer.future.timeout(ackTimeout, onTimeout: () {
      _pendingAcks.remove(packetId);
      log.note('no answer for packet id $packetId in ${ackTimeout.inSeconds} s');
      throw TimeoutException('no answer for packet id $packetId', ackTimeout);
    });
    // The caller awaits it after sending; if the send throws first, this
    // keeps the later error from being reported as unhandled.
    future.ignore();
    return future;
  }

  Future<void> _send(MqttPacket packet) async {
    final bytes = encodeMqtt(packet);
    log.sent(decodeMqtt(bytes).frame);
    await link.send(bytes);
    _restartKeepAlive();
  }

  /// The keep-alive clock restarts on every packet we send (spec 3.1.2.10):
  /// the ping only fills silence.
  void _restartKeepAlive() {
    _keepAliveTimer?.cancel();
    if (_keepAlive == Duration.zero || state.value != MqttClientState.connected) return;
    _keepAliveTimer = Timer(_keepAlive, () {
      if (_isPingPending) {
        log.note('no PINGRESP within keep alive: broker gone, closing');
        unawaited(close());
        return;
      }
      _isPingPending = true;
      unawaited(_send(const MqttEmpty(MqttPacketType.pingreq)).catchError((Object _) {}));
    });
  }

  void _onBytes(Uint8List chunk) {
    final List<Uint8List> packets;
    final carried = _splitter.waitingBytes;
    try {
      packets = _splitter.add(chunk);
    } on FormatException catch (error) {
      log.note('broken stream: ${error.message}');
      unawaited(close());
      return;
    }
    for (final (index, bytes) in packets.indexed) {
      final decoded = decodeMqtt(bytes);
      log.received(_withDelivery(decoded.frame, isSplit: index == 0 && carried > 0, sharedWith: packets.length - 1));
      final packet = decoded.packet;
      if (packet == null) {
        // Spec 4.8: a protocol violation closes the connection.
        unawaited(close());
        return;
      }
      _handle(packet);
    }
  }

  /// TCP has no message borders: say when this packet was cut across reads
  /// or arrived glued to others, so the Inside view shows why MQTT needs its
  /// remaining-length field.
  static Frame _withDelivery(Frame frame, {required bool isSplit, required int sharedWith}) {
    if (!isSplit && sharedWith == 0) return frame;
    return frame.copyWith(fields: [
      ...frame.fields,
      Field(
        'TCP delivery',
        0,
        0,
        [if (isSplit) 'started in an earlier read', if (sharedWith > 0) 'came in one read with $sharedWith other packet${sharedWith == 1 ? '' : 's'}'].join(', '),
        note: 'TCP is a byte stream; the remaining-length field finds where each packet ends',
      ),
    ]);
  }

  void _handle(MqttPacket packet) {
    switch (packet) {
      case MqttConnAck():
        _connAck?.complete(packet);
      case MqttPublish(:final qos, :final packetId):
        if (qos == 0) {
          _messages.add(packet);
        } else if (qos == 1) {
          _messages.add(packet);
          unawaited(_send(MqttPacketIdOnly(MqttPacketType.puback, packetId!)));
        } else {
          // QoS 2: deliver once; a resent PUBLISH with the same id before
          // PUBREL is the same message.
          if (_receivedQos2Ids.add(packetId!)) _messages.add(packet);
          unawaited(_send(MqttPacketIdOnly(MqttPacketType.pubrec, packetId)));
        }
      case MqttPacketIdOnly(type: MqttPacketType.pubrel, :final packetId):
        _receivedQos2Ids.remove(packetId);
        unawaited(_send(MqttPacketIdOnly(MqttPacketType.pubcomp, packetId)));
      case MqttPacketIdOnly(:final packetId):
        _pendingAcks.remove(packetId)?.complete(packet);
      case MqttSubAck(:final packetId):
        _pendingAcks.remove(packetId)?.complete(packet);
      case MqttEmpty(type: MqttPacketType.pingresp):
        _isPingPending = false;
      case MqttConnect() || MqttSubscribe() || MqttUnsubscribe() || MqttEmpty():
        log.note('${packet.type.label} only goes client → broker');
    }
  }

  void _closed(String reason) {
    if (state.value == MqttClientState.disconnected && _pendingAcks.isEmpty && _connAck == null) return;
    _keepAliveTimer?.cancel();
    state.value = MqttClientState.disconnected;
    log.note(reason);
    final error = StateError('connection $reason');
    if (_connAck != null && !_connAck!.isCompleted) _connAck!.completeError(error);
    for (final completer in _pendingAcks.values) {
      completer.completeError(error);
    }
    _pendingAcks.clear();
  }
}
