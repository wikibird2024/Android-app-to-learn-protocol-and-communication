import 'dart:typed_data';

import '../bytes/hex.dart';
import 'session_log.dart';

/// `time,direction,protocol,summary,hex` with one row per entry. Opens in a
/// spreadsheet; quotes are doubled as CSV requires.
String logToCsv(List<LogEntry> entries) {
  String quote(String text) => '"${text.replaceAll('"', '""')}"';
  final rows = ['time,direction,protocol,summary,hex'];
  for (final entry in entries) {
    rows.add(
      [
        entry.time.toIso8601String(),
        entry.direction.name,
        entry.frame.protocol,
        quote(entry.frame.summary),
        toHex(entry.bytes, separator: ''),
      ].join(','),
    );
  }
  return '${rows.join('\n')}\n';
}

/// How [logToPcap] wraps each entry so Wireshark picks the right dissector.
sealed class PcapLink {
  const PcapLink();
}

/// Bytes of a TCP stream. Each entry becomes an IPv4+TCP packet between the
/// phone (10.0.0.1) and the device (10.0.0.2:[port]), so Wireshark decodes
/// MQTT on 1883, Modbus/TCP on 502, HTTP on 80 by itself.
class PcapTcp extends PcapLink {
  const PcapTcp(this.port);
  final int port;
}

/// Same as [PcapTcp] for UDP (CoAP 5683, mDNS 5353).
class PcapUdp extends PcapLink {
  const PcapUdp(this.port);
  final int port;
}

/// Entries already hold SocketCAN frames (16 bytes each, see can_frame.dart).
class PcapSocketCan extends PcapLink {
  const PcapSocketCan();
}

/// Anything else (serial, Modbus RTU, BLE values): DLT_USER0. In Wireshark,
/// Preferences → Protocols → DLT_USER picks the dissector.
class PcapUser extends PcapLink {
  const PcapUser();
}

const _linkTypeRawIp = 101;
const _linkTypeSocketCan = 227;
const _linkTypeUser0 = 147;
const _phonePort = 50000;
const _ipHeaderLength = 20;
const _tcpHeaderLength = 20;
const _udpHeaderLength = 8;

/// A classic libpcap file (microsecond timestamps). Notes are skipped: they
/// have no bytes on the wire.
Uint8List logToPcap(List<LogEntry> entries, PcapLink link) {
  final out = BytesBuilder();
  final header = ByteData(24)
    ..setUint32(0, 0xa1b2c3d4, Endian.little)
    ..setUint16(4, 2, Endian.little)
    ..setUint16(6, 4, Endian.little)
    ..setUint32(16, 65535, Endian.little)
    ..setUint32(
      20,
      switch (link) {
        PcapTcp() || PcapUdp() => _linkTypeRawIp,
        PcapSocketCan() => _linkTypeSocketCan,
        PcapUser() => _linkTypeUser0,
      },
      Endian.little,
    );
  out.add(header.buffer.asUint8List());

  // TCP sequence numbers per direction, so Wireshark sees one clean stream.
  var phoneSequence = 1;
  var deviceSequence = 1;
  for (final entry in entries) {
    if (entry.direction == Direction.note) continue;
    final fromPhone = entry.direction == Direction.sent;
    final Uint8List packet;
    switch (link) {
      case PcapTcp(:final port):
        packet = _ipPacket(
          fromPhone: fromPhone,
          protocolNumber: 6,
          transport: _tcpSegment(
            fromPhone: fromPhone,
            devicePort: port,
            sequence: fromPhone ? phoneSequence : deviceSequence,
            acknowledge: fromPhone ? deviceSequence : phoneSequence,
            payload: entry.bytes,
          ),
        );
        if (fromPhone) {
          phoneSequence += entry.bytes.length;
        } else {
          deviceSequence += entry.bytes.length;
        }
      case PcapUdp(:final port):
        packet = _ipPacket(
          fromPhone: fromPhone,
          protocolNumber: 17,
          transport: _udpDatagram(
            fromPhone: fromPhone,
            devicePort: port,
            payload: entry.bytes,
          ),
        );
      case PcapSocketCan() || PcapUser():
        packet = entry.bytes;
    }
    final micros = entry.time.microsecondsSinceEpoch;
    final record = ByteData(16)
      ..setUint32(0, micros ~/ 1000000, Endian.little)
      ..setUint32(4, micros % 1000000, Endian.little)
      ..setUint32(8, packet.length, Endian.little)
      ..setUint32(12, packet.length, Endian.little);
    out
      ..add(record.buffer.asUint8List())
      ..add(packet);
  }
  return out.toBytes();
}

Uint8List _ipPacket({
  required bool fromPhone,
  required int protocolNumber,
  required Uint8List transport,
}) {
  final total = _ipHeaderLength + transport.length;
  final header = ByteData(_ipHeaderLength)
    ..setUint8(0, 0x45) // version 4, header 5 words
    ..setUint16(2, total)
    ..setUint8(8, 64) // TTL
    ..setUint8(9, protocolNumber);
  final phone = [10, 0, 0, 1];
  final device = [10, 0, 0, 2];
  final source = fromPhone ? phone : device;
  final destination = fromPhone ? device : phone;
  for (var index = 0; index < 4; index++) {
    header
      ..setUint8(12 + index, source[index])
      ..setUint8(16 + index, destination[index]);
  }
  header.setUint16(10, _internetChecksum(header.buffer.asUint8List()));
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(transport))
      .toBytes();
}

Uint8List _tcpSegment({
  required bool fromPhone,
  required int devicePort,
  required int sequence,
  required int acknowledge,
  required Uint8List payload,
}) {
  const flagsPushAck = 0x18;
  final header = ByteData(_tcpHeaderLength)
    ..setUint16(0, fromPhone ? _phonePort : devicePort)
    ..setUint16(2, fromPhone ? devicePort : _phonePort)
    ..setUint32(4, sequence)
    ..setUint32(8, acknowledge)
    ..setUint8(12, (_tcpHeaderLength ~/ 4) << 4)
    ..setUint8(13, flagsPushAck)
    ..setUint16(14, 65535); // window
  // Checksum left 0: Wireshark does not check it by default.
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(payload))
      .toBytes();
}

Uint8List _udpDatagram({
  required bool fromPhone,
  required int devicePort,
  required Uint8List payload,
}) {
  final header = ByteData(_udpHeaderLength)
    ..setUint16(0, fromPhone ? _phonePort : devicePort)
    ..setUint16(2, fromPhone ? devicePort : _phonePort)
    ..setUint16(4, _udpHeaderLength + payload.length);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(payload))
      .toBytes();
}

/// RFC 1071 one's-complement sum, the checksum of the IPv4 header.
int _internetChecksum(Uint8List bytes) {
  var sum = 0;
  for (var index = 0; index + 1 < bytes.length; index += 2) {
    sum += (bytes[index] << 8) | bytes[index + 1];
  }
  if (bytes.length.isOdd) sum += bytes.last << 8;
  while (sum > 0xffff) {
    sum = (sum & 0xffff) + (sum >> 16);
  }
  return ~sum & 0xffff;
}
