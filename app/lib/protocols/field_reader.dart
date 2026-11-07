import 'dart:typed_data';

import '../core/bytes/hex.dart';

export '../core/bytes/hex.dart' show hex16, hex8, textOrHex;
import '../core/inspect/frame.dart';

/// Reads a frame front to back and records a [Field] for each part read, so
/// one pass both decodes the frame and builds its Inside view. Reading past
/// the end throws [FormatException]; the fields read so far stay in
/// [fields] for the error view.
class FieldReader {
  FieldReader(this.bytes, {this.endian = Endian.big});

  final Uint8List bytes;
  final Endian endian;
  final fields = <Field>[];
  int offset = 0;

  int get remaining => bytes.length - offset;
  bool get isDone => offset >= bytes.length;

  void _need(int count, String name) {
    if (count < 0 || offset + count > bytes.length) {
      throw FormatException(
        '$name: needs $count bytes at offset $offset, frame has ${bytes.length}',
      );
    }
  }

  /// Adds a field for bytes the caller already read (for example a varint).
  Field add(
    String name,
    int start,
    String value, {
    String note = '',
    List<Field> children = const [],
  }) {
    final field = Field(
      name,
      start,
      offset - start,
      value,
      note: note,
      children: children,
    );
    fields.add(field);
    return field;
  }

  int peekUint8() {
    _need(1, 'byte');
    return bytes[offset];
  }

  int uint8(String name, {String Function(int)? describe, String note = ''}) {
    _need(1, name);
    final value = bytes[offset];
    offset += 1;
    add(name, offset - 1, describe?.call(value) ?? '$value', note: note);
    return value;
  }

  int uint16(String name, {String Function(int)? describe, String note = ''}) {
    _need(2, name);
    final value = ByteData.sublistView(bytes, offset, offset + 2).getUint16(0, endian);
    offset += 2;
    add(name, offset - 2, describe?.call(value) ?? '$value', note: note);
    return value;
  }

  int uint32(String name, {String Function(int)? describe, String note = ''}) {
    _need(4, name);
    final value = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, endian);
    offset += 4;
    add(name, offset - 4, describe?.call(value) ?? '$value', note: note);
    return value;
  }

  /// A byte whose bits mean different things: one child field per bit group.
  int flags(String name, List<BitField> bits, {String note = ''}) {
    _need(1, name);
    final value = bytes[offset];
    offset += 1;
    add(
      name,
      offset - 1,
      '0b${value.toRadixString(2).padLeft(8, '0')}',
      note: note,
      children: [
        for (final bit in bits)
          Field(
            bit.name,
            offset - 1,
            1,
            bit.describe((value >> bit.shift) & ((1 << bit.width) - 1)),
            note: bit.note,
          ),
      ],
    );
    return value;
  }

  Uint8List take(int count, String name, {String Function(Uint8List)? describe, String note = ''}) {
    _need(count, name);
    final value = Uint8List.sublistView(bytes, offset, offset + count);
    offset += count;
    add(
      name,
      offset - count,
      describe?.call(value) ?? (count == 0 ? '(empty)' : toHex(value)),
      note: note,
    );
    return value;
  }

  Uint8List rest(String name, {String Function(Uint8List)? describe, String note = ''}) =>
      take(remaining, name, describe: describe, note: note);
}

class BitField {
  const BitField(this.name, this.shift, {this.width = 1, this.note = '', String Function(int)? describe}) : _describe = describe; // ignore: prefer_initializing_formals

  final String name;
  final int shift;
  final int width;
  final String note;
  final String Function(int)? _describe;

  String describe(int value) => _describe?.call(value) ?? '$value';
}
