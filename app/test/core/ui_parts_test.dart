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
}
