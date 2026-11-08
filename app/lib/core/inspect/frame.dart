import 'dart:typed_data';

import '../bytes/hex.dart';
import 'wire_trace.dart';

export 'wire_trace.dart';

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
    this.bitShift,
    this.bitWidth = 0,
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

  /// For a bit field: its lowest bit inside the byte at [offset] (0 = LSB)
  /// and how many bits it has. Null for whole-byte fields. The Inside view
  /// draws these as a `7 6 5 4 3 2 1 0` bit map.
  final int? bitShift;
  final int bitWidth;

  bool get isBits => bitShift != null;
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
    this.exchange,
    this.endsExchange = false,
    this.wire,
    this.redecode,
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

  /// Which request/reply this frame belongs to, for the Flow view: frames
  /// with the same key are one exchange (MQTT packet id 7, CoAP message id,
  /// Modbus transaction, bridge request id). Null: not part of one.
  final String? exchange;

  /// This frame finishes its exchange (CONNACK, PUBCOMP, CoAP ACK, Modbus
  /// reply). The next frame with the same key starts a new exchange.
  final bool endsExchange;

  /// How the bytes look as signals on the wire (UART, I2C, SPI, CAN,
  /// 1-Wire), drawn from the bytes. Null for protocols with no wire of
  /// their own (TCP, UDP: the phone's network stack owns those).
  final WireTrace? wire;

  /// Decodes changed bytes the same way, for the "what if" editor. Null
  /// when the frame cannot be rebuilt from bytes alone.
  final Frame Function(Uint8List bytes)? redecode;

  Frame copyWith({String? summary, List<Field>? fields, String? exchange, bool? endsExchange, WireTrace? wire, Frame Function(Uint8List bytes)? redecode}) => Frame(
    protocol: protocol,
    summary: summary ?? this.summary,
    bytes: bytes,
    fields: fields ?? this.fields,
    error: error,
    exchange: exchange ?? this.exchange,
    endsExchange: endsExchange ?? this.endsExchange,
    wire: wire ?? this.wire,
    redecode: redecode ?? this.redecode,
  );
}
