import 'dart:typed_data';

import '../../core/bytes/hex.dart';
import '../../core/inspect/frame.dart';

/// ATT (Attribute Protocol, Bluetooth Core Vol 3 Part F): the packets GATT
/// is made of. Android's Bluetooth stack builds and parses them, and apps
/// only get the value, so these frames are rebuilt from what the app did.
/// The 2-byte attribute handle is not given to apps, so it is left out of
/// the bytes and named in the fields.
enum AttOpcode {
  readRequest(0x0a, 'Read Request', 'phone asks for the value'),
  readResponse(0x0b, 'Read Response', 'the value'),
  writeRequest(0x12, 'Write Request', 'value + wants a Write Response'),
  writeResponse(0x13, 'Write Response', 'device confirms the write'),
  writeCommand(0x52, 'Write Command', 'write without response: faster, no confirmation'),
  notification(0x1b, 'Handle Value Notification', 'device pushes a value, no ack'),
  indication(0x1d, 'Handle Value Indication', 'device pushes a value, wants a confirmation'),
  confirmation(0x1e, 'Handle Value Confirmation', 'phone confirms an indication');

  const AttOpcode(this.code, this.label, this.meaning);
  final int code;
  final String label;
  final String meaning;

  bool get hasHandle => this != readResponse && this != writeResponse && this != confirmation;
}

/// [exchange] pairs a request with its response in the Flow view (one key
/// per characteristic and operation).
Frame describeAtt(AttOpcode opcode, List<int> value, {required String characteristic, String? exchange, bool endsExchange = false, String what = ''}) {
  final bytes = Uint8List.fromList([opcode.code, ...value]);
  return Frame(
    protocol: 'ATT',
    summary: '${opcode.label}${what.isEmpty ? '' : ' $what'} $characteristic${value.isEmpty ? '' : ': ${textOrHex(Uint8List.fromList(value))}'}',
    bytes: bytes,
    fields: [
      Field('opcode', 0, 1, '${hex8(opcode.code)} ${opcode.label}', note: opcode.meaning, children: [
        Field('signed', 0, 1, (opcode.code >> 7) & 1 == 1 ? 'yes' : 'no', note: 'authentication signature appended', bitShift: 7, bitWidth: 1),
        Field('command', 0, 1, (opcode.code >> 6) & 1 == 1 ? 'yes' : 'no', note: 'commands get no response', bitShift: 6, bitWidth: 1),
        Field('method', 0, 1, hex8(opcode.code & 0x3f), bitShift: 0, bitWidth: 6),
      ]),
      if (opcode.hasHandle)
        Field('handle (2 bytes, little-endian)', 1, 0, 'not given to apps',
            note: 'the attribute\'s number in the device\'s table; Android maps the UUID $characteristic to it'),
      Field('value', 1, value.length, value.isEmpty ? '(none)' : textOrHex(Uint8List.fromList(value)),
          note: 'fits in ATT MTU − 3 bytes (20 by default, more after an MTU exchange)'),
    ],
    exchange: exchange,
    endsExchange: endsExchange,
  );
}
