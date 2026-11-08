import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/app/theme.dart';
import 'package:protocol_lab/core/inspect/frame.dart';
import 'package:protocol_lab/core/log/session_log.dart';
import 'package:protocol_lab/core/ui/form_parts.dart';
import 'package:protocol_lab/core/ui/frame_view.dart';
import 'package:protocol_lab/core/ui/log_view.dart';
import 'package:protocol_lab/core/ui/wire_view.dart';
import 'package:protocol_lab/protocols/bus/bus_frames.dart';
import 'package:protocol_lab/protocols/modbus/modbus_codec.dart';
import 'package:protocol_lab/protocols/mqtt/mqtt_packet.dart';

Frame _frame(String summary, List<int> bytes) => Frame(protocol: 'mqtt', summary: summary, bytes: Uint8List.fromList(bytes));

void main() {
  group('fieldAtByte', () {
    const flags = Field('flags', 0, 1, '0x32', children: [Field('QoS', 0, 0, '1')]);
    const length = Field('remaining length', 1, 2, '128', children: [Field('byte 1', 1, 1, '80'), Field('byte 2', 2, 1, '01')]);
    const fields = [flags, length];

    test('picks the deepest field with bytes', () {
      expect(fieldAtByte(fields, 2)?.name, 'byte 2');
      expect(fieldAtByte(fields, 1)?.name, 'byte 1');
    });

    test('a zero-length bit field never wins over its byte', () {
      expect(fieldAtByte(fields, 0)?.name, 'flags');
    });

    test('a byte outside every field has none', () {
      expect(fieldAtByte(fields, 9), isNull);
    });
  });

  group('log filter and time', () {
    final start = DateTime(2026, 11, 8, 14, 3, 22, 105);
    final publish = LogEntry(time: start, direction: Direction.sent, frame: _frame('PUBLISH t/1', [0x30, 0x80, 0x01]));
    final ack = LogEntry(time: start.add(const Duration(milliseconds: 250)), direction: Direction.received, frame: _frame('PUBACK', [0x40, 0x02]));

    test('matches summary text, protocol and hex bytes', () {
      final all = Direction.values.toSet();
      expect(logEntryMatches(publish, all, 'publish'), isTrue);
      expect(logEntryMatches(publish, all, 'mqtt'), isTrue);
      expect(logEntryMatches(publish, all, '80 01'), isTrue);
      expect(logEntryMatches(ack, all, '80 01'), isFalse);
    });

    test('hides directions that are switched off', () {
      expect(logEntryMatches(ack, {Direction.sent}, ''), isFalse);
      expect(logEntryMatches(publish, {Direction.sent}, ''), isTrue);
    });

    test('clock, since start and delta time', () {
      expect(formatLogTime(publish, TimeMode.clock), '14:03:22.105');
      expect(formatLogTime(ack, TimeMode.sinceStart, reference: start), '+0.250');
      expect(formatLogTime(ack, TimeMode.sincePrevious, reference: publish.time), 'Δ0.250');
    });
  });

  group('friendlyError', () {
    test('connection refused names the port and what to check', () {
      final text = friendlyError(const SocketException('Connection refused', osError: OSError('Connection refused', 111), port: 1883));
      expect(text, contains('port 1883'));
      expect(text, contains('running'));
    });

    test('a refused number names its range', () {
      expect(friendlyError(const FormatException('Port: a number 1..65535')), 'Port: a number 1..65535');
    });
  });

  testWidgets('Inside filter narrows the log and shows the count', (tester) async {
    final log = SessionLog()
      ..sent(_frame('PUBLISH t/1', [0x30]))
      ..received(_frame('PUBACK', [0x40]))
      ..note('connected');
    await tester.pumpWidget(MaterialApp(theme: lightTheme, home: Scaffold(body: LogView(log: log, showTools: true))));
    expect(find.text('PUBACK'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'publish');
    await tester.pump();
    expect(find.text('PUBACK'), findsNothing);
    expect(find.text('PUBLISH t/1'), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);
    log.dispose();
  });

  testWidgets('tapping a byte selects its field', (tester) async {
    final frame = Frame(
      protocol: 'mqtt',
      summary: 'PINGREQ',
      bytes: Uint8List.fromList([0xc0, 0x00]),
      fields: const [Field('type', 0, 1, 'PINGREQ'), Field('remaining length', 1, 1, '0')],
    );
    await tester.pumpWidget(MaterialApp(theme: lightTheme, home: Scaffold(body: FrameView(frame: frame))));
    Color? tileColor(String name) => tester.widget<Material>(find.ancestor(of: find.text(name), matching: find.byType(Material)).first).color;
    expect(tileColor('remaining length'), Colors.transparent);
    await tester.tap(find.text('00'));
    await tester.pump();
    expect(tileColor('remaining length'), lightTheme.colorScheme.primaryContainer);
  });

  testWidgets('a refused number shows under its field', (tester) async {
    final controller = SettingField(text: '70000');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LabeledField(controller: controller, label: 'Port'))));
    controller.refuse('a number 1..65535');
    await tester.pump();
    expect(find.text('a number 1..65535'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '1883');
    await tester.pump();
    expect(find.text('a number 1..65535'), findsNothing);
    controller.dispose();
  });

  testWidgets('a common value from the ▾ menu fills the field and clears its error', (tester) async {
    final controller = SettingField(text: '70');
    const presets = {'9600': 'Modbus', '115200': 'ESP32'};
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LabeledField(controller: controller, label: 'Baud rate', isNumber: true, presets: presets))));
    controller.refuse('a number 300..4000000');
    await tester.pump();
    await tester.tap(find.byTooltip('Common values'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('9600  ·  Modbus'));
    await tester.pumpAndSettle();
    expect(controller.text, '9600');
    expect(find.text('a number 300..4000000'), findsNothing);
    controller.dispose();
  });

  testWidgets('What if: breaking a byte makes the decoder report the CRC', (tester) async {
    final frame = decodeModbusRtu(Uint8List.fromList([0x11, 0x03, 0x00, 0x6b, 0x00, 0x03, 0x76, 0x87]), isRequest: true).frame;
    await tester.pumpWidget(MaterialApp(theme: lightTheme, home: Scaffold(body: FrameView(frame: frame))));
    await tester.tap(find.text('What if…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('wrong, expected'), findsNothing);
    await tester.enterText(find.byType(TextField), '11 03 00 6c 00 03 76 87');
    await tester.pump();
    expect(find.textContaining('wrong, expected'), findsWidgets);
  });

  testWidgets('Flow view pairs PINGREQ with PINGRESP and shows the reply time', (tester) async {
    var now = DateTime(2026, 11, 8, 12);
    final log = SessionLog(clock: () => now)..sent(decodeMqtt(Uint8List.fromList([0xc0, 0x00])).frame);
    now = now.add(const Duration(milliseconds: 42));
    log.received(decodeMqtt(Uint8List.fromList([0xd0, 0x00])).frame);
    await tester.pumpWidget(MaterialApp(theme: lightTheme, home: Scaffold(body: LogView(log: log, showTools: true))));
    await tester.tap(find.byTooltip('Show as a flow: phone ↔ device, replies paired'));
    await tester.pump();
    expect(find.textContaining('reply after 42 ms'), findsOneWidget);
    log.dispose();
  });

  testWidgets('a flags byte shows its bit map; a bus frame shows its wire view', (tester) async {
    final frame = describeI2cTransaction(address: 0x76, written: Uint8List.fromList([0xd0]), read: Uint8List.fromList([0x60]));
    await tester.pumpWidget(MaterialApp(theme: lightTheme, home: Scaffold(body: FrameView(frame: frame))));
    expect(find.text('On the wire'), findsOneWidget);
    expect(find.byType(WireView), findsOneWidget);
    final publish = decodeMqtt(encodeMqtt(MqttPublish(topic: 't', payload: Uint8List(1), qos: 1, packetId: 1))).frame;
    await tester.pumpWidget(MaterialApp(theme: lightTheme, home: Scaffold(body: FrameView(frame: publish))));
    expect(find.textContaining('bits 7–4  packet type = PUBLISH'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
