import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/inspect/frame.dart';
import 'package:protocol_lab/core/log/exchanges.dart';
import 'package:protocol_lab/core/log/session_log.dart';
import 'package:protocol_lab/core/transport/link.dart';
import 'package:protocol_lab/protocols/ble/att_pdu.dart';
import 'package:protocol_lab/protocols/coap/coap_codec.dart';
import 'package:protocol_lab/protocols/dns/dns_codec.dart';
import 'package:protocol_lab/protocols/modbus/modbus_codec.dart';
import 'package:protocol_lab/protocols/mqtt/mqtt_packet.dart';
import 'package:protocol_lab/protocols/radio/radio_frames.dart';
import 'package:protocol_lab/protocols/websocket/ws_client.dart';
import 'package:protocol_lab/protocols/websocket/ws_codec.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

Field _find(List<Field> fields, String name) {
  for (final field in fields) {
    if (field.name == name) return field;
    for (final child in field.children) {
      if (child.name == name) return child;
    }
  }
  throw StateError('no field $name in ${fields.map((field) => field.name)}');
}

LogEntry _entry(int milliseconds, Direction direction, String exchange, {bool ends = false}) => LogEntry(
  time: DateTime(2026, 11, 8, 12).add(Duration(milliseconds: milliseconds)),
  direction: direction,
  frame: Frame(protocol: 'test', summary: exchange, bytes: Uint8List(0), exchange: exchange, endsExchange: ends),
);

