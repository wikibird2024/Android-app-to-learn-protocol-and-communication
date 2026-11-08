import 'dart:convert';
import 'dart:typed_data';

import '../../core/inspect/frame.dart';
import '../field_reader.dart';

/// DNS messages (RFC 1035) as mDNS uses them (RFC 6762): a 12-byte header,
/// questions, then answer / authority / additional records. Names are
/// length-prefixed labels, and a name may end in a 2-byte pointer to an
/// earlier name (compression), which the Inside view shows.

const dnsTypes = {1: 'A', 12: 'PTR', 16: 'TXT', 28: 'AAAA', 33: 'SRV', 47: 'NSEC', 255: 'ANY'};

int dnsTypeCode(String name) => dnsTypes.entries.firstWhere((entry) => entry.value == name).key;

class DnsQuestion {
  const DnsQuestion(this.name, this.type, {this.wantsUnicast = false});
  final String name;
  final int type;

  /// mDNS "QU" bit (top bit of the class): please answer me directly.
  final bool wantsUnicast;
}

class DnsRecord {
  const DnsRecord({required this.name, required this.type, required this.ttlSeconds, required this.section, this.target, this.port, this.texts = const [], this.address});

  final String name;
  final int type;
  final int ttlSeconds;

  /// answer, authority or additional.
  final String section;

  /// PTR → instance name; SRV → host name.
  final String? target;
  final int? port;
  final List<String> texts;

  /// A / AAAA.
  final String? address;
}

class DnsMessage {
  const DnsMessage({required this.id, required this.isResponse, required this.questions, required this.records});
  final int id;
  final bool isResponse;
  final List<DnsQuestion> questions;
  final List<DnsRecord> records;
}

class DnsDecoded {
  const DnsDecoded(this.frame, [this.message]);
  final Frame frame;
  final DnsMessage? message;
}

/// An mDNS query (id 0, no flags), one question per name.
Uint8List encodeDnsQuery(List<DnsQuestion> questions, {int id = 0}) {
  final out = BytesBuilder();
  out.add((ByteData(12)
        ..setUint16(0, id)
        ..setUint16(4, questions.length))
      .buffer
      .asUint8List());
  for (final question in questions) {
    for (final label in question.name.split('.').where((label) => label.isNotEmpty)) {
      final bytes = utf8.encode(label);
      out
        ..addByte(bytes.length)
        ..add(bytes);
    }
    out.addByte(0);
    out.add((ByteData(4)
          ..setUint16(0, question.type)
          ..setUint16(2, (question.wantsUnicast ? 0x8000 : 0) | 1))
        .buffer
        .asUint8List());
  }
  return out.toBytes();
}

/// Reads a name at [offset]: labels, possibly ending in a compression
/// pointer. Returns the name, where it ends in the message, and one field
/// per label / pointer.
({String name, int end, List<Field> parts}) _readName(Uint8List bytes, int offset) {
  final labels = <String>[];
  final parts = <Field>[];
  var position = offset;
  int? end;
  var jumps = 0;
  while (true) {
    if (position >= bytes.length) throw const FormatException('name runs past the end');
    final length = bytes[position];
    if (length & 0xc0 == 0xc0) {
      if (position + 1 >= bytes.length) throw const FormatException('pointer cut off');
      final target = (length & 0x3f) << 8 | bytes[position + 1];
      if (++jumps > 20) throw const FormatException('pointer loop');
      final pointed = _readName(bytes, target).name;
      if (end == null) {
        parts.add(Field('pointer', position, 2, '→ offset $target "$pointed"', note: 'compression: the rest of the name is already at offset $target', children: [
          Field('pointer flag', position, 1, '11', bitShift: 6, bitWidth: 2),
          Field('offset (high bits)', position, 1, '${length & 0x3f}', bitShift: 0, bitWidth: 6),
        ]));
        end = position + 2;
      }
      labels.add(pointed);
      break;
    }
    if (length == 0) {
      if (end == null) {
        parts.add(Field('end', position, 1, '00', note: 'zero length = root, name ends'));
        end = position + 1;
      }
      break;
    }
    if (position + 1 + length > bytes.length) throw const FormatException('label runs past the end');
    final label = utf8.decode(bytes.sublist(position + 1, position + 1 + length), allowMalformed: true);
    if (end == null) parts.add(Field('label', position, 1 + length, '$length "$label"', note: 'length byte, then the text'));
    labels.add(label);
    position += 1 + length;
  }
  return (name: labels.where((label) => label.isNotEmpty).join('.'), end: end, parts: parts);
}

