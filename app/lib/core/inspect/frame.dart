import 'dart:typed_data';

import '../bytes/hex.dart';

/// One named part of a frame: where it sits in the bytes and what it means.
/// This is the "Inside" view's unit: every decoder explains its bytes as a
/// list of fields.
class Field {
  const Field(
    this.name,
    this.offset,
    this.length,
    this.value, {
    this.note = '',
    this.children = const [],
  });

  final String name;

  /// Byte offset in the frame. Bits inside a byte share the byte's offset.
  final int offset;
  final int length;

  /// The decoded value as people read it: `CONNECT`, `0x1f`, `"sensors/1"`.
  final String value;

  /// Why the field matters, in a few words.
  final String note;

  /// Bit fields of a flags byte, or the parts of a nested structure.
  final List<Field> children;

  int get end => offset + length;

  @override
  String toString() => '$name@$offset+$length=$value';
}

/// A decoded frame. A decoder that meets bytes it cannot understand still
/// returns a frame, with an [error] and the fields it got through.
class Frame {
  const Frame({
    required this.protocol,
    required this.summary,
    required this.bytes,
    this.fields = const [],
    this.error,
  });

  /// Raw bytes with only a single "payload" field, for links with no codec.
  /// The summary is the text when it is printable, else hex.
  factory Frame.raw(String protocol, Uint8List bytes, {String summary = ''}) =>
      Frame(
        protocol: protocol,
        summary: summary.isEmpty ? textOrHex(bytes) : summary,
        bytes: bytes,
        fields: [Field('payload', 0, bytes.length, '${bytes.length} bytes')],
      );

  final String protocol;

  /// One line for the log list, for example `PUBLISH sensors/1 (QoS 1)`.
  final String summary;
  final Uint8List bytes;
  final List<Field> fields;

  /// Set when the bytes broke a rule of the protocol.
  final String? error;
}
