import 'dart:convert';
import 'dart:typed_data';

import '../../core/bytes/hex.dart';
import '../../core/inspect/frame.dart';
import '../field_reader.dart';

/// BLE advertising data (Core Spec Vol 3 Part C §11, Supplement to the
/// Core Spec Part A): up to 31 bytes (legacy) of AD structures, each
///
///   [length = 1 + data bytes][AD type][data]
///
/// Android hands apps the parsed parts, not the raw bytes, so the scanner
/// rebuilds the bytes with [encodeAdvert] and explains them with
/// [decodeAdvert]; the same decoder reads raw adverts from other sources.
const adTypes = {
  0x01: 'Flags',
  0x02: 'Incomplete 16-bit service UUIDs',
  0x03: 'Complete 16-bit service UUIDs',
  0x06: 'Incomplete 128-bit service UUIDs',
  0x07: 'Complete 128-bit service UUIDs',
  0x08: 'Shortened local name',
  0x09: 'Complete local name',
  0x0a: 'TX power level',
  0x16: 'Service data (16-bit UUID)',
  0x19: 'Appearance',
  0xff: 'Manufacturer specific data',
};

/// A few company ids (Bluetooth SIG assigned numbers) seen on a bench.
const bleCompanies = {
  0x0006: 'Microsoft',
  0x004c: 'Apple',
  0x0059: 'Nordic Semiconductor',
  0x0075: 'Samsung',
  0x00e0: 'Google',
  0x02e5: 'Espressif',
};

class AdvertParts {
  const AdvertParts({
    this.name,
    this.serviceUuids = const [],
    this.manufacturerData = const {},
    this.serviceData = const {},
  });

  final String? name;

  /// Lowercase, `0000180f-0000-1000-8000-00805f9b34fb` or short `180f`.
  final List<String> serviceUuids;

  /// Company id → payload (without the 2 id bytes).
  final Map<int, Uint8List> manufacturerData;

  /// 16-bit service UUID (short form) → payload.
  final Map<String, Uint8List> serviceData;
}

const _baseUuidTail = '-0000-1000-8000-00805f9b34fb';

/// `0000180f-0000-1000-8000-00805f9b34fb` → `180f`; other UUIDs unchanged.
String shortUuid(String uuid) {
  final lower = uuid.toLowerCase();
  if (lower.length == 36 && lower.startsWith('0000') && lower.endsWith(_baseUuidTail)) {
    return lower.substring(4, 8);
  }
  return lower;
}

Uint8List encodeAdvert(AdvertParts parts) {
  final out = BytesBuilder();
  void addStructure(int type, List<int> data) => out
    ..addByte(data.length + 1)
    ..addByte(type)
    ..add(data);

  if (parts.name != null && parts.name!.isNotEmpty) {
    addStructure(0x09, utf8.encode(parts.name!));
  }
  final shortIds = <int>[];
  final longIds = <int>[];
  for (final uuid in parts.serviceUuids) {
    final short = shortUuid(uuid);
    if (short.length == 4) {
      final value = int.parse(short, radix: 16);
      shortIds.addAll([value & 0xff, value >> 8]);
    } else {
      // 128-bit UUIDs go on air little-endian (reversed).
      longIds.addAll(parseHex(short.replaceAll('-', '')).reversed);
    }
  }
  if (shortIds.isNotEmpty) addStructure(0x03, shortIds);
  if (longIds.isNotEmpty) addStructure(0x07, longIds);
  parts.serviceData.forEach((uuid, payload) {
    final value = int.tryParse(shortUuid(uuid), radix: 16) ?? 0;
    addStructure(0x16, [value & 0xff, (value >> 8) & 0xff, ...payload]);
  });
  parts.manufacturerData.forEach((companyId, payload) {
    addStructure(0xff, [companyId & 0xff, companyId >> 8, ...payload]);
  });
  return out.toBytes();
}

