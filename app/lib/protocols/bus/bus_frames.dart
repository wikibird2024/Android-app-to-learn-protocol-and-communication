import 'dart:typed_data';

import '../../core/bytes/hex.dart';
import '../../core/inspect/frame.dart';
import '../field_reader.dart';
import 'wire_signals.dart';

// Decoders for what the bridge reports from wired buses. The bridge sends
// results as JSON; these turn them into the frames a logic analyzer would
// show on the wire, which is the part worth learning.

// ---- I2C -----------------------------------------------------------------

/// One I2C transaction as it looks on SDA: START, address+W, the written
/// bytes, then (for a read) repeated START, address+R, the read bytes, STOP.
/// Each byte is followed by ACK (0, receiver pulls SDA low) or NACK (1).
Frame describeI2cTransaction({
  required int address,
  required Uint8List written,
  required Uint8List read,
  int clockHz = 100000,
}) {
  final bytes = BytesBuilder();
  final fields = <Field>[];
  void addByte(String name, int value, String meaning, String ack) {
    fields.add(Field(name, bytes.length, 1, '${hex8(value)} $meaning', note: ack));
    bytes.addByte(value);
  }

  if (written.isNotEmpty || read.isEmpty) {
    addByte('address + W', address << 1, '(${hex8(address)} write)', 'START before it · ACK from the device');
    for (final (index, value) in written.indexed) {
      addByte(index == 0 ? 'register / command' : 'write [$index]', value, '', 'ACK from the device');
    }
  }
  if (read.isNotEmpty) {
    addByte('address + R', (address << 1) | 1, '(${hex8(address)} read)', written.isEmpty ? 'START · ACK' : 'repeated START · ACK');
    for (final (index, value) in read.indexed) {
      addByte('read [$index]', value, '', index == read.length - 1 ? 'NACK from us: "last byte", then STOP' : 'ACK from us: "send more"');
    }
  }
  final summary = read.isEmpty
      ? 'I2C ${hex8(address)} write ${toHex(written)}'
      : 'I2C ${hex8(address)}${written.isEmpty ? '' : ' write ${toHex(written)},'} read ${toHex(read)}';
  return Frame(
    protocol: 'I2C',
    summary: summary,
    bytes: bytes.toBytes(),
    fields: fields,
    wire: i2cTrace(address: address, written: written, read: read, clockHz: clockHz),
  );
}

// ---- SPI -----------------------------------------------------------------

/// One SPI transfer: byte i went out on MOSI while byte i came in on MISO.
/// The bytes are the written ones followed by the read ones.
Frame describeSpiTransfer({required Uint8List written, required Uint8List read, int mode = 0, int clockHz = 1000000}) => Frame(
  protocol: 'SPI',
  summary: 'MOSI ${toHex(written)} · MISO ${toHex(read)}',
  bytes: Uint8List.fromList([...written, ...read]),
  fields: [
    for (var index = 0; index < written.length; index++)
      Field('byte $index', index, 1, 'out ${hex8(written[index])} · in ${index < read.length ? hex8(read[index]) : '--'}',
          note: index == 0 ? 'one clock pulse moves one bit each way' : ''),
  ],
  wire: spiTrace(mosi: written, miso: read, mode: mode, clockHz: clockHz),
);

/// Well-known 7-bit addresses, to guess what a scan found.
const i2cKnownDevices = {
  0x20: 'PCF8574 / MCP23017 IO expander',
  0x27: 'PCF8574 LCD backpack',
  0x3c: 'SSD1306 OLED',
  0x3d: 'SSD1306 OLED (alt)',
  0x40: 'INA219 / HTU21D / PCA9685',
  0x44: 'SHT3x',
  0x48: 'ADS1115 / TMP102',
  0x50: 'AT24C EEPROM',
  0x57: 'AT24C32 on DS3231 board',
  0x5a: 'MLX90614',
  0x68: 'MPU6050 / DS3231 RTC',
  0x69: 'MPU6050 (AD0 high)',
  0x76: 'BME280 / BMP280',
  0x77: 'BME280 / BMP180 (alt)',
};

