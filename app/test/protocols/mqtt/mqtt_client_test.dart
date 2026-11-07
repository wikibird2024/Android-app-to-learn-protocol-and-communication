import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/log/session_log.dart';
import 'package:protocol_lab/core/transport/link.dart';
import 'package:protocol_lab/protocols/mqtt/mqtt_client.dart';
import 'package:protocol_lab/protocols/mqtt/mqtt_packet.dart';

/// A tiny broker stand-in: answers what a real broker would, and records
/// the packets the client sent.
class _FakeBroker {
  _FakeBroker(this.link) {
    link.onSend = (bytes) {
      for (final packet in splitter.add(bytes)) {
        final decoded = decodeMqtt(packet).packet!;
        received.add(decoded);
        if (isSilent) continue;
        switch (decoded) {
          case MqttConnect():
            reply(MqttConnAck(sessionPresent: false, returnCode: connectReturnCode));
          case MqttPublish(qos: 1, :final packetId):
            reply(MqttPacketIdOnly(MqttPacketType.puback, packetId!));
          case MqttPublish(qos: 2, :final packetId):
            reply(MqttPacketIdOnly(MqttPacketType.pubrec, packetId!));
          case MqttPacketIdOnly(type: MqttPacketType.pubrel, :final packetId):
            reply(MqttPacketIdOnly(MqttPacketType.pubcomp, packetId));
          case MqttSubscribe(:final packetId, :final subscriptions):
            reply(MqttSubAck(packetId: packetId, returnCodes: [for (final item in subscriptions) item.qos]));
          case MqttEmpty(type: MqttPacketType.pingreq):
            if (answersPing) reply(const MqttEmpty(MqttPacketType.pingresp));
          default:
            break;
        }
      }
    };
  }

  final FakeLink link;
  final splitter = MqttStreamSplitter();
  final received = <MqttPacket>[];
  var connectReturnCode = 0;
  var answersPing = true;
  var isSilent = false;

  void reply(MqttPacket packet) => scheduleMicrotask(() => link.deliver(encodeMqtt(packet)));

  List<MqttPacketType> get types => [for (final packet in received) packet.type];
}

void main() {
  late FakeLink link;
  late _FakeBroker broker;
  late SessionLog log;
  late MqttClient client;

  setUp(() {
    link = FakeLink();
    broker = _FakeBroker(link);
    log = SessionLog();
    client = MqttClient(link: link, log: log, ackTimeout: const Duration(seconds: 2));
  });

  test('connect, then QoS 0/1/2 publish follow the handshakes', () async {
    await client.connect(const MqttConnect(clientId: 'lab'));
    expect(client.state.value, MqttClientState.connected);
    await client.publish('t', Uint8List.fromList([1]));
    await client.publish('t', Uint8List.fromList([2]), qos: 1);
    await client.publish('t', Uint8List.fromList([3]), qos: 2);
    expect(broker.types, [
      MqttPacketType.connect,
      MqttPacketType.publish,
      MqttPacketType.publish,
      MqttPacketType.publish,
      MqttPacketType.pubrel,
    ]);
    // Every packet both ways is in the log, decoded.
    expect(log.entries.where((entry) => entry.direction != Direction.note).length, 9);
    await client.disconnect();
    expect(broker.types.last, MqttPacketType.disconnect);
  });

  test('refused CONNACK throws and closes', () async {
    broker.connectReturnCode = 5;
    await expectLater(client.connect(const MqttConnect(clientId: 'lab')), throwsStateError);
    expect(client.state.value, MqttClientState.disconnected);
    expect(link.isClosed, isTrue);
  });

  test('silent broker: connect times out', () {
    fakeAsync((async) {
      // Built inside the fake zone so close() runs on the fake clock too.
      final link = FakeLink();
      _FakeBroker(link).isSilent = true;
      final client = MqttClient(link: link, log: SessionLog(), ackTimeout: const Duration(seconds: 2));
      Object? error;
      client.connect(const MqttConnect(clientId: 'lab')).catchError((Object caught) {
        error = caught;
        return const MqttConnAck(sessionPresent: false, returnCode: 0);
      });
      async.elapse(const Duration(seconds: 3));
      expect(error, isA<TimeoutException>());
    });
  });

  test('incoming QoS 1 gets PUBACK, QoS 2 is delivered once', () async {
    await client.connect(const MqttConnect(clientId: 'lab'));
    final messages = <MqttPublish>[];
    client.messages.listen(messages.add);
    final qos2 = MqttPublish(topic: 'x', payload: Uint8List(1), qos: 2, packetId: 9);
    broker.reply(MqttPublish(topic: 'x', payload: Uint8List(1), qos: 1, packetId: 8));
    broker.reply(qos2);
    broker.reply(MqttPublish(topic: 'x', payload: Uint8List(1), qos: 2, packetId: 9, duplicate: true));
    broker.reply(const MqttPacketIdOnly(MqttPacketType.pubrel, 9));
    await pumpEventQueue();
    expect(messages.length, 2);
    expect(broker.types.skip(1), [
      MqttPacketType.puback,
      MqttPacketType.pubrec,
      MqttPacketType.pubrec,
      MqttPacketType.pubcomp,
    ]);
  });

  test('keep alive: PINGREQ after silence, close when no PINGRESP', () {
    fakeAsync((async) {
      client.connect(const MqttConnect(clientId: 'lab', keepAliveSeconds: 10));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 10));
      expect(broker.types.last, MqttPacketType.pingreq);
      broker.answersPing = false;
      async.elapse(const Duration(seconds: 10));
      async.elapse(const Duration(seconds: 10));
      expect(client.state.value, MqttClientState.disconnected);
      expect(log.entries.any((entry) => entry.frame.summary.contains('no PINGRESP')), isTrue);
    });
  });

  test('subscribe returns the granted QoS', () async {
    await client.connect(const MqttConnect(clientId: 'lab'));
    final ack = await client.subscribe(const [MqttSubscription('lab/#', 1)]);
    expect(ack.returnCodes, [1]);
  });
}
