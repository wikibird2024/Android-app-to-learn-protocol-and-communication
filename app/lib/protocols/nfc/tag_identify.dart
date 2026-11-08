import 'dart:typed_data';

import '../../core/bytes/hex.dart';
import '../../core/inspect/frame.dart';
import '../field_reader.dart';

/// Which tag is this? From what every NFC-A tag tells the phone on its own
/// (ATQA, SAK) and, for NTAG / Ultralight EV1, the GET_VERSION reply.
///
///   SAK 0x00 → Type 2 (NTAG, Ultralight)  → ask GET_VERSION for the model
///   SAK 0x08 → MIFARE Classic 1K          → needs sector keys
///   SAK 0x20 → ISO 14443-4 (ISO-DEP)      → APDUs (DESFire, bank cards)

/// NTAG / Ultralight EV1 command: GET_VERSION.
final ntagGetVersion = Uint8List.fromList([0x60]);

/// SAK (select acknowledge) byte → tag family, NXP AN10833.
const sakFamilies = {
  0x00: 'MIFARE Ultralight / NTAG (Type 2)',
  0x08: 'MIFARE Classic 1K',
  0x09: 'MIFARE Mini',
  0x10: 'MIFARE Plus 2K',
  0x11: 'MIFARE Plus 4K',
  0x18: 'MIFARE Classic 4K',
  0x20: 'ISO 14443-4 (DESFire, smart card, phone)',
  0x28: 'MIFARE Classic 1K + ISO 14443-4',
  0x38: 'MIFARE Classic 4K + ISO 14443-4',
};

String describeSak(int sak) => sakFamilies[sak] ?? 'unknown family';

class TagModel {
  const TagModel(this.name, this.totalPages, this.userBytes);

  final String name;

  /// 4-byte pages, including UID, lock, CC and config pages.
  final int totalPages;
  final int userBytes;
}

/// (product type, storage size byte) of the GET_VERSION reply → model.
/// NXP datasheets NTAG213/215/216, NTAG210/212, MF0ULx1.
const _models = {
  (0x04, 0x0B): TagModel('NTAG210', 20, 48),
  (0x04, 0x0E): TagModel('NTAG212', 41, 128),
  (0x04, 0x0F): TagModel('NTAG213', 45, 144),
  (0x04, 0x11): TagModel('NTAG215', 135, 504),
  (0x04, 0x13): TagModel('NTAG216', 231, 888),
  (0x03, 0x0B): TagModel('MIFARE Ultralight EV1 (MF0UL11)', 20, 48),
  (0x03, 0x0E): TagModel('MIFARE Ultralight EV1 (MF0UL21)', 41, 128),
};

/// The model from an 8-byte GET_VERSION reply, or null when unknown.
TagModel? tagModelFromVersion(Uint8List reply) =>
    reply.length == 8 && reply[1] == 0x04 ? _models[(reply[2], reply[6])] : null;

/// What the phone learned at anti-collision: UID, ATQA and SAK.
/// Bytes laid out as [UID][ATQA 2][SAK 1]; ATQA and SAK are absent on tags
/// that are not NFC-A.
Frame describeTagInfo(Uint8List uid, String technologies, {Uint8List? atqa, int? sak}) {
  final bytes = Uint8List.fromList([...uid, ...?atqa, ?sak]);
  final reader = FieldReader(bytes);
  reader.take(uid.length, 'UID', describe: (value) => toHex(value, separator: ':'), note: '4, 7 or 10 bytes; not secret, easy to copy');
  if (atqa != null) reader.take(atqa.length, 'ATQA', note: 'answer to request: UID size and anti-collision');
  if (sak != null) reader.uint8('SAK', describe: (value) => '${hex8(value)} ${describeSak(value)}', note: 'select acknowledge: which tag family');
  reader.add('technologies', 0, technologies);
  final family = sak == null ? technologies : describeSak(sak);
  return Frame(protocol: 'NFC tag', summary: 'tag ${toHex(uid, separator: ':')} · $family', bytes: bytes, fields: reader.fields);
}

/// The 8-byte GET_VERSION reply, field by field.
Frame describeNtagVersion(Uint8List bytes) {
  final reader = FieldReader(bytes);
  try {
    reader.uint8('fixed header', describe: hex8);
    reader.uint8('vendor', describe: (value) => value == 0x04 ? '0x04 NXP' : hex8(value));
    reader.uint8('product type', describe: (value) => switch (value) {
      0x03 => '0x03 MIFARE Ultralight',
      0x04 => '0x04 NTAG',
      _ => hex8(value),
    });
    reader.uint8('product subtype', describe: hex8, note: 'input capacitance (17 or 50 pF)');
    reader.uint8('major version', describe: hex8);
    reader.uint8('minor version', describe: hex8);
    reader.uint8('storage size', describe: (value) {
      // Bits 7..1 = n: user memory is 2^n bytes, or between 2^n and 2^(n+1) when bit 0 is set.
      final power = 1 << (value >> 1);
      return value & 1 == 0 ? '${hex8(value)} $power bytes' : '${hex8(value)} $power..${power * 2} bytes';
    });
    reader.uint8('protocol type', describe: (value) => value == 0x03 ? '0x03 ISO 14443-3' : hex8(value));
    if (!reader.isDone) reader.rest('extra');
    final model = tagModelFromVersion(bytes);
    final summary = model == null
        ? 'GET_VERSION: unknown model'
        : '${model.name}: ${model.userBytes} user bytes, ${model.totalPages} pages';
    return Frame(protocol: 'NTAG', summary: summary, bytes: bytes, fields: reader.fields);
  } on FormatException catch (error) {
    return Frame(protocol: 'NTAG', summary: 'bad GET_VERSION reply', bytes: bytes, fields: reader.fields, error: error.message);
  }
}
