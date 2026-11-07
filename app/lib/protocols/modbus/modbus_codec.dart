import 'dart:typed_data';

import '../../core/inspect/frame.dart';
import '../field_reader.dart';

/// Modbus application protocol (modbus.org, V1.1b3). One PDU, two wrappers:
///
///   RTU (RS-485 / serial): [unit][PDU][CRC16 low, high]   end = 3.5 chars of silence
///   TCP (port 502)       : [transaction][protocol=0][length][unit][PDU]
///   PDU                  : [function code][data]
enum ModbusFunction {
  readCoils(1, 'Read Coils'),
  readDiscreteInputs(2, 'Read Discrete Inputs'),
  readHoldingRegisters(3, 'Read Holding Registers'),
  readInputRegisters(4, 'Read Input Registers'),
  writeSingleCoil(5, 'Write Single Coil'),
  writeSingleRegister(6, 'Write Single Register'),
  writeMultipleCoils(15, 'Write Multiple Coils'),
  writeMultipleRegisters(16, 'Write Multiple Registers');

  const ModbusFunction(this.code, this.label);
  final int code;
  final String label;

  bool get readsBits => this == readCoils || this == readDiscreteInputs;
  bool get readsRegisters => this == readHoldingRegisters || this == readInputRegisters;

  static ModbusFunction? fromCode(int code) {
    for (final function in values) {
      if (function.code == code) return function;
    }
    return null;
  }
}

const modbusExceptionCodes = {
  1: 'illegal function',
  2: 'illegal data address',
  3: 'illegal data value',
  4: 'server device failure',
  5: 'acknowledge (busy, poll later)',
  6: 'server device busy',
  8: 'memory parity error',
  10: 'gateway path unavailable',
  11: 'gateway target did not respond',
};

/// Spec limits per request (so one frame fits 256 bytes on RTU).
const modbusMaxReadBits = 2000;
const modbusMaxReadRegisters = 125;
const modbusMaxWriteCoils = 1968;
const modbusMaxWriteRegisters = 123;

class ModbusRequest {
  const ModbusRequest({
    required this.unitId,
    required this.function,
    required this.address,
    this.quantity = 1,
    this.values = const [],
  });

  /// RTU: slave address 1..247 (0 = broadcast, no answer). TCP: usually 1
  /// or 255, used by gateways to reach a serial device behind them.
  final int unitId;
  final ModbusFunction function;

  /// 0-based address on the wire. "Holding register 40001" in a datasheet
  /// is address 0: the 4xxxx prefix only names the table.
  final int address;

  /// How many to read (functions 1–4).
  final int quantity;

  /// What to write: 0/1 per coil, or 16-bit register values.
  final List<int> values;

  /// Throws [ArgumentError] with the rule broken, before anything is sent.
  void check() {
    if (unitId < 0 || unitId > 255) throw ArgumentError('unit id 0..255');
    if (address < 0 || address > 0xffff) throw ArgumentError('address 0..65535');
    switch (function) {
      case ModbusFunction.readCoils || ModbusFunction.readDiscreteInputs:
        if (quantity < 1 || quantity > modbusMaxReadBits) throw ArgumentError('read 1..$modbusMaxReadBits bits');
      case ModbusFunction.readHoldingRegisters || ModbusFunction.readInputRegisters:
        if (quantity < 1 || quantity > modbusMaxReadRegisters) throw ArgumentError('read 1..$modbusMaxReadRegisters registers');
      case ModbusFunction.writeSingleCoil || ModbusFunction.writeSingleRegister:
        if (values.length != 1) throw ArgumentError('write one value');
      case ModbusFunction.writeMultipleCoils:
        if (values.isEmpty || values.length > modbusMaxWriteCoils) throw ArgumentError('write 1..$modbusMaxWriteCoils coils');
      case ModbusFunction.writeMultipleRegisters:
        if (values.isEmpty || values.length > modbusMaxWriteRegisters) throw ArgumentError('write 1..$modbusMaxWriteRegisters registers');
    }
    if (address + (function.readsBits || function.readsRegisters ? quantity : values.length) > 0x10000) {
      throw ArgumentError('range runs past address 65535');
    }
    for (final value in values) {
      if (value < 0 || value > 0xffff) throw ArgumentError('register value 0..65535');
    }
  }
}

