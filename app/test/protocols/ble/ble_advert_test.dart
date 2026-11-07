import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/bytes/hex.dart';
import 'package:protocol_lab/protocols/ble/ble_advert.dart';

void main() {
  test('decode a typical advert: flags, name, 16-bit UUID, Espressif data', () {
    final bytes = parseHex('02 01 06  05 09 4c 61 62 31  03 03 0f 18  05 ff e5 02 01 02');
    final frame = decodeAdvert(bytes);
    expect(frame.error, isNull);
    expect(frame.fields.map((field) => field.value), [
      'LE general discoverable, BR/EDR not supported',
      '"Lab1"',
      '180f',
      'Espressif: 01 02',
    ]);
    expect(frame.fields[1].offset, 3);
    expect(frame.fields[1].length, 6);
  });

  test('encode then decode keeps 16- and 128-bit UUIDs', () {
    final bytes = encodeAdvert(AdvertParts(
      name: 'bridge',
      serviceUuids: const ['0000180f-0000-1000-8000-00805f9b34fb', '6e400001-b5a3-f393-e0a9-e50e24dcca9e'],
      manufacturerData: {0x02e5: Uint8List.fromList([9])},
    ));
    final values = decodeAdvert(bytes).fields.map((field) => field.value).toList();
    expect(values, ['"bridge"', '180f', '6e400001-b5a3-f393-e0a9-e50e24dcca9e', 'Espressif: 09']);
  });

  test('a structure longer than the data is an error, not a crash', () {
    expect(decodeAdvert(parseHex('05 09 41')).error, isNotNull);
  });

  test('shortUuid', () {
    expect(shortUuid('0000180F-0000-1000-8000-00805F9B34FB'), '180f');
    expect(shortUuid('6e400001-b5a3-f393-e0a9-e50e24dcca9e'), '6e400001-b5a3-f393-e0a9-e50e24dcca9e');
  });
}