void main() {
  group('bit maps', () {
    test('MQTT fixed header bits carry their position', () {
      final frame = decodeMqtt(encodeMqtt(MqttPublish(topic: 't', payload: _bytes([1]), qos: 1, packetId: 7))).frame;
      final qos = _find(frame.fields, 'QoS');
      expect((qos.bitShift, qos.bitWidth, qos.value), (1, 2, '1'));
      expect(_find(frame.fields, 'packet type').bitShift, 4);
    });

    test('CoAP option header splits into delta (bits 7-4) and length (3-0)', () {
      final frame = decodeCoap(encodeCoap(CoapMessage.request(method: 1, path: '/temp', messageId: 1, token: _bytes([1])))).frame;
      final option = frame.fields.firstWhere((field) => field.name == 'Uri-Path');
      final header = option.children.first;
      expect(header.value, '0xb4'); // delta 11, length 4
      expect(header.children.map((bit) => (bit.name, bit.bitShift, bit.value)), [('delta', 4, '11'), ('length', 0, '4')]);
    });

    test('Modbus coils: one bit per coil, LSB first', () {
      final body = [0x01, 0x01, 0x01, 0x05];
      final crc = modbusCrc16(body);
      final frame = decodeModbusRtu(_bytes([...body, crc & 0xff, crc >> 8]), isRequest: false).frame;
      final byte = _find(frame.fields, 'bits').children.single;
      expect([for (final bit in byte.children) bit.value].take(3), ['1', '0', '1']);
      expect(byte.children.first.bitShift, 0);
    });
  });

  group('worked-out values', () {
    test('MQTT remaining length 200 = 0xC8 0x01 step by step', () {
      final frame = decodeMqtt(encodeMqtt(MqttPublish(topic: 'abc', payload: Uint8List(195)))).frame;
      final steps = _find(frame.fields, 'remaining length').children;
      expect(steps.map((step) => step.value), ['0xc8 → 72 × 1 = 72', '0x01 → 1 × 128 = 128']);
    });

    test('Modbus CRC says which bytes it covers, low byte first', () {
      final frame = decodeModbusRtu(_bytes([0x11, 0x03, 0x00, 0x6b, 0x00, 0x03, 0x76, 0x87]), isRequest: true).frame;
      final crc = _find(frame.fields, 'CRC');
      expect(crc.note, contains('bytes 0..5'));
      expect(crc.children.map((part) => part.value), ['0x76', '0x87']);
    });
  });

  group('Flow pairing', () {
    test('CoAP CON resent, then ACK: retry flagged, reply time measured', () {
      final steps = pairExchanges([
        _entry(0, Direction.sent, 'CoAP #1'),
        _entry(2000, Direction.sent, 'CoAP #1'),
        _entry(2100, Direction.received, 'CoAP #1', ends: true),
        _entry(3000, Direction.sent, 'CoAP #1'),
      ]);
      expect(steps[0]!.isFirst, isTrue);
      expect(steps[1]!.isRetry, isTrue);
      expect((steps[2]!.isLast, steps[2]!.sinceStart), (true, const Duration(milliseconds: 2100)));
      expect(steps[3]!.number, 2, reason: 'after the ACK the same id starts a new exchange');
    });

    test('MQTT QoS 2: four packets, one exchange, the last one closes it', () {
      final steps = pairExchanges([
        for (final (time, direction, ends) in [(0, Direction.sent, false), (10, Direction.received, false), (12, Direction.sent, false), (30, Direction.received, true)])
          _entry(time, direction, 'MQTT id 7', ends: ends),
      ]);
      expect(steps.map((step) => step!.number).toSet(), {1});
      expect(steps.any((step) => step!.isRetry), isFalse);
      expect(steps.last!.sinceStart, const Duration(milliseconds: 30));
    });

    test('decoders set the keys: CONNECT/CONNACK and PUBLISH/PUBACK', () {
      final connect = decodeMqtt(encodeMqtt(const MqttConnect(clientId: 'a'))).frame;
      final connAck = decodeMqtt(_bytes([0x20, 0x02, 0x00, 0x00])).frame;
      expect((connect.exchange, connect.endsExchange), ('MQTT connect', false));
      expect((connAck.exchange, connAck.endsExchange), ('MQTT connect', true));
      final pubAck = decodeMqtt(_bytes([0x40, 0x02, 0x00, 0x07])).frame;
      expect((pubAck.exchange, pubAck.endsExchange), ('MQTT id 7', true));
    });
  });

  group('DNS / mDNS', () {
    // A hand-built mDNS answer: PTR, then SRV and A as additional records,
    // with compression pointers back into earlier names.
    final response = _bytes([
      0x00, 0x00, 0x84, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02,
      // offset 12: _http._tcp.local PTR IN ttl 4500
      0x05, ...'_http'.codeUnits, 0x04, ...'_tcp'.codeUnits, 0x05, ...'local'.codeUnits, 0x00,
      0x00, 0x0c, 0x00, 0x01, 0x00, 0x00, 0x11, 0x94, 0x00, 0x0a,
      // offset 40: Kitchen + pointer to offset 12
      0x07, ...'Kitchen'.codeUnits, 0xc0, 0x0c,
      // offset 50: SRV for Kitchen (pointer 40), cache flush, ttl 120
      0xc0, 0x28, 0x00, 0x21, 0x80, 0x01, 0x00, 0x00, 0x00, 0x78, 0x00, 0x0e,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x50,
      // offset 68: esp32 + pointer to "local" at offset 23
      0x05, ...'esp32'.codeUnits, 0xc0, 0x17,
      // offset 76: A for esp32.local (pointer 68)
      0xc0, 0x44, 0x00, 0x01, 0x80, 0x01, 0x00, 0x00, 0x00, 0x78, 0x00, 0x04, 192, 168, 1, 42,
    ]);

    test('reads PTR → SRV → A through compression pointers', () {
      final decoded = decodeDns(response);
      expect(decoded.frame.error, isNull);
      final records = decoded.message!.records;
      expect(records[0].target, 'Kitchen._http._tcp.local');
      expect((records[1].target, records[1].port), ('esp32.local', 80));
      expect((records[2].name, records[2].address), ('esp32.local', '192.168.1.42'));
    });

    test('the Inside view shows the pointer and its offset', () {
      final frame = decodeDns(response).frame;
      final ptr = frame.fields.firstWhere((field) => field.name == 'answer PTR');
      final data = ptr.children.firstWhere((field) => field.name == 'data');
      final pointer = data.children.firstWhere((field) => field.name == 'pointer');
      expect(pointer.value, contains('offset 12'));
      expect(pointer.children.first.bitShift, 6);
    });

    test('query round trip, QU bit in the class', () {
      final bytes = encodeDnsQuery([const DnsQuestion('_http._tcp.local', 12, wantsUnicast: true)]);
      final message = decodeDns(bytes).message!;
      expect(message.isResponse, isFalse);
      expect((message.questions.single.name, message.questions.single.wantsUnicast), ('_http._tcp.local', true));
    });

    test('a cut-off message is an error frame, not a throw', () {
      expect(decodeDns(Uint8List.sublistView(response, 0, 30)).frame.error, isNotNull);
    });
  });

  group('WebSocket (RFC 6455 examples)', () {
    test('Sec-WebSocket-Accept for the RFC sample key', () {
      expect(wsAcceptFor('dGhlIHNhbXBsZSBub25jZQ=='), 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=');
    });

    test('"Hello" unmasked and masked (section 5.7)', () {
      expect(encodeWsFrame(WsOpcode.text, utf8.encode('Hello')), [0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]);
      final masked = encodeWsFrame(WsOpcode.text, utf8.encode('Hello'), maskKey: [0x37, 0xfa, 0x21, 0x3d]);
      expect(masked, [0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58]);
      final decoded = decodeWsFrame(masked);
      expect((decoded.opcode, utf8.decode(decoded.payload!)), (WsOpcode.text, 'Hello'));
      expect(_find(decoded.frame.fields, 'MASK').bitShift, 7);
    });

    test('256 bytes use the 16-bit length, 64 KiB the 64-bit one', () {
      expect(encodeWsFrame(WsOpcode.binary, Uint8List(256)).sublist(0, 4), [0x82, 0x7e, 0x01, 0x00]);
      expect(encodeWsFrame(WsOpcode.binary, Uint8List(65536)).sublist(0, 10), [0x82, 0x7f, 0, 0, 0, 0, 0, 1, 0, 0]);
    });

    test('splitter: two frames in one read, one frame across two reads', () {
      final splitter = WsFrameSplitter();
      final one = encodeWsFrame(WsOpcode.text, utf8.encode('a'));
      final two = encodeWsFrame(WsOpcode.text, utf8.encode('bc'));
      expect(splitter.add([...one, ...two]).length, 2);
      expect(splitter.add(two.sublist(0, 3)), isEmpty);
      expect(splitter.add(two.sublist(3)).single, two);
    });

    test('client: handshake, a message, a ping answered with a masked pong', () async {
      final link = FakeLink();
      final log = SessionLog();
      final client = WsClient(link: link, log: log);
      link.onSend = (bytes) {
        final text = utf8.decode(bytes, allowMalformed: true);
        final key = RegExp(r'Sec-WebSocket-Key: (\S+)').firstMatch(text)?.group(1);
        if (key == null) return;
        scheduleMicrotask(() => link.deliver([
          ...utf8.encode('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${wsAcceptFor(key)}\r\n\r\n'),
          ...encodeWsFrame(WsOpcode.text, utf8.encode('hi')),
          ...encodeWsFrame(WsOpcode.ping, utf8.encode('p1')),
        ]));
      };
      final message = client.messages.first;
      await client.handshake(Uri.parse('ws://bench.local/ws'));
      expect(utf8.decode((await message).payload), 'hi');
      await Future<void>.delayed(Duration.zero);
      final pong = decodeWsFrame(link.sentChunks.last);
      expect((pong.opcode, utf8.decode(pong.payload!)), (WsOpcode.pong, 'p1'));
      expect(link.sentChunks.last[1] & 0x80, 0x80, reason: 'client frames are masked');
      await link.close();
      log.dispose();
    });

    test('client: a wrong Accept is refused', () async {
      final link = FakeLink();
      final client = WsClient(link: link, log: SessionLog());
      link.onSend = (_) => scheduleMicrotask(() => link.deliver(utf8.encode('HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: wrong\r\n\r\n')));
      await expectLater(client.handshake(Uri.parse('ws://x/')), throwsA(isA<WsError>()));
    });
  });

  group('rebuilt frames', () {
    test('ATT Write Request: opcode 0x12, command bit clear; Write Command 0x52 has it', () {
      final request = describeAtt(AttOpcode.writeRequest, [1, 2], characteristic: '2a19');
      expect(request.bytes, [0x12, 1, 2]);
      expect(_find(request.fields, 'command').value, 'no');
      expect(_find(describeAtt(AttOpcode.writeCommand, [1], characteristic: '2a19').fields, 'command').value, 'yes');
    });

    test('ESP-NOW: category 127, Espressif OUI, element 0xdd, type 4', () {
      final frame = describeEspNow(utf8.encode('hi'), peer: 'ff:ff:ff:ff:ff:ff', isSent: true);
      expect(frame.bytes.sublist(0, 4), [127, 0x18, 0xfe, 0x34]);
      expect(frame.bytes.sublist(8, 15), [0xdd, 7, 0x18, 0xfe, 0x34, 4, 1]);
      expect(frame.bytes.sublist(15), utf8.encode('hi'));
    });

    test('ZCL On/Off toggle: cluster-specific frame, command 0x02', () {
      final frame = describeZclOnOff(shortAddress: '1a2b', endpoint: 1, action: 'toggle');
      expect(frame.bytes, [0x01, 0x00, 0x02]);
      expect(_find(frame.fields, 'frame type').bitWidth, 2);
    });
  });
}
