import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/inspect/frame.dart';
import '../field_reader.dart';

/// WebSocket (RFC 6455) written by hand, so the Inside view shows every
/// frame byte: FIN, opcode, MASK, the 7/16/64-bit length, the mask key.

/// The fixed GUID every server appends to the client's key (RFC 6455 1.3).
const wsGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/// What the server must answer in Sec-WebSocket-Accept: base64(SHA-1(key +
/// GUID)). It proves the server read this handshake (not a cached page).
String wsAcceptFor(String key) => base64.encode(sha1.convert(utf8.encode('$key$wsGuid')).bytes);

enum WsOpcode {
  continuation(0x0),
  text(0x1),
  binary(0x2),
  close(0x8),
  ping(0x9),
  pong(0xa);

  const WsOpcode(this.code);
  final int code;

  static WsOpcode? fromCode(int code) {
    for (final opcode in values) {
      if (opcode.code == code) return opcode;
    }
    return null;
  }
}

/// One frame. Clients MUST mask what they send ([maskKey] of 4 bytes);
/// servers must not.
Uint8List encodeWsFrame(WsOpcode opcode, List<int> payload, {List<int>? maskKey, bool isFinal = true}) {
  final out = BytesBuilder();
  out.addByte((isFinal ? 0x80 : 0) | opcode.code);
  final maskBit = maskKey == null ? 0 : 0x80;
  if (payload.length < 126) {
    out.addByte(maskBit | payload.length);
  } else if (payload.length < 65536) {
    out
      ..addByte(maskBit | 126)
      ..add((ByteData(2)..setUint16(0, payload.length)).buffer.asUint8List());
  } else {
    out
      ..addByte(maskBit | 127)
      ..add((ByteData(8)..setUint64(0, payload.length)).buffer.asUint8List());
  }
  if (maskKey == null) {
    out.add(payload);
  } else {
    out.add(maskKey);
    out.add([for (var index = 0; index < payload.length; index++) payload[index] ^ maskKey[index % 4]]);
  }
  return out.toBytes();
}

class WsDecoded {
  const WsDecoded(this.frame, {this.opcode, this.payload, this.isFinal = true});
  final Frame frame;
  final WsOpcode? opcode;

  /// Unmasked payload; null when the frame is broken.
  final Uint8List? payload;
  final bool isFinal;
}

String _yesNo(int bit) => bit == 1 ? 'yes' : 'no';

WsDecoded decodeWsFrame(Uint8List bytes) {
  final reader = FieldReader(bytes);
  try {
    final first = reader.flags('byte 0', [
      BitField('FIN', 7, note: 'last fragment of the message', describe: _yesNo),
      BitField('RSV1-3', 4, width: 3, note: 'extensions only (permessage-deflate uses RSV1)'),
      BitField('opcode', 0, width: 4, describe: (code) => '$code ${WsOpcode.fromCode(code)?.name ?? 'reserved'}',
          note: '1 text · 2 binary · 8 close · 9 ping · 10 pong · 0 continuation'),
    ]);
    final second = reader.flags('byte 1', [
      BitField('MASK', 7, note: 'client → server frames must be masked', describe: _yesNo),
      BitField('length', 0, width: 7, describe: (length) => length < 126 ? '$length' : length == 126 ? '126: real length in the next 2 bytes' : '127: real length in the next 8 bytes'),
    ]);
    var length = second & 0x7f;
    if (length == 126) {
      length = reader.uint16('extended length', note: '16-bit, big-endian');
    } else if (length == 127) {
      final start = reader.offset;
      final wide = reader.take(8, 'extended length');
      reader.fields.removeLast();
      length = ByteData.sublistView(wide).getUint64(0);
      reader.add('extended length', start, '$length', note: '64-bit, big-endian');
    }
    final isMasked = second & 0x80 != 0;
    final maskKey = isMasked ? reader.take(4, 'mask key', note: 'random per frame, so proxies cannot be fooled by crafted bytes') : null;
    final opcode = WsOpcode.fromCode(first & 0x0f);
    final raw = reader.take(length, 'payload');
    reader.fields.removeLast();
    final payload = maskKey == null ? raw : Uint8List.fromList([for (var index = 0; index < raw.length; index++) raw[index] ^ maskKey[index % 4]]);
    final shown = opcode == WsOpcode.close && payload.length >= 2
        ? 'code ${payload[0] << 8 | payload[1]} ${utf8.decode(payload.sublist(2), allowMalformed: true)}'.trim()
        : opcode == WsOpcode.text
        ? '"${utf8.decode(payload, allowMalformed: true)}"'
        : textOrHex(payload);
    reader.add('payload', reader.offset - length, shown, note: isMasked ? 'shown unmasked: each byte XOR mask key[i % 4]' : '');
    if (!reader.isDone) throw const FormatException('extra bytes after the frame');
    if (opcode == null) throw FormatException('reserved opcode ${first & 0x0f}');
    final isControl = opcode.code >= 8;
    return WsDecoded(
      Frame(
        protocol: 'WebSocket',
        summary: '${opcode.name.toUpperCase()}${first & 0x80 == 0 ? ' (fragment)' : ''} $shown',
        bytes: bytes,
        fields: reader.fields,
        exchange: isControl ? 'WebSocket ${opcode == WsOpcode.close ? 'close' : 'ping'}' : null,
        endsExchange: opcode == WsOpcode.pong,
        redecode: _redecode,
      ),
      opcode: opcode,
      payload: payload,
      isFinal: first & 0x80 != 0,
    );
  } on FormatException catch (error) {
    return WsDecoded(Frame(protocol: 'WebSocket', summary: 'bad frame: ${error.message}', bytes: bytes, fields: reader.fields, error: error.message, redecode: _redecode));
  }
}

Frame _redecode(Uint8List bytes) => decodeWsFrame(bytes).frame;

/// Joins TCP chunks into whole frames, using the length in bytes 1..9.
class WsFrameSplitter {
  Uint8List _buffer = Uint8List(0);

  List<Uint8List> add(List<int> chunk) {
    _buffer = Uint8List.fromList([..._buffer, ...chunk]);
    final frames = <Uint8List>[];
    var start = 0;
    while (_buffer.length - start >= 2) {
      final second = _buffer[start + 1];
      var header = 2;
      var length = second & 0x7f;
      if (length == 126) {
        if (_buffer.length - start < 4) break;
        length = _buffer[start + 2] << 8 | _buffer[start + 3];
        header = 4;
      } else if (length == 127) {
        if (_buffer.length - start < 10) break;
        length = ByteData.sublistView(_buffer, start + 2, start + 10).getUint64(0);
        header = 10;
      }
      if (second & 0x80 != 0) header += 4;
      if (_buffer.length - start < header + length) break;
      frames.add(Uint8List.sublistView(_buffer, start, start + header + length));
      start += header + length;
    }
    _buffer = Uint8List.fromList(_buffer.sublist(start));
    return frames;
  }
}