// ---- CAN -----------------------------------------------------------------

class CanFrame {
  const CanFrame({
    required this.id,
    required this.data,
    this.isExtended = false,
    this.isRemote = false,
  });

  /// From a bridge event `{"id":"123","ext":false,"rtr":false,"data":"0102"}`.
  static CanFrame? fromEvent(Map<String, Object?> event) {
    final idText = event['id'];
    final dataText = event['data'];
    if (idText is! String || dataText is! String) return null;
    final id = int.tryParse(idText, radix: 16);
    if (id == null) return null;
    try {
      return CanFrame(
        id: id,
        data: parseHex(dataText),
        isExtended: event['ext'] == true,
        isRemote: event['rtr'] == true,
      );
    } on FormatException {
      return null;
    }
  }

  /// 11-bit standard (0..0x7FF) or 29-bit extended (0..0x1FFFFFFF).
  final int id;
  final Uint8List data;
  final bool isExtended;

  /// Remote request: "please send frame [id]", no data bytes.
  final bool isRemote;

  /// The 16-byte Linux SocketCAN frame that pcap link type 227 stores:
  /// can_id (big-endian in pcap, flags in the top 3 bits), DLC, 3 pad
  /// bytes, 8 data bytes.
  Uint8List toSocketCan() {
    var canId = id;
    if (isExtended) canId |= 0x80000000;
    if (isRemote) canId |= 0x40000000;
    final out = ByteData(16)
      ..setUint32(0, canId)
      ..setUint8(4, data.length);
    for (final (index, value) in data.take(8).indexed) {
      out.setUint8(8 + index, value);
    }
    return out.buffer.asUint8List();
  }

  String get idText => isExtended
      ? id.toRadixString(16).padLeft(8, '0')
      : id.toRadixString(16).padLeft(3, '0');
}

/// Inside view of a CAN frame: the SocketCAN bytes software sees (what
/// pcap stores) plus the wire view of what the controller really sends:
/// SOF, CRC-15, bit stuffing, the ACK slot.
Frame describeCanFrame(CanFrame frame, {int bitrate = 500000}) {
  final onWire = canTrace(id: frame.id, data: frame.data, isExtended: frame.isExtended, isRemote: frame.isRemote, bitrate: bitrate);
  final bytes = frame.toSocketCan();
  String yesNo(bool value) => value ? 'yes' : 'no';
  final fields = [
    Field(
      'can_id',
      0,
      4,
      '${frame.idText} (${frame.isExtended ? '29-bit extended' : '11-bit standard'})',
      note: 'lower id wins arbitration: the id is also the priority',
      children: [
        Field('EFF (bit 31)', 0, 1, yesNo(frame.isExtended), note: 'extended 29-bit id', bitShift: 7, bitWidth: 1),
        Field('RTR (bit 30)', 0, 1, yesNo(frame.isRemote), note: 'remote request: asks for data', bitShift: 6, bitWidth: 1),
        Field('ERR (bit 29)', 0, 1, 'no', note: 'error frame (Linux only)', bitShift: 5, bitWidth: 1),
        Field('identifier', 0, 4, '0x${frame.idText}'),
      ],
    ),
    Field('DLC', 4, 1, '${frame.data.length}', note: 'data length 0..8 (CAN FD: up to 64)'),
    const Field('padding', 5, 3, '00 00 00', note: 'SocketCAN struct padding, not on the wire'),
    Field('data', 8, frame.data.length, frame.data.isEmpty ? '(none)' : toHex(frame.data)),
    Field('CRC-15 (on the wire)', 0, 0, '0x${onWire.crc.toRadixString(16).padLeft(4, '0')}',
        note: 'added by the controller, not in these bytes; see the wire view'),
    Field('stuff bits (on the wire)', 0, 0, '${onWire.stuffBits}', note: 'after 5 equal bits the controller adds one opposite bit'),
  ];
  return Frame(
    protocol: 'CAN',
    summary: '${frame.idText}${frame.isRemote ? ' RTR' : ''} [${frame.data.length}] ${toHex(frame.data)}',
    bytes: Uint8List.sublistView(bytes, 0, 8 + frame.data.length),
    fields: fields,
    wire: onWire.trace,
  );
}