DnsDecoded decodeDns(Uint8List bytes) {
  final reader = FieldReader(bytes);
  try {
    final id = reader.uint16('id', note: 'mDNS uses 0: answers are matched by name, not id');
    final flagsHigh = reader.flags('flags (high)', [
      BitField('QR', 7, describe: (bit) => bit == 1 ? 'response' : 'query'),
      BitField('opcode', 3, width: 4, note: '0 = standard query'),
      BitField('AA', 2, note: 'authoritative: mDNS answers always set it', describe: (bit) => bit == 1 ? 'yes' : 'no'),
      BitField('TC', 1, note: 'truncated: more answers follow', describe: (bit) => bit == 1 ? 'yes' : 'no'),
      BitField('RD', 0, note: 'recursion desired (unused in mDNS)', describe: (bit) => bit == 1 ? 'yes' : 'no'),
    ]);
    reader.flags('flags (low)', [
      BitField('RA', 7, describe: (bit) => bit == 1 ? 'yes' : 'no'),
      BitField('Z', 4, width: 3),
      BitField('RCODE', 0, width: 4, note: '0 = no error'),
    ]);
    final questionCount = reader.uint16('questions');
    final answerCount = reader.uint16('answers');
    final authorityCount = reader.uint16('authority records');
    final additionalCount = reader.uint16('additional records', note: 'mDNS puts SRV, TXT and A here to save more queries');
    final questions = <DnsQuestion>[];
    for (var index = 0; index < questionCount; index++) {
      final start = reader.offset;
      final name = _readName(bytes, start);
      reader.offset = name.end;
      final type = reader.uint16('type');
      final klass = reader.uint16('class');
      reader.fields.length -= 2;
      questions.add(DnsQuestion(name.name, type, wantsUnicast: klass & 0x8000 != 0));
      reader.add('question', start, '${dnsTypes[type] ?? type} ${name.name}', children: [
        Field('name', start, name.end - start, name.name, children: name.parts),
        Field('type', name.end, 2, '$type ${dnsTypes[type] ?? ''}'.trim()),
        Field('class', name.end + 2, 2, '${klass & 0x7fff} (IN)${klass & 0x8000 != 0 ? ', QU' : ''}', children: [
          Field('QU', name.end + 2, 1, klass & 0x8000 != 0 ? 'yes' : 'no', note: 'unicast reply wanted', bitShift: 7, bitWidth: 1),
        ]),
      ]);
    }
    final records = <DnsRecord>[];
    final sections = [
      for (var index = 0; index < answerCount; index++) 'answer',
      for (var index = 0; index < authorityCount; index++) 'authority',
      for (var index = 0; index < additionalCount; index++) 'additional',
    ];
    for (final section in sections) {
      records.add(_readRecord(reader, bytes, section));
    }
    if (!reader.isDone) throw const FormatException('extra bytes after the records');
    final isResponse = flagsHigh & 0x80 != 0;
    final message = DnsMessage(id: id, isResponse: isResponse, questions: questions, records: records);
    final firstName = questions.isNotEmpty ? questions.first.name : records.isNotEmpty ? records.first.name : '';
    final summary = isResponse
        ? 'response: ${records.map((record) => '${dnsTypes[record.type] ?? record.type} ${record.target ?? record.address ?? record.name}').take(4).join(', ')}${records.length > 4 ? ' …' : ''}'
        : 'query ${questions.map((question) => '${dnsTypes[question.type] ?? question.type} ${question.name}').join(', ')}';
    return DnsDecoded(
      Frame(protocol: 'mDNS', summary: summary, bytes: bytes, fields: reader.fields, exchange: 'mDNS $firstName', redecode: _redecode),
      message,
    );
  } on FormatException catch (error) {
    return DnsDecoded(Frame(protocol: 'mDNS', summary: 'bad DNS message: ${error.message}', bytes: bytes, fields: reader.fields, error: error.message, redecode: _redecode));
  }
}

