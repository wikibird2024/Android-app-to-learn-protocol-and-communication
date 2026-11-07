import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/inspect/frame.dart';
import 'package:protocol_lab/core/log/log_export.dart';
import 'package:protocol_lab/core/log/session_log.dart';

void main() {
  final time = DateTime.utc(2026, 11, 8, 10);
  final log = SessionLog(clock: () => time)
    ..sent(Frame.raw('t', Uint8List.fromList([1, 2, 3]), summary: 'say "hi"'))
    ..note('connected')
    ..received(Frame.raw('t', Uint8List.fromList([4])));

  test('CSV quotes and hex', () {
    expect(
      logToCsv(log.entries),
      'time,direction,protocol,summary,hex\n'
      '2026-11-08T10:00:00.000Z,sent,t,"say ""hi""",010203\n'
      '2026-11-08T10:00:00.000Z,note,note,"connected",\n'
      '2026-11-08T10:00:00.000Z,received,t,"04",04\n',
    );
  });

  test('pcap TCP: global header, two packets, valid IP checksum', () {
    final pcap = logToPcap(log.entries, const PcapTcp(1883));
    final data = ByteData.sublistView(pcap);
    expect(data.getUint32(0, Endian.little), 0xa1b2c3d4);
    expect(data.getUint32(20, Endian.little), 101);
    final firstLength = data.getUint32(24 + 8, Endian.little);
    expect(firstLength, 20 + 20 + 3);
    final ip = Uint8List.sublistView(pcap, 40, 60);
    var sum = 0;
    for (var index = 0; index < 20; index += 2) {
      sum += ip[index] << 8 | ip[index + 1];
    }
    while (sum > 0xffff) {
      sum = (sum & 0xffff) + (sum >> 16);
    }
    expect(sum, 0xffff, reason: 'IPv4 header checksum must sum to all ones');
    // Destination port of the first (phone → device) packet.
    expect(ByteData.sublistView(pcap, 60).getUint16(2), 1883);
    expect(pcap.length, 24 + (16 + 43) + (16 + 41));
  });

  test('log capacity drops the oldest', () {
    final small = SessionLog(capacity: 2)
      ..note('a')
      ..note('b')
      ..note('c');
    expect(small.entries.map((entry) => entry.frame.summary), ['b', 'c']);
  });
}