// ---- 1-Wire --------------------------------------------------------------

/// Dallas/Maxim CRC-8 (polynomial x^8 + x^5 + x^4 + 1, reflected 0x8C),
/// used by every 1-Wire ROM code and the DS18B20 scratchpad.
int oneWireCrc8(List<int> bytes) {
  var crc = 0;
  for (final byte in bytes) {
    var value = byte;
    for (var bit = 0; bit < 8; bit++) {
      final mix = (crc ^ value) & 1;
      crc >>= 1;
      if (mix != 0) crc ^= 0x8c;
      value >>= 1;
    }
  }
  return crc;
}

const oneWireFamilies = {
  0x10: 'DS18S20 temperature',
  0x22: 'DS1822 temperature',
  0x28: 'DS18B20 temperature',
  0x26: 'DS2438 battery monitor',
  0x2d: 'DS2431 EEPROM',
  0x01: 'DS2401 serial number',
};

/// A 64-bit ROM code: family (1), serial (6), CRC (1), sent lowest byte
/// first during the search.
Frame describeOneWireRom(Uint8List rom) {
  final reader = FieldReader(rom);
  try {
    reader.uint8('family code', describe: (code) => '${hex8(code)} ${oneWireFamilies[code] ?? 'unknown'}');
    reader.take(6, 'serial number', note: 'unique, lasered at the factory');
    final expected = oneWireCrc8(rom.sublist(0, 7));
    reader.uint8('CRC-8', describe: (crc) => crc == expected ? '${hex8(crc)} ok' : '${hex8(crc)} wrong, expected ${hex8(expected)}');
    if (!reader.isDone) throw const FormatException('ROM code is 8 bytes');
    return Frame(protocol: '1-Wire', summary: 'ROM ${toHex(rom, separator: '')}', bytes: rom, fields: reader.fields,
        error: rom[7] == expected ? null : 'bad CRC',
        // The search finds ROMs bit by bit; the wire view shows the simpler
        // Read ROM (0x33) a single device would answer.
        wire: oneWireTrace(written: const [0x33], read: rom, writtenLabels: const ['Read ROM 0x33']),
        redecode: describeOneWireRom);
  } on FormatException catch (error) {
    return Frame(protocol: '1-Wire', summary: 'bad ROM', bytes: rom, fields: reader.fields, error: error.message);
  }
}

/// DS18B20 scratchpad (9 bytes) → temperature in °C, or null if the CRC
/// fails. Temperature is a signed 16-bit count of 1/16 °C.
({double? celsius, Frame frame}) describeDs18b20Scratchpad(Uint8List scratchpad) {
  final reader = FieldReader(scratchpad, endian: Endian.little);
  try {
    final raw = reader.uint16('temperature', describe: (value) => '${value.toSigned(16) / 16} °C (${hex16(value)} / 16)',
        note: 'signed, little-endian, 1/16 °C steps');
    reader.uint8('TH alarm');
    reader.uint8('TL alarm');
    reader.uint8('configuration', describe: (value) => '${9 + ((value >> 5) & 3)}-bit resolution',
        note: '12-bit: 750 ms per conversion');
    reader.take(3, 'reserved');
    final expected = oneWireCrc8(scratchpad.sublist(0, 8));
    final crc = reader.uint8('CRC-8', describe: (crc) => crc == expected ? '${hex8(crc)} ok' : '${hex8(crc)} wrong');
    final celsius = crc == expected ? raw.toSigned(16) / 16 : null;
    return (
      celsius: celsius,
      frame: Frame(
        protocol: 'DS18B20',
        summary: celsius == null ? 'scratchpad CRC wrong' : '$celsius °C',
        bytes: scratchpad,
        fields: reader.fields,
        error: celsius == null ? 'bad CRC' : null,
      ),
    );
  } on FormatException catch (error) {
    return (celsius: null, frame: Frame(protocol: 'DS18B20', summary: 'bad scratchpad', bytes: scratchpad, fields: reader.fields, error: error.message));
  }
}
