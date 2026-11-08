import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/bytes/hex.dart';
import 'package:protocol_lab/protocols/nfc/tag_identify.dart';

void main() {
  test('NTAG213 GET_VERSION reply (NXP NTAG21x datasheet)', () {
    final reply = parseHex('00 04 04 02 01 00 0f 03');
    expect(tagModelFromVersion(reply)?.name, 'NTAG213');
    final frame = describeNtagVersion(reply);
    expect(frame.error, isNull);
    expect(frame.summary, 'NTAG213: 144 user bytes, 45 pages');
    expect(frame.fields[6].value, '0x0f 128..256 bytes');
  });

  test('NTAG215 and NTAG216 by storage size byte', () {
    expect(tagModelFromVersion(parseHex('00 04 04 02 01 00 11 03'))?.totalPages, 135);
    expect(tagModelFromVersion(parseHex('00 04 04 02 01 00 13 03'))?.userBytes, 888);
  });

  test('unknown vendor gives no model, not a guess', () {
    expect(tagModelFromVersion(parseHex('00 05 04 02 01 00 0f 03')), isNull);
  });

  test('short reply is an error frame, not a throw', () {
    expect(describeNtagVersion(parseHex('00 04 04')).error, isNotNull);
  });

  test('tag info: UID, ATQA and SAK at their offsets', () {
    final frame = describeTagInfo(parseHex('04 a2 2c 3a 5b 61 80'), 'NfcA, MifareUltralight, Ndef', atqa: parseHex('44 00'), sak: 0x00);
    expect(frame.summary, 'tag 04:a2:2c:3a:5b:61:80 · MIFARE Ultralight / NTAG (Type 2)');
    final sak = frame.fields.firstWhere((field) => field.name == 'SAK');
    expect(sak.offset, 9);
  });

  test('tag info without NFC-A (ISO 15693)', () {
    final frame = describeTagInfo(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]), 'NfcV, Ndef');
    expect(frame.summary, endsWith('· NfcV, Ndef'));
    expect(frame.bytes.length, 8);
  });
}
