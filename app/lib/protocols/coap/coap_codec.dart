import 'dart:convert';
import 'dart:typed_data';

import '../../core/inspect/frame.dart';
import '../field_reader.dart';

/// CoAP (RFC 7252): REST for small devices, over UDP port 5683.
///
///   byte 0  : version (2 bits, =1) | type (2) | token length (4)
///   byte 1  : code class.detail (3.5 bits): 0.01 GET … 2.05 Content, 4.04 Not Found
///   2..3    : message id (pairs ACK with CON, finds duplicates)
///   token   : 0..8 bytes (pairs response with request)
///   options : delta-encoded (number = previous + delta), then 0xFF + payload
enum CoapType { confirmable, nonConfirmable, acknowledgement, reset }

const coapTypeShort = ['CON', 'NON', 'ACK', 'RST'];

const coapMethods = {1: 'GET', 2: 'POST', 3: 'PUT', 4: 'DELETE'};

const coapOptionNames = {
  1: 'If-Match',
  3: 'Uri-Host',
  4: 'ETag',
  6: 'Observe',
  7: 'Uri-Port',
  8: 'Location-Path',
  11: 'Uri-Path',
  12: 'Content-Format',
  14: 'Max-Age',
  15: 'Uri-Query',
  17: 'Accept',
  23: 'Block2',
  27: 'Block1',
  60: 'Size1',
};

const coapContentFormats = {0: 'text/plain', 40: 'application/link-format', 41: 'application/xml', 42: 'application/octet-stream', 50: 'application/json', 60: 'application/cbor'};

/// `2.05` style text for a code byte.
String coapCodeText(int code) {
  final text = '${code >> 5}.${(code & 0x1f).toString().padLeft(2, '0')}';
  return coapMethods[code] ?? text;
}

class CoapOption {
  const CoapOption(this.number, this.value);
  final int number;
  final Uint8List value;
}

class CoapMessage {
  CoapMessage({
    required this.type,
    required this.code,
    required this.messageId,
    required this.token,
    this.options = const [],
    Uint8List? payload,
  }) : payload = payload ?? Uint8List(0);

  /// A request for `coap://host/path?query`, split into Uri-Path and
  /// Uri-Query options as the RFC asks.
  factory CoapMessage.request({
    required int method,
    required String path,
    required int messageId,
    required Uint8List token,
    bool confirmable = true,
    Uint8List? payload,
    int? contentFormat,
    bool observe = false,
  }) {
    final uri = Uri.parse(path.startsWith('/') ? path : '/$path');
    final options = <CoapOption>[
      if (observe) CoapOption(6, Uint8List(0)),
      for (final segment in uri.pathSegments.where((segment) => segment.isNotEmpty))
        CoapOption(11, Uint8List.fromList(utf8.encode(segment))),
      if (contentFormat != null) CoapOption(12, _uintBytes(contentFormat)),
      for (final query in uri.query.split('&').where((query) => query.isNotEmpty))
        CoapOption(15, Uint8List.fromList(utf8.encode(query))),
    ];
    return CoapMessage(
      type: confirmable ? CoapType.confirmable : CoapType.nonConfirmable,
      code: method,
      messageId: messageId,
      token: token,
      options: options,
      payload: payload,
    );
  }

  final CoapType type;
  final int code;
  final int messageId;
  final Uint8List token;
  final List<CoapOption> options;
  final Uint8List payload;
}

Uint8List _uintBytes(int value) {
  if (value == 0) return Uint8List(0);
  final bytes = <int>[];
  var left = value;
  while (left > 0) {
    bytes.insert(0, left & 0xff);
    left >>= 8;
  }
  return Uint8List.fromList(bytes);
}

int _uintValue(Uint8List bytes) => bytes.fold(0, (value, byte) => value << 8 | byte);

Uint8List encodeCoap(CoapMessage message) {
  if (message.token.length > 8) throw ArgumentError('token is 0..8 bytes');
  final out = BytesBuilder()
    ..addByte(0x40 | (message.type.index << 4) | message.token.length)
    ..addByte(message.code)
    ..addByte(message.messageId >> 8 & 0xff)
    ..addByte(message.messageId & 0xff)
    ..add(message.token);
  final sorted = [...message.options]..sort((left, right) => left.number.compareTo(right.number));
  var previous = 0;
  for (final option in sorted) {
    final delta = option.number - previous;
    previous = option.number;
    final (deltaNibble, deltaExtra) = _nibble(delta);
    final (lengthNibble, lengthExtra) = _nibble(option.value.length);
    out
      ..addByte(deltaNibble << 4 | lengthNibble)
      ..add(deltaExtra)
      ..add(lengthExtra)
      ..add(option.value);
  }
  if (message.payload.isNotEmpty) {
    out
      ..addByte(0xff)
      ..add(message.payload);
  }
  return out.toBytes();
}

