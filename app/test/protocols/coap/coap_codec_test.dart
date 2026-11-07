import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/bytes/hex.dart';
import 'package:protocol_lab/protocols/coap/coap_codec.dart';

void main() {
  test('GET /sensors/temp encodes like RFC 7252', () {
    final bytes = encodeCoap(CoapMessage.request(
      method: 1,
      path: '/sensors/temp',
      messageId: 0x1234,
      token: Uint8List.fromList([0xab]),
    ));
    // 41 = v1 CON tkl 1; 01 GET; 12 34 id; ab token;
    // b7 = delta 11 (Uri-Path) len 7 "sensors"; 04 = delta 0 len 4 "temp"
    expect(toHex(bytes), '41 01 12 34 ab b7 73 65 6e 73 6f 72 73 04 74 65 6d 70');
  });

  test('response with Content-Format and payload decodes', () {
    final bytes = encodeCoap(CoapMessage(
      type: CoapType.acknowledgement,
      code: 0x45, // 2.05 Content
      messageId: 0x1234,
      token: Uint8List.fromList([0xab]),
      options: [CoapOption(12, Uint8List.fromList([50]))],
      payload: Uint8List.fromList(utf8.encode('{"t":21}')),
    ));
    final decoded = decodeCoap(bytes);
    expect(decoded.frame.error, isNull);
    expect(decoded.frame.summary, 'ACK 2.05 #4660 "{"t":21}"');
    expect(decoded.frame.fields.any((field) => field.value == '50 application/json'), isTrue);
  });

  test('long option uses the 13 extension', () {
    final path = 'a' * 20;
    final decoded = decodeCoap(encodeCoap(CoapMessage.request(method: 1, path: path, messageId: 1, token: Uint8List(0))));
    expect(utf8.decode(decoded.message!.options.single.value), path);
  });

  test('bad messages give an error frame', () {
    for (final hex in ['', '81 01 00 01', '49 01 00 01', '40 01 00 01 ff', '40 01 00 01 f0']) {
      expect(decodeCoap(parseHex(hex)).frame.error, isNotNull, reason: hex);
    }
  });
}
