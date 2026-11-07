import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/bytes/hex.dart';
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
}
