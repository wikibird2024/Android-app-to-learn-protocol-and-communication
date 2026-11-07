import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/bytes/hex.dart';
import 'package:protocol_lab/protocols/mqtt/mqtt_packet.dart';

void main() {
  group('remaining length (spec table 2.4)', () {
    const cases = {
      0: '00',
      127: '7f',
      128: '80 01',
      16383: 'ff 7f',
      16384: '80 80 01',
      2097151: 'ff ff 7f',
      2097152: '80 80 80 01',
      268435455: 'ff ff ff 7f',
    };
    cases.forEach((length, hex) {
      test('$length → $hex', () {
        expect(toHex(encodeRemainingLength(length)), hex);
      });
    });
    test('over the maximum throws', () {
      expect(() => encodeRemainingLength(268435456), throwsArgumentError);
    });
  });

  test('CONNECT bytes match the spec layout', () {
    final bytes = encodeMqtt(
      const MqttConnect(clientId: 'lab', keepAliveSeconds: 60),
    );
    expect(
      toHex(bytes),
      // 10 = CONNECT, 0f = 15 bytes left, 00 04 "MQTT", level 4,
      // flags 02 (clean session), keep alive 00 3c, client id 00 03 "lab"
      '10 0f 00 04 4d 51 54 54 04 02 00 3c 00 03 6c 61 62',
    );
  });

  test('CONNECT with will, user and password round-trips', () {
    final original = MqttConnect(
      clientId: 'phone-1',
      keepAliveSeconds: 30,
      username: 'hao',
      password: 'secret',
      will: MqttWill(
        topic: 'lab/status',
        message: Uint8List.fromList(utf8.encode('offline')),
        qos: 1,
        retain: true,
      ),
    );
    final decoded = decodeMqtt(encodeMqtt(original));
    final packet = decoded.packet as MqttConnect;
    expect(decoded.frame.error, isNull);
    expect(packet.clientId, 'phone-1');
    expect(packet.keepAliveSeconds, 30);
    expect(packet.username, 'hao');
    expect(packet.password, 'secret');
    expect(packet.will!.topic, 'lab/status');
    expect(utf8.decode(packet.will!.message), 'offline');
    expect(packet.will!.qos, 1);
    expect(packet.will!.retain, isTrue);
    // flags: user, password, will retain, will QoS 1, will, clean = 0xEE
    expect(encodeMqtt(original)[9], 0xEE);
  });

  test('PUBLISH QoS 1 bytes and decode', () {
    final bytes = encodeMqtt(
      MqttPublish(
        topic: 'a/b',
        payload: Uint8List.fromList([0x68, 0x69]),
        qos: 1,
        retain: true,
        packetId: 10,
      ),
    );
    expect(toHex(bytes), '33 09 00 03 61 2f 62 00 0a 68 69');
    final decoded = decodeMqtt(bytes);
    final packet = decoded.packet as MqttPublish;
    expect(packet.topic, 'a/b');
    expect(packet.qos, 1);
    expect(packet.retain, isTrue);
    expect(packet.packetId, 10);
    expect(decoded.frame.summary, 'PUBLISH a/b QoS 1 retained "hi"');
    expect(
      decoded.frame.fields.map((field) => field.name),
      ['fixed header', 'remaining length', 'topic', 'packet id', 'payload'],
    );
    expect(decoded.frame.fields[2].offset, 2);
    expect(decoded.frame.fields[2].length, 5);
  });

  test('QoS 1 PUBLISH without packet id is refused', () {
    expect(
      () => encodeMqtt(
        MqttPublish(topic: 't', payload: Uint8List(0), qos: 1),
      ),
      throwsArgumentError,
    );
  });

  test('SUBSCRIBE uses flags 0010 and lists filters', () {
    final bytes = encodeMqtt(
      const MqttSubscribe(
        packetId: 1,
        subscriptions: [MqttSubscription('lab/#', 1)],
      ),
    );
    expect(toHex(bytes), '82 0a 00 01 00 05 6c 61 62 2f 23 01');
  });

  test('small packets', () {
    expect(toHex(encodeMqtt(const MqttEmpty(MqttPacketType.pingreq))), 'c0 00');
    expect(toHex(encodeMqtt(const MqttEmpty(MqttPacketType.disconnect))), 'e0 00');
    expect(toHex(encodeMqtt(const MqttPacketIdOnly(MqttPacketType.puback, 10))), '40 02 00 0a');
    expect(toHex(encodeMqtt(const MqttPacketIdOnly(MqttPacketType.pubrel, 7))), '62 02 00 07');
  });

  test('CONNACK and SUBACK decode', () {
    final connAck = decodeMqtt(parseHex('20 02 00 05')).packet as MqttConnAck;
    expect(connAck.returnCode, 5);
    expect(decodeMqtt(parseHex('20 02 00 05')).frame.summary, 'CONNACK refused: not authorized');
    final subAck = decodeMqtt(parseHex('90 04 00 01 01 80')).packet as MqttSubAck;
    expect(subAck.returnCodes, [1, 0x80]);
  });

  group('bad bytes give an error frame, never a throw', () {
    for (final hex in ['', '30', '30 05 00', '00 00', 'f0 00', '30 ff ff ff ff 01', '20 02 00', '36 03 00 01 61']) {
      test('"$hex"', () {
        final decoded = decodeMqtt(parseHex(hex));
        expect(decoded.packet, isNull);
        expect(decoded.frame.error, isNotNull);
      });
    }
  });

  group('stream splitter', () {
    final packets = [
      encodeMqtt(const MqttConnAck(sessionPresent: false, returnCode: 0)),
      encodeMqtt(MqttPublish(topic: 'big', payload: Uint8List(300))),
      encodeMqtt(const MqttEmpty(MqttPacketType.pingresp)),
    ];
    final stream = Uint8List.fromList(packets.expand((packet) => packet).toList());
    for (final chunkSize in [1, 2, 3, 7, 1000]) {
      test('chunk size $chunkSize', () {
        final splitter = MqttStreamSplitter();
        final out = <Uint8List>[];
        for (var start = 0; start < stream.length; start += chunkSize) {
          final end = (start + chunkSize).clamp(0, stream.length);
          out.addAll(splitter.add(Uint8List.sublistView(stream, start, end)));
        }
        expect(out, packets);
      });
    }
    test('a 5-byte length breaks the stream', () {
      expect(() => MqttStreamSplitter().add(parseHex('30 ff ff ff ff 01')), throwsFormatException);
    });
  });
}
