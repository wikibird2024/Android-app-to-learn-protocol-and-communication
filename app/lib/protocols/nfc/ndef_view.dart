import 'dart:convert';
import 'dart:typed_data';

import '../../core/inspect/frame.dart';
import '../field_reader.dart';
import 'ndef_build.dart';

/// NDEF (NFC Forum Data Exchange Format): the message a phone reads from a
/// tag. Parsing and encoding for real use comes from the community package
/// ndef_record (re-exported by nfc_manager); this explains the bytes.
///
///   per record: [MB ME CF SR IL TNF][type len][payload len 1 or 4][id len?]
///               [type][id][payload]
const ndefTypeNameFormats = ['empty', 'well-known', 'media type', 'absolute URI', 'external', 'unknown', 'unchanged', 'reserved'];

/// URI record prefix codes (NFC Forum URI RTD), the common ones.
const ndefUriPrefixes = {
  0x00: '',
  0x01: 'http://www.',
  0x02: 'https://www.',
  0x03: 'http://',
  0x04: 'https://',
  0x05: 'tel:',
  0x06: 'mailto:',
};

Frame describeNdef(Uint8List bytes) {
  final reader = FieldReader(bytes);
  final summaries = <String>[];
  try {
    var index = 0;
    while (!reader.isDone) {
      final header = reader.flags('record ${index + 1} header', [
        const BitField('MB message begin', 7),
        const BitField('ME message end', 6),
        const BitField('CF chunked', 5),
        const BitField('SR short record', 4, note: 'payload length is 1 byte, not 4'),
        const BitField('IL id present', 3),
        BitField('TNF', 0, width: 3, describe: (tnf) => '$tnf ${ndefTypeNameFormats[tnf]}'),
      ]);
      final typeLength = reader.uint8('type length');
      final payloadLength = header & 0x10 != 0 ? reader.uint8('payload length') : reader.uint32('payload length');
      final idLength = header & 0x08 != 0 ? reader.uint8('id length') : 0;
      final type = reader.take(typeLength, 'type', describe: (value) => '"${ascii.decode(value, allowInvalid: true)}"');
      if (idLength > 0) reader.take(idLength, 'id');
      final payload = reader.take(payloadLength, 'payload', describe: (value) => _payloadText(header & 7, type, value));
      summaries.add(_payloadText(header & 7, type, payload));
      index++;
      if (header & 0x40 != 0) break;
    }
    if (!reader.isDone) reader.rest('after message end', note: 'tag memory past the NDEF message');
    return Frame(protocol: 'NDEF', summary: summaries.join(' · '), bytes: bytes, fields: reader.fields);
  } on FormatException catch (error) {
    return Frame(protocol: 'NDEF', summary: 'bad NDEF', bytes: bytes, fields: reader.fields, error: error.message);
  }
}

String _payloadText(int tnf, Uint8List type, Uint8List payload) {
  if (tnf == 0) return 'empty record';
  if (tnf == 2 && ascii.decode(type, allowInvalid: true) == wifiMimeType) {
    final attributes = wscAttributes(payload);
    final ssid = utf8.decode(attributes[wscSsid] ?? [], allowMalformed: true);
    final authType = attributes[wscAuthType];
    final isOpen = authType != null && authType.length == 2 && authType[1] == 0x01;
    return 'Wi-Fi "$ssid" ${isOpen ? 'open' : 'with password'}';
  }
  if (tnf == 1 && type.length == 1 && payload.isNotEmpty) {
    if (type[0] == 0x54) {
      // Text: status byte (bit 7 UTF-16, bits 5..0 language length), language, text.
      final languageLength = payload[0] & 0x3f;
      if (1 + languageLength <= payload.length) {
        final language = ascii.decode(payload.sublist(1, 1 + languageLength), allowInvalid: true);
        final text = utf8.decode(payload.sublist(1 + languageLength), allowMalformed: true);
        return 'Text [$language] "$text"';
      }
    }
    if (type[0] == 0x55) {
      final prefix = ndefUriPrefixes[payload[0]] ?? '';
      return 'URI $prefix${utf8.decode(payload.sublist(1), allowMalformed: true)}';
    }
  }
  return textOrHex(payload);
}