class ModbusResponse {
  const ModbusResponse({
    required this.unitId,
    required this.functionCode,
    this.exceptionCode,
    this.bits = const [],
    this.registers = const [],
    this.address,
    this.value,
  });

  final int unitId;
  final int functionCode;

  /// Set when the device answered with function | 0x80.
  final int? exceptionCode;
  final List<bool> bits;
  final List<int> registers;

  /// Echo of a write (functions 5, 6, 15, 16).
  final int? address;
  final int? value;

  bool get isException => exceptionCode != null;
}

// ---- CRC -----------------------------------------------------------------

/// CRC-16/MODBUS: polynomial 0x8005 reflected (0xA001), start 0xFFFF. Sent
/// low byte first, unlike everything else in Modbus.
int modbusCrc16(List<int> bytes) {
  var crc = 0xffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xa001 : crc >> 1;
    }
  }
  return crc;
}

// ---- Encode --------------------------------------------------------------

Uint8List encodeModbusPdu(ModbusRequest request) {
  request.check();
  final out = BytesBuilder()..addByte(request.function.code);
  void addUint16(int value) => out
    ..addByte((value >> 8) & 0xff)
    ..addByte(value & 0xff);
  addUint16(request.address);
  switch (request.function) {
    case ModbusFunction.readCoils ||
        ModbusFunction.readDiscreteInputs ||
        ModbusFunction.readHoldingRegisters ||
        ModbusFunction.readInputRegisters:
      addUint16(request.quantity);
    case ModbusFunction.writeSingleCoil:
      addUint16(request.values.single != 0 ? 0xff00 : 0x0000);
    case ModbusFunction.writeSingleRegister:
      addUint16(request.values.single);
    case ModbusFunction.writeMultipleCoils:
      addUint16(request.values.length);
      final packed = packBits(request.values.map((value) => value != 0).toList());
      out
        ..addByte(packed.length)
        ..add(packed);
    case ModbusFunction.writeMultipleRegisters:
      addUint16(request.values.length);
      out.addByte(request.values.length * 2);
      request.values.forEach(addUint16);
  }
  return out.toBytes();
}

Uint8List encodeModbusRtu(ModbusRequest request) {
  final body = BytesBuilder()
    ..addByte(request.unitId)
    ..add(encodeModbusPdu(request));
  final bytes = body.toBytes();
  final crc = modbusCrc16(bytes);
  return (BytesBuilder()
        ..add(bytes)
        ..addByte(crc & 0xff)
        ..addByte(crc >> 8))
      .toBytes();
}

Uint8List encodeModbusTcp(ModbusRequest request, int transactionId) {
  final pdu = encodeModbusPdu(request);
  final header = ByteData(7)
    ..setUint16(0, transactionId & 0xffff)
    ..setUint16(2, 0)
    ..setUint16(4, pdu.length + 1)
    ..setUint8(6, request.unitId);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(pdu))
      .toBytes();
}

/// Coil i goes to bit (i % 8) of byte (i ~/ 8): first coil = lowest bit.
Uint8List packBits(List<bool> bits) {
  final bytes = Uint8List((bits.length + 7) ~/ 8);
  for (var index = 0; index < bits.length; index++) {
    if (bits[index]) bytes[index ~/ 8] |= 1 << (index % 8);
  }
  return bytes;
}

// ---- Framing -------------------------------------------------------------

