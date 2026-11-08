import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/bytes/hex.dart';
import 'package:protocol_lab/protocols/nfc/ndef_build.dart';
import 'package:protocol_lab/protocols/nfc/ndef_view.dart';

void main() {
  test('URI record https://example.com', () {
    // d1 = MB ME SR TNF 1; type len 1; payload len 0c; "U"; 04 = https://
    final frame = describeNdef(parseHex('d1 01 0c 55 04 65 78 61 6d 70 6c 65 2e 63 6f 6d'));
    expect(frame.error, isNull);
    expect(frame.summary, 'URI https://example.com');
  });

  test('Text record', () {
    final frame = describeNdef(parseHex('d1 01 05 54 02 65 6e 68 69'));
    expect(frame.summary, 'Text [en] "hi"');
  });

  test('cut-off record is an error', () {
    expect(describeNdef(parseHex('d1 01 0c 55 04')).error, isNotNull);
  });

  test('URI payload uses the longest prefix', () {
    expect(toHex(uriPayload('https://www.x.io')), '02 78 2e 69 6f');
    expect(toHex(uriPayload('https://x.io')), '04 78 2e 69 6f');
    expect(uriPayload('ftp://x')[0], 0x00);
  });

  test('Text payload: status byte is the language length', () {
    expect(toHex(textPayload('hi')), '02 65 6e 68 69');
  });

  test('empty record (erase) decodes', () {
    expect(describeNdef(parseHex('d0 00 00')).summary, 'empty record');
  });

  test('Wi-Fi record round trip', () {
    final payload = wifiPayload(ssid: 'bench', password: 'secret12');
    final attributes = wscAttributes(payload);
    expect(String.fromCharCodes(attributes[wscSsid]!), 'bench');
    expect(toHex(attributes[wscAuthType]!), '00 20');
    final type = 'application/vnd.wfa.wsc'.codeUnits;
    // d2 = MB ME SR TNF 2 (media type)
    final record = [0xd2, type.length, payload.length, ...type, ...payload];
    expect(describeNdef(Uint8List.fromList(record)).summary, 'Wi-Fi "bench" with password');
    expect(toHex(wscAttributes(wifiPayload(ssid: 'cafe', password: ''))[wscAuthType]!), '00 01');
  });

  test('cut-off Wi-Fi payload does not throw', () {
    expect(wscAttributes(parseHex('10 0e 00 40 10 45')), isEmpty);
  });
}