Frame _redecode(Uint8List bytes) => decodeDns(bytes).frame;

DnsRecord _readRecord(FieldReader reader, Uint8List bytes, String section) {
  final start = reader.offset;
  final name = _readName(bytes, start);
  reader.offset = name.end;
  final type = reader.uint16('type');
  final klass = reader.uint16('class');
  final ttl = reader.uint32('ttl');
  final length = reader.uint16('data length');
  reader.fields.length -= 4;
  final dataStart = reader.offset;
  final data = reader.take(length, 'data');
  reader.fields.removeLast();
  String? target;
  int? port;
  String? address;
  var texts = <String>[];
  final dataParts = <Field>[];
  switch (type) {
    case 1 when length == 4:
      address = data.join('.');
    case 28 when length == 16:
      address = [for (var index = 0; index < 16; index += 2) (data[index] << 8 | data[index + 1]).toRadixString(16)].join(':');
    case 12:
      final pointed = _readName(bytes, dataStart);
      target = pointed.name;
      dataParts.addAll(pointed.parts);
    case 33 when length >= 7:
      final view = ByteData.sublistView(data);
      port = view.getUint16(4);
      final host = _readName(bytes, dataStart + 6);
      target = host.name;
      dataParts.addAll([
        Field('priority', dataStart, 2, '${view.getUint16(0)}', note: 'lower is tried first'),
        Field('weight', dataStart + 2, 2, '${view.getUint16(2)}'),
        Field('port', dataStart + 4, 2, '$port'),
        Field('target', dataStart + 6, host.end - dataStart - 6, host.name, children: host.parts),
      ]);
    case 16:
      var position = 0;
      while (position < data.length) {
        final textLength = data[position];
        if (position + 1 + textLength > data.length) break;
        final text = utf8.decode(data.sublist(position + 1, position + 1 + textLength), allowMalformed: true);
        if (text.isNotEmpty) texts.add(text);
        dataParts.add(Field('string', dataStart + position, 1 + textLength, '"$text"', note: 'key=value, length byte first'));
        position += 1 + textLength;
      }
    default:
      break;
  }
  final typeName = dnsTypes[type] ?? 'type $type';
  final shown = address ?? (port != null ? '$target:$port' : target) ?? (texts.isNotEmpty ? texts.join(' ') : textOrHex(data));
  reader.add('$section $typeName', start, '${name.name} → $shown', children: [
    Field('name', start, name.end - start, name.name, children: name.parts),
    Field('type', name.end, 2, '$type $typeName'),
    Field('class', name.end + 2, 2, '${klass & 0x7fff} (IN)${klass & 0x8000 != 0 ? ', cache flush' : ''}', children: [
      Field('cache flush', name.end + 2, 1, klass & 0x8000 != 0 ? 'yes' : 'no', note: 'this answer replaces older cached ones', bitShift: 7, bitWidth: 1),
    ]),
    Field('TTL', name.end + 4, 4, '$ttl s', note: ttl == 0 ? 'goodbye: the service is leaving' : 'how long others may cache it'),
    Field('data length', name.end + 8, 2, '$length'),
    Field('data', dataStart, length, shown, children: dataParts),
  ]);
  texts = List.unmodifiable(texts);
  return DnsRecord(name: name.name, type: type, ttlSeconds: ttl, section: section, target: target, port: port, texts: texts, address: address);
}
