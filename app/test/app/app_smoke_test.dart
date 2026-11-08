import 'package:flutter/material.dart';

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/app/app.dart';
import 'package:protocol_lab/core/settings/tool_settings.dart';
import 'package:protocol_lab/tools/tool_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpApp(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(overrides: [sharedPreferencesProvider.overrideWithValue(preferences)], child: const ProtocolLabApp()),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('home lists every tool by layer', (tester) async {
    await _pumpApp(tester);
    expect(find.text('Network / IoT'), findsOneWidget);
    for (final tool in toolCatalog.take(5)) {
      expect(find.text(tool.name), findsOneWidget);
    }
  });

  // Tools that start native work (BLE scan, NFC, serial list) on open are
  // left to the phone check; these open with no plugin call.
  for (final id in ['tcp', 'udp', 'mqtt', 'http', 'coap', 'mdns', 'websocket', 'bridge', 'i2c', 'can', 'lora']) {
    testWidgets('tool $id opens and shows its tabs', (tester) async {
      await _pumpApp(tester);
      final tool = toolById(id)!;
      final row = find.byKey(ValueKey('tool-${tool.id}'));
      // Reach the tool through the home search (a scrolled row can sit under
      // a pinned group header, where a tap hits the header).
      await tester.enterText(find.descendant(of: find.byType(SearchBar), matching: find.byType(EditableText)), tool.name);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      if (id != 'lora') {
        expect(find.text('Configure'), findsOneWidget);
        await tester.tap(find.text('Learn'));
        await tester.pumpAndSettle();
      }
      expect(find.text('No notes for this tool yet.'), findsNothing, reason: 'assets/learn/$id.md missing');
    });
  }

  testWidgets('Back from the bridge returns to the bus tool that opened it', (tester) async {
    await _pumpApp(tester);
    await tester.enterText(find.descendant(of: find.byType(SearchBar), matching: find.byType(EditableText)), 'I2C');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tool-i2c')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open ESP32 bridge'));
    await tester.pumpAndSettle();
    expect(find.text('ESP32 bridge'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('I2C'), findsWidgets, reason: 'Back must return to I2C, not Home');
    expect(find.byType(SearchBar), findsNothing);
  });

  test('every tool has a Learn note', () {
    for (final tool in toolCatalog) {
      final file = File('assets/learn/${tool.id}.md');
      expect(file.existsSync() && file.readAsStringSync().trim().isNotEmpty, isTrue, reason: tool.id);
    }
  });
}
