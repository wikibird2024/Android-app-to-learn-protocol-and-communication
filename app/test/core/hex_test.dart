import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/bytes/hex.dart';

void main() {
  test('parseHex forgives how people type hex', () {
    for (final text in ['0a 1B', '0x0a,0x1b', '0a1b', ' 0A:1b ']) {
      expect(parseHex(text), [0x0a, 0x1b], reason: text);
    }
    expect(() => parseHex('abc'), throwsFormatException);
    expect(() => parseHex('zz'), throwsFormatException);
  });

  test('escaped text', () {
    expect(parseEscapedText(r'AT\r\n'), [0x41, 0x54, 0x0d, 0x0a]);
    expect(parseEscapedText(r'\x41\x7e'), [0x41, 0x7e]);
    expect(parseEscapedText(r'\xZZ'), [0x5c, 0x78, 0x5a, 0x5a]);
    expect(parseEscapedText(r'end\'), [0x65, 0x6e, 0x64, 0x5c]);
  });

  test('hex dump', () {
    expect(hexDump('Hello'.codeUnits), '0000  48 65 6c 6c 6f${' ' * 33}  Hello');
  });
}