/// How long an RTU response that starts with [buffer] will be, or null when
/// more bytes are needed to know. RTU has no length field: the length
/// follows from the function code (and the byte count for reads).
int? rtuResponseLength(Uint8List buffer) {
  if (buffer.length < 2) return null;
  final functionCode = buffer[1];
  if (functionCode & 0x80 != 0) return 5; // unit, fc|0x80, exception, crc×2
  final function = ModbusFunction.fromCode(functionCode);
  if (function == null) return 5; // unknown: let the CRC check reject it
  if (function.readsBits || function.readsRegisters) {
    if (buffer.length < 3) return null;
    return 3 + buffer[2] + 2;
  }
  return 8; // writes echo unit, fc, address, value/quantity, crc
}

/// Total length of the TCP frame starting with [buffer], or null.
int? tcpFrameLength(Uint8List buffer) {
  if (buffer.length < 6) return null;
  return 6 + ((buffer[4] << 8) | buffer[5]);
}

// ---- Decode --------------------------------------------------------------

class ModbusDecoded {
  const ModbusDecoded(this.frame, {this.response, this.transactionId});
  final Frame frame;
  final ModbusResponse? response;
  final int? transactionId;
}

ModbusDecoded decodeModbusRtu(Uint8List bytes, {required bool isRequest}) {
  if (bytes.length < 4) {
    const error = 'shorter than unit + function + CRC';
    return ModbusDecoded(Frame(protocol: 'Modbus RTU', summary: 'bad frame: $error', bytes: bytes, error: error));
  }
  // The body reader stops before the CRC, so the PDU decoder cannot eat it.
  final body = Uint8List.sublistView(bytes, 0, bytes.length - 2);
  final reader = FieldReader(body);
  final got = bytes[bytes.length - 2] | (bytes[bytes.length - 1] << 8);
  final expected = modbusCrc16(body);
  final crcField = Field(
    'CRC',
    bytes.length - 2,
    2,
    got == expected ? '${hex16(got)} ok' : '${hex16(got)} wrong, expected ${hex16(expected)}',
    note: 'CRC-16/MODBUS, low byte first',
  );
  try {
    final unitId = reader.uint8('unit id', note: '1..247; 0 = broadcast');
    final result = isRequest ? _decodeRequestPdu(reader) : _decodeResponsePdu(reader, unitId);
    if (!reader.isDone) throw const FormatException('extra bytes before the CRC');
    if (got != expected) throw FormatException('CRC ${hex16(got)} wrong, expected ${hex16(expected)}');
    return ModbusDecoded(
      Frame(protocol: 'Modbus RTU', summary: 'unit $unitId ${result.$1}', bytes: bytes, fields: [...reader.fields, crcField]),
      response: result.$2,
    );
  } on FormatException catch (error) {
    return ModbusDecoded(
      Frame(protocol: 'Modbus RTU', summary: 'bad frame: ${error.message}', bytes: bytes, fields: [...reader.fields, crcField], error: error.message),
    );
  }
}

ModbusDecoded decodeModbusTcp(Uint8List bytes, {required bool isRequest}) {
  final reader = FieldReader(bytes);
  try {
    final transactionId = reader.uint16('transaction id', note: 'pairs answer with request');
    reader.uint16('protocol id', note: 'always 0 for Modbus');
    final length = reader.uint16('length', note: 'unit id + PDU bytes');
    if (length != reader.remaining) throw FormatException('length says $length, frame has ${reader.remaining}');
    final unitId = reader.uint8('unit id');
    final result = isRequest ? _decodeRequestPdu(reader) : _decodeResponsePdu(reader, unitId);
    if (!reader.isDone) throw const FormatException('extra bytes after the PDU');
    return ModbusDecoded(
      Frame(protocol: 'Modbus TCP', summary: '#$transactionId unit $unitId ${result.$1}', bytes: bytes, fields: reader.fields),
      response: result.$2,
      transactionId: transactionId,
    );
  } on FormatException catch (error) {
    return ModbusDecoded(
      Frame(protocol: 'Modbus TCP', summary: 'bad frame: ${error.message}', bytes: bytes, fields: reader.fields, error: error.message),
    );
  }
}