Frame decodeAdvert(Uint8List bytes) {
  final reader = FieldReader(bytes, endian: Endian.little);
  final names = <String>[];
  try {
    while (!reader.isDone) {
      final start = reader.offset;
      final length = reader.peekUint8();
      if (length == 0) {
        reader.rest('padding', note: 'length 0 ends the data');
        break;
      }
      final structure = reader.take(1 + length, 'AD structure');
      reader.fields.removeLast();
      final type = structure[1];
      final data = Uint8List.sublistView(structure, 2);
      final typeName = adTypes[type] ?? 'AD type ${hex8(type)}';
      names.add(typeName);
      reader.fields.add(Field(
        typeName,
        start,
        1 + length,
        _describeAdData(type, data),
        children: [
          Field('length', start, 1, '$length', note: 'type byte + data'),
          Field('AD type', start + 1, 1, hex8(type)),
          Field('data', start + 2, data.length, data.isEmpty ? '(empty)' : toHex(data), children: [
            if (type == 0x01 && data.isNotEmpty)
              for (final (bit, name) in _flagBits)
                Field(name, start + 2, 1, data[0] & (1 << bit) != 0 ? 'yes' : 'no', bitShift: bit, bitWidth: 1),
          ]),
        ],
      ));
    }
    return Frame(
      protocol: 'BLE advert',
      summary: '${bytes.length} bytes: ${names.join(', ')}${bytes.length > 31 ? ' (extended: over 31 bytes)' : ''}',
      bytes: bytes,
      fields: reader.fields,
      redecode: decodeAdvert,
    );
  } on FormatException catch (error) {
    return Frame(protocol: 'BLE advert', summary: 'bad advert', bytes: bytes, fields: reader.fields, error: error.message, redecode: decodeAdvert);
  }
}

/// Bits of the Flags AD structure (Core Spec Supplement, part A 1.3).
const _flagBits = [
  (0, 'LE limited discoverable'),
  (1, 'LE general discoverable'),
  (2, 'BR/EDR not supported'),
  (3, 'LE + BR/EDR controller'),
  (4, 'LE + BR/EDR host'),
];

String _describeAdData(int type, Uint8List data) {
  switch (type) {
    case 0x01 when data.isNotEmpty:
      final flags = data[0];
      return [
        if (flags & 0x01 != 0) 'LE limited discoverable',
        if (flags & 0x02 != 0) 'LE general discoverable',
        if (flags & 0x04 != 0) 'BR/EDR not supported',
      ].join(', ');
    case 0x02 || 0x03:
      return [
        for (var index = 0; index + 1 < data.length; index += 2)
          (data[index] | data[index + 1] << 8).toRadixString(16).padLeft(4, '0'),
      ].join(', ');
    case 0x06 || 0x07:
      return [
        for (var index = 0; index + 15 < data.length; index += 16) _uuid128(data.sublist(index, index + 16)),
      ].join(', ');
    case 0x08 || 0x09:
      return '"${utf8.decode(data, allowMalformed: true)}"';
    case 0x0a when data.isNotEmpty:
      return '${data[0].toSigned(8)} dBm';
    case 0x16 when data.length >= 2:
      return 'UUID ${(data[0] | data[1] << 8).toRadixString(16).padLeft(4, '0')}: ${toHex(data.sublist(2))}';
    case 0xff when data.length >= 2:
      final company = data[0] | data[1] << 8;
      return '${bleCompanies[company] ?? hex16(company)}: ${toHex(data.sublist(2))}';
    default:
      return toHex(data);
  }
}

String _uuid128(List<int> littleEndian) {
  final hex = toHex(littleEndian.reversed.toList(), separator: '');
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Signal strength in words, for people new to RSSI.
String rssiText(int? rssi) {
  if (rssi == null) return '';
  final quality = rssi >= -60 ? 'strong' : rssi >= -75 ? 'good' : rssi >= -90 ? 'weak' : 'at the edge';
  return '$rssi dBm ($quality)';
}