/// Option delta/length: 0..12 in the nibble, 13 → +1 byte (value-13),
/// 14 → +2 bytes (value-269). 15 is reserved for the payload marker.
(int, List<int>) _nibble(int value) {
  if (value < 13) return (value, const []);
  if (value < 269) return (13, [value - 13]);
  final extended = value - 269;
  return (14, [extended >> 8, extended & 0xff]);
}

class CoapDecoded {
  const CoapDecoded(this.message, this.frame);
  final CoapMessage? message;
  final Frame frame;
}

CoapDecoded decodeCoap(Uint8List bytes) {
  final reader = FieldReader(bytes);
  try {
    final first = reader.flags('header', [
      BitField('version', 6, width: 2, note: 'always 1'),
      BitField('type', 4, width: 2, describe: (type) => '${coapTypeShort[type]} (${CoapType.values[type].name})',
          note: 'CON wants an ACK; NON does not'),
      BitField('token length', 0, width: 4),
    ]);
    if (first >> 6 != 1) throw FormatException('version ${first >> 6}, not 1');
    final tokenLength = first & 0x0f;
    if (tokenLength > 8) throw const FormatException('token length over 8');
    final code = reader.uint8('code', describe: (code) => '${coapCodeText(code)} (class ${code >> 5}, detail ${code & 0x1f})',
        note: '0 = request, 2 = success, 4 = client error, 5 = server error');
    final messageId = reader.uint16('message id');
    final token = reader.take(tokenLength, 'token', note: 'the response repeats it');
    final options = <CoapOption>[];
    var number = 0;
    Uint8List payload = Uint8List(0);
    while (!reader.isDone) {
      final start = reader.offset;
      final header = reader.take(1, 'option header')[0];
      reader.fields.removeLast();
      if (header == 0xff) {
        reader.add('payload marker', start, '0xff');
        if (reader.isDone) throw const FormatException('payload marker with no payload');
        payload = reader.rest('payload', describe: textOrHex);
        break;
      }
      int extended(int nibble, String what) {
        if (nibble == 15) throw FormatException('$what nibble 15 is reserved');
        if (nibble == 13) return reader.take(1, '$what extra')[0] + 13;
        if (nibble == 14) {
          final extra = reader.take(2, '$what extra');
          return (extra[0] << 8 | extra[1]) + 269;
        }
        return nibble;
      }

      final fieldCount = reader.fields.length;
      final delta = extended(header >> 4, 'delta');
      final length = extended(header & 0x0f, 'length');
      final extraFields = reader.fields.sublist(fieldCount);
      reader.fields.length = fieldCount;
      final previous = number;
      number += delta;
      final valueStart = reader.offset;
      final value = reader.take(length, 'value');
      reader.fields.removeLast();
      options.add(CoapOption(number, value));
      final name = coapOptionNames[number] ?? 'option $number';
      reader.add(name, start, _optionText(number, value), note: 'option $number = previous $previous + delta $delta', children: [
        Field('option header', start, 1, hex8(header), children: [
          Field('delta', start, 1, '${header >> 4}${header >> 4 >= 13 ? ' (extended below)' : ''}',
              note: 'number − previous number: options must be sorted', bitShift: 4, bitWidth: 4),
          Field('length', start, 1, '${header & 0x0f}${header & 0x0f >= 13 ? ' (extended below)' : ''}', note: 'value bytes', bitShift: 0, bitWidth: 4),
        ]),
        ...extraFields,
        Field('value', valueStart, length, _optionText(number, value)),
      ]);
    }
    final message = CoapMessage(
      type: CoapType.values[(first >> 4) & 3],
      code: code,
      messageId: messageId,
      token: token,
      options: options,
      payload: payload,
    );
    final path = options.where((option) => option.number == 11).map((option) => utf8.decode(option.value, allowMalformed: true)).join('/');
    return CoapDecoded(
      message,
      Frame(
        protocol: 'CoAP',
        summary: '${coapTypeShort[message.type.index]} ${coapCodeText(code)} #$messageId${path.isEmpty ? '' : ' /$path'}'
            '${payload.isEmpty ? '' : ' ${textOrHex(payload)}'}',
        bytes: bytes,
        fields: reader.fields,
        // CON → ACK (or RST) share the message id; the ACK closes it.
        exchange: 'CoAP #$messageId',
        endsExchange: message.type == CoapType.acknowledgement || message.type == CoapType.reset,
        redecode: _redecode,
      ),
    );
  } on FormatException catch (error) {
    return CoapDecoded(null, Frame(protocol: 'CoAP', summary: 'bad message: ${error.message}', bytes: bytes, fields: reader.fields, error: error.message, redecode: _redecode));
  }
}

Frame _redecode(Uint8List bytes) => decodeCoap(bytes).frame;

String _optionText(int number, Uint8List value) => switch (number) {
  3 || 8 || 11 || 15 => '"${utf8.decode(value, allowMalformed: true)}"',
  12 || 17 => '${_uintValue(value)} ${coapContentFormats[_uintValue(value)] ?? ''}'.trim(),
  6 || 7 || 14 || 60 => '${_uintValue(value)}',
  _ => textOrHex(value),
};
