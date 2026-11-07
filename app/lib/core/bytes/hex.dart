import 'dart:convert';
import 'dart:typed_data';

/// `[0x0a, 0x1b]` → `0a 1b`.
String toHex(List<int> bytes, {String separator = ' '}) => [
  for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0'),
].join(separator);

/// Forgiving hex input, the way people type it: `0a 1B`, `0x0a,0x1b`,
/// `0a1b`. Throws [FormatException] for an odd digit count or a non-hex
/// character.
Uint8List parseHex(String text) {
  final digits = text
      .replaceAll(RegExp(r'0x', caseSensitive: false), '')
      .replaceAll(RegExp(r'[\s,:;-]'), '');
  if (digits.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(digits)) {
    throw const FormatException('Not hex, or an odd number of digits');
  }
  return Uint8List.fromList([
    for (var index = 0; index < digits.length; index += 2)
      int.parse(digits.substring(index, index + 2), radix: 16),
  ]);
}

/// Printable ASCII, other bytes shown as `.`, like a hex dump's right column.
String toPrintable(List<int> bytes) => String.fromCharCodes([
  for (final byte in bytes) (byte >= 0x20 && byte < 0x7f) ? byte : 0x2e,
]);

/// Text with escapes a terminal user types: `\r`, `\n`, `\t`, `\xNN`, `\\`.
Uint8List parseEscapedText(String text) {
  final bytes = <int>[];
  for (var index = 0; index < text.length; index++) {
    final character = text.codeUnitAt(index);
    if (character != 0x5c || index + 1 >= text.length) {
      bytes.add(character & 0xff);
      continue;
    }
    final next = text[index + 1];
    index++;
    switch (next) {
      case 'r':
        bytes.add(0x0d);
      case 'n':
        bytes.add(0x0a);
      case 't':
        bytes.add(0x09);
      case '0':
        bytes.add(0x00);
      case '\\':
        bytes.add(0x5c);
      case 'x' when index + 2 < text.length:
        final value = int.tryParse(
          text.substring(index + 1, index + 3),
          radix: 16,
        );
        if (value == null) {
          bytes.addAll([0x5c, 0x78]);
        } else {
          bytes.add(value);
          index += 2;
        }
      default:
        bytes.addAll([0x5c, next.codeUnitAt(0) & 0xff]);
    }
  }
  return Uint8List.fromList(bytes);
}

/// One line of a classic hex dump per 16 bytes:
/// `0000  48 65 6c 6c 6f                                   Hello`.
String hexDump(List<int> bytes) {
  const bytesPerLine = 16;
  final lines = <String>[];
  for (var offset = 0; offset < bytes.length; offset += bytesPerLine) {
    final end = (offset + bytesPerLine).clamp(0, bytes.length);
    final chunk = bytes.sublist(offset, end);
    lines.add(
      '${offset.toRadixString(16).padLeft(4, '0')}  '
      '${toHex(chunk).padRight(bytesPerLine * 3 - 1)}  ${toPrintable(chunk)}',
    );
  }
  return lines.join('\n');
}

/// UTF-8 when it decodes cleanly and is printable, else hex: payloads are
/// often JSON text, sometimes raw sensor bytes.
String textOrHex(Uint8List bytes) {
  if (bytes.isEmpty) return '(empty)';
  try {
    final text = utf8.decode(bytes);
    if (!text.runes.any((rune) => rune < 0x20 && rune != 0x0a && rune != 0x0d && rune != 0x09)) {
      return '"$text"';
    }
  } on FormatException {
    // Not UTF-8: show hex.
  }
  return toHex(bytes);
}

String hex8(int value) => '0x${value.toRadixString(16).padLeft(2, '0')}';
String hex16(int value) => '0x${value.toRadixString(16).padLeft(4, '0')}';