String _functionName(int code) =>
    ModbusFunction.fromCode(code & 0x7f)?.label ?? 'function $code';

(String, ModbusResponse?) _decodeRequestPdu(FieldReader reader) {
  final code = reader.uint8('function', describe: (code) => '$code ${_functionName(code)}');
  final function = ModbusFunction.fromCode(code);
  if (function == null) return ('${_functionName(code)} ${reader.remaining} bytes', null);
  final address = reader.uint16('address', note: '0-based');
  switch (function) {
    case ModbusFunction.readCoils ||
        ModbusFunction.readDiscreteInputs ||
        ModbusFunction.readHoldingRegisters ||
        ModbusFunction.readInputRegisters:
      final quantity = reader.uint16('quantity');
      return ('${function.label} $address ×$quantity', null);
    case ModbusFunction.writeSingleCoil:
      final value = reader.uint16('value', describe: (value) => value == 0xff00 ? 'ON (0xff00)' : value == 0 ? 'OFF (0x0000)' : '${hex16(value)} invalid');
      return ('${function.label} $address = ${value == 0xff00 ? 'ON' : 'OFF'}', null);
    case ModbusFunction.writeSingleRegister:
      final value = reader.uint16('value');
      return ('${function.label} $address = $value', null);
    case ModbusFunction.writeMultipleCoils || ModbusFunction.writeMultipleRegisters:
      final quantity = reader.uint16('quantity');
      final byteCount = reader.uint8('byte count');
      if (function == ModbusFunction.writeMultipleRegisters) {
        for (var index = 0; index < byteCount ~/ 2; index++) {
          reader.uint16('register ${address + index}');
        }
      } else {
        reader.take(byteCount, 'coil bits', note: 'first coil = lowest bit');
      }
      return ('${function.label} $address ×$quantity', null);
  }
}

(String, ModbusResponse?) _decodeResponsePdu(FieldReader reader, int unitId) {
  final code = reader.uint8('function', describe: (code) => code & 0x80 != 0 ? '${hex8(code)} exception for ${_functionName(code)}' : '$code ${_functionName(code)}');
  if (code & 0x80 != 0) {
    final exception = reader.uint8('exception code', describe: (value) => '$value ${modbusExceptionCodes[value] ?? 'unknown'}');
    return (
      'exception ${modbusExceptionCodes[exception] ?? exception}',
      ModbusResponse(unitId: unitId, functionCode: code & 0x7f, exceptionCode: exception),
    );
  }
  final function = ModbusFunction.fromCode(code);
  if (function == null) throw FormatException('unknown function $code');
  if (function.readsBits) {
    final byteCount = reader.uint8('byte count');
    final packed = reader.take(byteCount, 'bits', note: 'first = lowest bit; padding bits are 0');
    final bits = [for (var index = 0; index < byteCount * 8; index++) packed[index ~/ 8] & (1 << (index % 8)) != 0];
    return ('${function.label}: ${bits.where((bit) => bit).length} of ${bits.length} bits on', ModbusResponse(unitId: unitId, functionCode: code, bits: bits));
  }
  if (function.readsRegisters) {
    final byteCount = reader.uint8('byte count');
    if (byteCount.isOdd) throw const FormatException('odd byte count for registers');
    final registers = [for (var index = 0; index < byteCount ~/ 2; index++) reader.uint16('register [$index]', describe: (value) => '$value (${hex16(value)})')];
    return ('${function.label}: ${registers.join(', ')}', ModbusResponse(unitId: unitId, functionCode: code, registers: registers));
  }
  final address = reader.uint16('address');
  final value = reader.uint16(function == ModbusFunction.writeSingleCoil || function == ModbusFunction.writeSingleRegister ? 'value' : 'quantity');
  return ('${function.label} $address ok', ModbusResponse(unitId: unitId, functionCode: code, address: address, value: value));
}
