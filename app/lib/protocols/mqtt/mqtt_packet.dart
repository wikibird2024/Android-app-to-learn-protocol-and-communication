import 'dart:convert';
import 'dart:typed_data';

import '../../core/inspect/frame.dart';
import '../field_reader.dart';

/// MQTT 3.1.1 (OASIS standard, 2014) control packets, encoded and decoded by
/// hand. Every packet is:
///
///   byte 0      : type (high 4 bits) | flags (low 4 bits)
///   bytes 1..4  : remaining length, 7 bits per byte, high bit = "more"
///   then        : variable header + payload (remaining length bytes)
enum MqttPacketType {
  connect(1),
  connack(2),
  publish(3),
  puback(4),
  pubrec(5),
  pubrel(6),
  pubcomp(7),
  subscribe(8),
  suback(9),
  unsubscribe(10),
  unsuback(11),
  pingreq(12),
  pingresp(13),
  disconnect(14);

  const MqttPacketType(this.code);
  final int code;

  String get label => name.toUpperCase();

  static MqttPacketType? fromCode(int code) {
    for (final type in values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

const mqttMaxRemainingLength = 268435455;

/// CONNACK return codes (spec 3.2.2.3).
const mqttConnectReturnCodes = {
  0: 'accepted',
  1: 'refused: protocol version',
  2: 'refused: client id rejected',
  3: 'refused: server unavailable',
  4: 'refused: bad user name or password',
  5: 'refused: not authorized',
};

sealed class MqttPacket {
  const MqttPacket();
  MqttPacketType get type;
}

class MqttWill {
  const MqttWill({
    required this.topic,
    required this.message,
    this.qos = 0,
    this.retain = false,
  });

  final String topic;
  final Uint8List message;
  final int qos;
  final bool retain;
}

class MqttConnect extends MqttPacket {
  const MqttConnect({
    required this.clientId,
    this.keepAliveSeconds = 60,
    this.cleanSession = true,
    this.username,
    this.password,
    this.will,
  });

  final String clientId;
  final int keepAliveSeconds;
  final bool cleanSession;
  final String? username;
  final String? password;
  final MqttWill? will;

  @override
  MqttPacketType get type => MqttPacketType.connect;
}

class MqttConnAck extends MqttPacket {
  const MqttConnAck({required this.sessionPresent, required this.returnCode});

  final bool sessionPresent;
  final int returnCode;

  @override
  MqttPacketType get type => MqttPacketType.connack;
}

class MqttPublish extends MqttPacket {
  const MqttPublish({
    required this.topic,
    required this.payload,
    this.qos = 0,
    this.retain = false,
    this.duplicate = false,
    this.packetId,
  });

  final String topic;
  final Uint8List payload;
  final int qos;
  final bool retain;
  final bool duplicate;

  /// Only for QoS 1 and 2.
  final int? packetId;

  @override
  MqttPacketType get type => MqttPacketType.publish;
}

/// PUBACK, PUBREC, PUBREL, PUBCOMP, UNSUBACK: just a packet id.
class MqttPacketIdOnly extends MqttPacket {
  const MqttPacketIdOnly(this.type, this.packetId);

  @override
  final MqttPacketType type;
  final int packetId;
}

class MqttSubscription {
  const MqttSubscription(this.topicFilter, this.qos);
  final String topicFilter;
  final int qos;
}

class MqttSubscribe extends MqttPacket {
  const MqttSubscribe({required this.packetId, required this.subscriptions});

  final int packetId;
  final List<MqttSubscription> subscriptions;

  @override
  MqttPacketType get type => MqttPacketType.subscribe;
}

class MqttSubAck extends MqttPacket {
  const MqttSubAck({required this.packetId, required this.returnCodes});

  final int packetId;

  /// Granted QoS 0..2 per filter, or 0x80 for "refused".
  final List<int> returnCodes;

  @override
  MqttPacketType get type => MqttPacketType.suback;
}

class MqttUnsubscribe extends MqttPacket {
  const MqttUnsubscribe({required this.packetId, required this.topicFilters});

  final int packetId;
  final List<String> topicFilters;

  @override
  MqttPacketType get type => MqttPacketType.unsubscribe;
}

/// PINGREQ, PINGRESP, DISCONNECT: the 2-byte packets.
class MqttEmpty extends MqttPacket {
  const MqttEmpty(this.type);

  @override
  final MqttPacketType type;
}

// ---- Encode ---------------------------------------------------------------

Uint8List encodeRemainingLength(int length) {
  if (length < 0 || length > mqttMaxRemainingLength) {
    throw ArgumentError.value(length, 'length', 'MQTT remaining length');
  }
  final bytes = <int>[];
  var left = length;
  do {
    var digit = left % 128;
    left ~/= 128;
    if (left > 0) digit |= 0x80;
    bytes.add(digit);
  } while (left > 0);
  return Uint8List.fromList(bytes);
}

void _addString(BytesBuilder out, String text) => _addBinary(out, utf8.encode(text));

void _addBinary(BytesBuilder out, List<int> bytes) {
  if (bytes.length > 0xffff) throw ArgumentError('MQTT string over 65535 bytes');
  out
    ..addByte(bytes.length >> 8)
    ..addByte(bytes.length & 0xff)
    ..add(bytes);
}

void _addUint16(BytesBuilder out, int value) => out
  ..addByte((value >> 8) & 0xff)
  ..addByte(value & 0xff);

Uint8List encodeMqtt(MqttPacket packet) {
  var flags = 0;
  final body = BytesBuilder();
  switch (packet) {
    case MqttConnect():
      _addString(body, 'MQTT');
      body.addByte(4); // protocol level 4 = MQTT 3.1.1
      final will = packet.will;
      var connectFlags = 0;
      if (packet.username != null) connectFlags |= 0x80;
      if (packet.password != null) connectFlags |= 0x40;
      if (will != null) {
        connectFlags |= 0x04 | (will.qos << 3);
        if (will.retain) connectFlags |= 0x20;
      }
      if (packet.cleanSession) connectFlags |= 0x02;
      body.addByte(connectFlags);
      _addUint16(body, packet.keepAliveSeconds);
      _addString(body, packet.clientId);
      if (will != null) {
        _addString(body, will.topic);
        _addBinary(body, will.message);
      }
      if (packet.username != null) _addString(body, packet.username!);
      if (packet.password != null) _addString(body, packet.password!);
    case MqttConnAck():
      body
        ..addByte(packet.sessionPresent ? 1 : 0)
        ..addByte(packet.returnCode);
    case MqttPublish():
      flags = (packet.duplicate ? 0x08 : 0) | (packet.qos << 1) | (packet.retain ? 1 : 0);
      _addString(body, packet.topic);
      if (packet.qos > 0) {
        final packetId = packet.packetId;
        if (packetId == null) throw ArgumentError('QoS ${packet.qos} PUBLISH needs a packet id');
        _addUint16(body, packetId);
      }
      body.add(packet.payload);
    case MqttPacketIdOnly():
      if (packet.type == MqttPacketType.pubrel) flags = 0x02;
      _addUint16(body, packet.packetId);
    case MqttSubscribe():
      flags = 0x02;
      _addUint16(body, packet.packetId);
      for (final subscription in packet.subscriptions) {
        _addString(body, subscription.topicFilter);
        body.addByte(subscription.qos);
      }
    case MqttSubAck():
      _addUint16(body, packet.packetId);
      body.add(packet.returnCodes);
    case MqttUnsubscribe():
      flags = 0x02;
      _addUint16(body, packet.packetId);
      for (final filter in packet.topicFilters) {
        _addString(body, filter);
      }
    case MqttEmpty():
      break;
  }
  final bodyBytes = body.toBytes();
  return (BytesBuilder()
        ..addByte((packet.type.code << 4) | flags)
        ..add(encodeRemainingLength(bodyBytes.length))
        ..add(bodyBytes))
      .toBytes();
}

// ---- Decode ---------------------------------------------------------------

/// The result of decoding one packet: [packet] is null when the bytes broke
/// a rule; [frame] always explains as much as could be read.
class MqttDecoded {
  const MqttDecoded(this.packet, this.frame);
  final MqttPacket? packet;
  final Frame frame;
}

/// Joins TCP chunks and returns whole packets. TCP has no message borders;
/// MQTT finds them with the remaining-length field.
class MqttStreamSplitter {
  final _pending = BytesBuilder(copy: false);
  Uint8List _buffer = Uint8List(0);

  /// Throws [FormatException] for a remaining length over 4 bytes: the
  /// stream is then broken and the connection must close.
  List<Uint8List> add(Uint8List chunk) {
    _pending
      ..add(_buffer)
      ..add(chunk);
    _buffer = _pending.takeBytes();
    final packets = <Uint8List>[];
    var start = 0;
    while (true) {
      final available = _buffer.length - start;
      if (available < 2) break;
      var length = 0;
      var multiplier = 1;
      var index = start + 1;
      var isComplete = false;
      while (index < _buffer.length) {
        final digit = _buffer[index];
        length += (digit & 0x7f) * multiplier;
        index++;
        if (digit & 0x80 == 0) {
          isComplete = true;
          break;
        }
        multiplier *= 128;
        if (index - start - 1 >= 4) {
          throw const FormatException('MQTT remaining length longer than 4 bytes');
        }
      }
      if (!isComplete || _buffer.length < index + length) break;
      packets.add(Uint8List.fromList(_buffer.sublist(start, index + length)));
      start = index + length;
    }
    _buffer = Uint8List.fromList(_buffer.sublist(start));
    return packets;
  }
}

MqttDecoded decodeMqtt(Uint8List bytes) {
  final reader = FieldReader(bytes);
  MqttPacketType? type;
  try {
    final first = reader.peekUint8();
    type = MqttPacketType.fromCode(first >> 4);
    reader.flags(
      'fixed header',
      [
        BitField('packet type', 4, width: 4, describe: (code) => MqttPacketType.fromCode(code)?.label ?? 'reserved $code'),
        if (type == MqttPacketType.publish) ...[
          BitField('DUP', 3, note: 'resent copy of an earlier PUBLISH', describe: _yesNo),
          BitField('QoS', 1, width: 2, note: '0 at most once · 1 at least once · 2 exactly once'),
          BitField('RETAIN', 0, note: 'broker keeps it for new subscribers', describe: _yesNo),
        ] else
          BitField('flags', 0, width: 4, note: 'fixed per type (0010 for SUBSCRIBE, UNSUBSCRIBE, PUBREL)'),
      ],
    );
    final lengthStart = reader.offset;
    var remainingLength = 0;
    var multiplier = 1;
    while (true) {
      if (reader.offset - lengthStart >= 4) throw const FormatException('remaining length over 4 bytes');
      if (reader.isDone) throw const FormatException('remaining length cut off');
      final digit = reader.bytes[reader.offset];
      reader.offset++;
      remainingLength += (digit & 0x7f) * multiplier;
      multiplier *= 128;
      if (digit & 0x80 == 0) break;
    }
    reader.add('remaining length', lengthStart, '$remainingLength',
        note: '${reader.offset - lengthStart} byte varint: 7 bits each, high bit = more');
    if (reader.remaining != remainingLength) {
      throw FormatException('remaining length says $remainingLength, frame has ${reader.remaining}');
    }
    if (type == null) throw FormatException('reserved packet type ${first >> 4}');
    final packet = _decodeBody(reader, type, first & 0x0f);
    if (!reader.isDone) throw const FormatException('extra bytes after the packet');
    return MqttDecoded(
      packet,
      Frame(protocol: 'MQTT', summary: _summary(packet), bytes: bytes, fields: reader.fields),
    );
  } on FormatException catch (error) {
    return MqttDecoded(
      null,
      Frame(
        protocol: 'MQTT',
        summary: '${type?.label ?? 'bad packet'}: ${error.message}',
        bytes: bytes,
        fields: reader.fields,
        error: error.message,
      ),
    );
  }
}

String _yesNo(int bit) => bit == 1 ? 'yes' : 'no';

String _readString(FieldReader reader, String name, {String note = ''}) {
  final start = reader.offset;
  final length = ByteData.sublistView(reader.take(2, '$name length')).getUint16(0);
  reader.fields.removeLast();
  final value = reader.take(length, name);
  reader.fields.removeLast();
  final text = utf8.decode(value, allowMalformed: true);
  reader.add(name, start, '"$text"', note: note.isEmpty ? '2-byte length + UTF-8' : note);
  return text;
}

Uint8List _readBinary(FieldReader reader, String name) {
  final start = reader.offset;
  final length = ByteData.sublistView(reader.take(2, '$name length')).getUint16(0);
  reader.fields.removeLast();
  final value = reader.take(length, name);
  reader.fields.removeLast();
  reader.add(name, start, textOrHex(value), note: '2-byte length + bytes');
  return value;
}

MqttPacket _decodeBody(FieldReader reader, MqttPacketType type, int flags) {
  switch (type) {
    case MqttPacketType.connect:
      final protocolName = _readString(reader, 'protocol name');
      if (protocolName != 'MQTT') throw FormatException('protocol name "$protocolName", not "MQTT"');
      reader.uint8('protocol level', describe: (level) => level == 4 ? '4 (MQTT 3.1.1)' : '$level', note: '5 would be MQTT 5');
      final connectFlags = reader.flags('connect flags', [
        BitField('user name', 7, describe: _yesNo),
        BitField('password', 6, describe: _yesNo),
        BitField('will retain', 5, describe: _yesNo),
        BitField('will QoS', 3, width: 2),
        BitField('will flag', 2, note: 'broker publishes the will if we vanish', describe: _yesNo),
        BitField('clean session', 1, note: 'forget old subscriptions and queued messages', describe: _yesNo),
      ]);
      final keepAlive = reader.uint16('keep alive', describe: (seconds) => '$seconds s',
          note: 'broker drops us after 1.5 × this with no packet');
      final clientId = _readString(reader, 'client id');
      MqttWill? will;
      if (connectFlags & 0x04 != 0) {
        final topic = _readString(reader, 'will topic');
        final message = _readBinary(reader, 'will message');
        will = MqttWill(topic: topic, message: message, qos: (connectFlags >> 3) & 3, retain: connectFlags & 0x20 != 0);
      }
      final username = connectFlags & 0x80 != 0 ? _readString(reader, 'user name') : null;
      final password = connectFlags & 0x40 != 0 ? _readString(reader, 'password', note: 'sent in clear text unless TLS') : null;
      return MqttConnect(
        clientId: clientId,
        keepAliveSeconds: keepAlive,
        cleanSession: connectFlags & 0x02 != 0,
        username: username,
        password: password,
        will: will,
      );
    case MqttPacketType.connack:
      final ackFlags = reader.uint8('ack flags', describe: (value) => value & 1 == 1 ? 'session present' : 'new session');
      final returnCode = reader.uint8('return code', describe: (code) => '$code ${mqttConnectReturnCodes[code] ?? 'unknown'}');
      return MqttConnAck(sessionPresent: ackFlags & 1 == 1, returnCode: returnCode);
    case MqttPacketType.publish:
      final qos = (flags >> 1) & 3;
      if (qos == 3) throw const FormatException('QoS 3 does not exist');
      final topic = _readString(reader, 'topic');
      final packetId = qos > 0 ? reader.uint16('packet id', note: 'matches the PUBACK / PUBREC') : null;
      final payload = reader.rest('payload', describe: textOrHex, note: 'no length: it is whatever is left');
      return MqttPublish(topic: topic, payload: payload, qos: qos, retain: flags & 1 == 1, duplicate: flags & 8 != 0, packetId: packetId);
    case MqttPacketType.puback || MqttPacketType.pubrec || MqttPacketType.pubrel || MqttPacketType.pubcomp || MqttPacketType.unsuback:
      return MqttPacketIdOnly(type, reader.uint16('packet id'));
    case MqttPacketType.subscribe:
      final packetId = reader.uint16('packet id');
      final subscriptions = <MqttSubscription>[];
      while (!reader.isDone) {
        final filter = _readString(reader, 'topic filter', note: '+ one level, # all below');
        final qos = reader.uint8('requested QoS');
        subscriptions.add(MqttSubscription(filter, qos));
      }
      if (subscriptions.isEmpty) throw const FormatException('SUBSCRIBE with no topic');
      return MqttSubscribe(packetId: packetId, subscriptions: subscriptions);
    case MqttPacketType.suback:
      final packetId = reader.uint16('packet id');
      final codes = <int>[];
      while (!reader.isDone) {
        codes.add(reader.uint8('return code', describe: (code) => code == 0x80 ? '0x80 refused' : 'granted QoS $code'));
      }
      return MqttSubAck(packetId: packetId, returnCodes: codes);
    case MqttPacketType.unsubscribe:
      final packetId = reader.uint16('packet id');
      final filters = <String>[];
      while (!reader.isDone) {
        filters.add(_readString(reader, 'topic filter'));
      }
      return MqttUnsubscribe(packetId: packetId, topicFilters: filters);
    case MqttPacketType.pingreq || MqttPacketType.pingresp || MqttPacketType.disconnect:
      return MqttEmpty(type);
  }
}

String _summary(MqttPacket packet) => switch (packet) {
  MqttConnect(:final clientId, :final keepAliveSeconds) => 'CONNECT "$clientId" keep alive ${keepAliveSeconds}s',
  MqttConnAck(:final returnCode) => 'CONNACK ${mqttConnectReturnCodes[returnCode] ?? returnCode}',
  MqttPublish(:final topic, :final qos, :final retain, :final payload) =>
    'PUBLISH $topic QoS $qos${retain ? ' retained' : ''} ${textOrHex(payload)}',
  MqttPacketIdOnly(:final type, :final packetId) => '${type.label} id $packetId',
  MqttSubscribe(:final subscriptions) =>
    'SUBSCRIBE ${subscriptions.map((item) => '${item.topicFilter} (QoS ${item.qos})').join(', ')}',
  MqttSubAck(:final returnCodes) => 'SUBACK ${returnCodes.map((code) => code == 0x80 ? 'refused' : 'QoS $code').join(', ')}',
  MqttUnsubscribe(:final topicFilters) => 'UNSUBSCRIBE ${topicFilters.join(', ')}',
  MqttEmpty(:final type) => type.label,
};
