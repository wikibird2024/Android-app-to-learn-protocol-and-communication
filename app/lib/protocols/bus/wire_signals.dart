import '../../core/bytes/hex.dart';
import '../../core/inspect/wire_trace.dart';

/// Bytes → logic signals, the way each bus puts them on the wire. These
/// are drawings for the Inside view (like a logic analyzer screen), built
/// from the bytes the bridge or the phone saw, not measured.

// ---- UART ------------------------------------------------------------------

enum UartParity { none, even, odd, mark, space }

/// One line, idle high: START (0), data bits LSB first, optional parity,
/// STOP (1). At 115200 baud one bit is 8.68 µs.
WireTrace uartTrace(List<int> bytes, {required int baud, int dataBits = 8, UartParity parity = UartParity.none, int stopBits = 1, String lane = 'TX', int maxBytes = 8}) {
  final bitNs = (1e9 / baud).round();
  final trace = WireTraceBuilder([lane], bitTimeNs: bitNs);
  trace.hold({lane: true}, bitNs);
  for (final value in bytes.take(maxBytes)) {
    var start = trace.timeNs;
    trace.hold({lane: false}, bitNs);
    trace.mark('S', start);
    start = trace.timeNs;
    var ones = 0;
    for (var bit = 0; bit < dataBits; bit++) {
      final isOne = (value >> bit) & 1 == 1;
      if (isOne) ones++;
      trace.hold({lane: isOne}, bitNs);
    }
    trace.mark('${hex8(value)} ${_printable(value)}  (LSB first)', start, WireMarkKind.data);
    if (parity != UartParity.none) {
      start = trace.timeNs;
      // Even parity: the parity bit makes the count of ones even. Mark and
      // space are a fixed 1 and 0.
      final parityBit = switch (parity) {
        UartParity.even => ones.isOdd,
        UartParity.odd => ones.isEven,
        UartParity.mark => true,
        _ => false,
      };
      trace.hold({lane: parityBit}, bitNs);
      trace.mark('P', start);
    }
    start = trace.timeNs;
    trace.hold({lane: true}, bitNs * stopBits);
    trace.mark('stop', start);
  }
  trace.hold({lane: true}, bitNs);
  final more = bytes.length - maxBytes;
  return trace.build(note: '${(1e6 / baud).toStringAsFixed(2)} µs per bit${more > 0 ? ' · first $maxBytes bytes, $more more not drawn' : ''}');
}

String _printable(int value) => value >= 0x20 && value < 0x7f ? "'${String.fromCharCode(value)}'" : '';

// ---- I2C -------------------------------------------------------------------

/// SCL + SDA, both pulled up (idle high). Data changes while SCL is low and
/// is read while SCL is high; START and STOP are the two exceptions: SDA
/// moving while SCL is high.
WireTrace i2cTrace({required int address, required List<int> written, required List<int> read, int clockHz = 100000, bool addressAcked = true}) {
  final halfNs = (1e9 / clockHz / 2).round();
  final trace = WireTraceBuilder(['SCL', 'SDA'], bitTimeNs: halfNs * 2);
  trace.hold({'SCL': true, 'SDA': true}, halfNs);

  void start(String label) {
    final from = trace.timeNs;
    trace.hold({'SDA': true, 'SCL': true}, halfNs);
    trace.hold({'SDA': false}, halfNs); // SDA falls while SCL is high
    trace.hold({'SCL': false}, halfNs);
    trace.mark(label, from);
  }

  void bit(bool isOne) {
    trace.hold({'SCL': false, 'SDA': isOne}, halfNs);
    trace.hold({'SCL': true}, halfNs);
  }

  void byte(int value, String label, {required bool acked, String? ackLabel}) {
    final from = trace.timeNs;
    for (var index = 7; index >= 0; index--) {
      bit((value >> index) & 1 == 1);
    }
    trace.mark(label, from, WireMarkKind.data);
    final ackFrom = trace.timeNs;
    bit(!acked); // ACK = receiver pulls SDA low
    trace.mark(ackLabel ?? (acked ? 'ACK' : 'NACK'), ackFrom, acked ? WireMarkKind.ack : WireMarkKind.nack);
  }

  if (written.isNotEmpty || read.isEmpty) {
    start('S');
    byte(address << 1, '${hex8(address)} + W', acked: addressAcked);
    for (final value in written) {
      byte(value, hex8(value), acked: true);
    }
  }
  if (read.isNotEmpty) {
    start(written.isEmpty ? 'S' : 'Sr');
    byte((address << 1) | 1, '${hex8(address)} + R', acked: addressAcked);
    for (final (index, value) in read.indexed) {
      final isLast = index == read.length - 1;
      byte(value, hex8(value), acked: !isLast, ackLabel: isLast ? 'NACK: last' : 'ACK: more');
    }
  }
  final from = trace.timeNs;
  trace.hold({'SCL': false, 'SDA': false}, halfNs);
  trace.hold({'SCL': true}, halfNs);
  trace.hold({'SDA': true}, halfNs); // SDA rises while SCL is high
  trace.mark('P', from);
  trace.hold({}, halfNs);
  return trace.build(note: '${clockHz ~/ 1000} kHz · SDA may only change while SCL is low, except START and STOP');
}

// ---- SPI -------------------------------------------------------------------

/// CS low selects the device; each SCK period moves one bit out on MOSI
/// and one bit in on MISO at the same time, MSB first. CPOL is the idle
/// clock level; CPHA 0 samples on the first edge, 1 on the second.
WireTrace spiTrace({required List<int> mosi, required List<int> miso, int mode = 0, int clockHz = 1000000, int maxBytes = 6}) {
  final cpol = mode >> 1 == 1;
  final cpha = mode & 1 == 1;
  final halfNs = (1e9 / clockHz / 2).round();
  final trace = WireTraceBuilder(['CS', 'SCK', 'MOSI', 'MISO'], bitTimeNs: halfNs * 2, idle: {'SCK': cpol});
  trace.hold({}, halfNs);
  var from = trace.timeNs;
  trace.hold({'CS': false}, halfNs);
  trace.mark('CS low', from);
  final count = mosi.length < maxBytes ? mosi.length : maxBytes;
  for (var index = 0; index < count; index++) {
    final out = mosi[index];
    final input = index < miso.length ? miso[index] : 0;
    from = trace.timeNs;
    for (var bit = 7; bit >= 0; bit--) {
      final levels = {'MOSI': (out >> bit) & 1 == 1, 'MISO': (input >> bit) & 1 == 1};
      // CPHA 0: data ready before the first edge; CPHA 1: data changes on it.
      trace.hold({...levels, 'SCK': cpha ? !cpol : cpol}, halfNs);
      trace.hold({'SCK': cpha ? cpol : !cpol}, halfNs);
    }
    trace.mark('out ${hex8(out)} · in ${hex8(input)}', from, WireMarkKind.data);
  }
  from = trace.timeNs;
  trace.hold({'CS': true, 'SCK': cpol}, halfNs);
  trace.mark('CS high', from);
  final more = mosi.length - count;
  return trace.build(note: 'mode $mode: clock idles ${cpol ? 'high' : 'low'}, sampled on the ${cpha ? 'second' : 'first'} edge${more > 0 ? ' · $more more bytes not drawn' : ''}');
}

// ---- CAN -------------------------------------------------------------------

/// CRC-15/CAN over a bit stream (polynomial 0x4599, init 0): what the
/// controller appends after the data field.
int canCrc15(List<int> bits) {
  var crc = 0;
  for (final bit in bits) {
    final next = bit ^ ((crc >> 14) & 1);
    crc = (crc << 1) & 0x7fff;
    if (next == 1) crc ^= 0x4599;
  }
  return crc;
}

/// The classic CAN frame as the controller sends it: SOF, arbitration,
/// control, data, CRC-15, then a stuff bit after every 5 equal bits (SOF
/// to CRC), delimiters, the ACK slot and 7 recessive EOF bits.
/// Dominant 0 = low, recessive 1 = high.
({WireTrace trace, int crc, int stuffBits}) canTrace({required int id, required List<int> data, bool isExtended = false, bool isRemote = false, int bitrate = 500000, bool acked = true}) {
  final parts = <(String, List<int>)>[];
  List<int> bitsOf(int value, int width) => [for (var index = width - 1; index >= 0; index--) (value >> index) & 1];
  parts.add(('SOF', [0]));
  if (isExtended) {
    parts
      ..add(('ID 28..18', bitsOf(id >> 18, 11)))
      ..add(('SRR', [1]))
      ..add(('IDE', [1]))
      ..add(('ID 17..0', bitsOf(id & 0x3ffff, 18)))
      ..add(('RTR', [isRemote ? 1 : 0]))
      ..add(('r1 r0', [0, 0]));
  } else {
    parts
      ..add(('ID ${id.toRadixString(16)}', bitsOf(id, 11)))
      ..add(('RTR', [isRemote ? 1 : 0]))
      ..add(('IDE', [0]))
      ..add(('r0', [0]));
  }
  parts.add(('DLC ${data.length}', bitsOf(data.length, 4)));
  if (!isRemote) {
    for (final (index, value) in data.take(8).indexed) {
      parts.add(('D$index ${hex8(value)}', bitsOf(value, 8)));
    }
  }
  final crc = canCrc15([for (final part in parts) ...part.$2]);
  parts.add(('CRC ${crc.toRadixString(16)}', bitsOf(crc, 15)));

  final bitNs = (1e9 / bitrate).round();
  final trace = WireTraceBuilder(['CAN'], bitTimeNs: bitNs);
  trace.hold({'CAN': true}, bitNs * 2); // bus idle (recessive)
  var run = 0;
  var last = -1;
  var stuffBits = 0;
  for (final (name, bits) in parts) {
    final from = trace.timeNs;
    for (final bit in bits) {
      trace.hold({'CAN': bit == 1}, bitNs);
      run = bit == last ? run + 1 : 1;
      last = bit;
      if (run == 5) {
        final stuffFrom = trace.timeNs;
        final stuff = 1 - bit;
        trace.hold({'CAN': stuff == 1}, bitNs);
        trace.mark('stuff', stuffFrom, WireMarkKind.stuff);
        stuffBits++;
        run = 1;
        last = stuff;
      }
    }
    trace.mark(name, from, name.startsWith('D') && !name.startsWith('DLC') ? WireMarkKind.data : WireMarkKind.field);
  }
  var from = trace.timeNs;
  trace.hold({'CAN': true}, bitNs);
  trace.mark('CRC del', from);
  from = trace.timeNs;
  trace.hold({'CAN': !acked}, bitNs); // a receiver drives the slot dominant
  trace.mark(acked ? 'ACK' : 'no ACK', from, acked ? WireMarkKind.ack : WireMarkKind.nack);
  from = trace.timeNs;
  trace.hold({'CAN': true}, bitNs);
  trace.mark('ACK del', from);
  from = trace.timeNs;
  trace.hold({'CAN': true}, bitNs * 7);
  trace.mark('EOF', from);
  trace.hold({'CAN': true}, bitNs * 3);
  return (
    trace: trace.build(note: '${bitrate ~/ 1000} kbit/s · low = dominant 0 · $stuffBits stuff bits added by the controller'),
    crc: crc,
    stuffBits: stuffBits,
  );
}

// ---- 1-Wire ----------------------------------------------------------------

/// One data line pulled up to 3.3 V. Reset: master low 480 µs, the device
/// answers with a presence pulse. Then time slots, LSB first: write 1 =
/// short low, write 0 = long low, read = short low, then the device holds
/// the line low for a 0 or lets it go for a 1.
WireTrace oneWireTrace({required List<int> written, required List<int> read, List<String> writtenLabels = const [], int maxReadBytes = 2}) {
  const us = 1000;
  final trace = WireTraceBuilder(['DQ'], bitTimeNs: 70 * us);
  trace.hold({'DQ': true}, 20 * us);
  var from = trace.timeNs;
  trace.hold({'DQ': false}, 480 * us);
  trace.mark('reset (master)', from);
  trace.hold({'DQ': true}, 70 * us);
  from = trace.timeNs;
  trace.hold({'DQ': false}, 120 * us);
  trace.mark('presence', from, WireMarkKind.ack);
  trace.hold({'DQ': true}, 290 * us);
  for (final (index, value) in written.indexed) {
    from = trace.timeNs;
    for (var bit = 0; bit < 8; bit++) {
      final isOne = (value >> bit) & 1 == 1;
      trace.hold({'DQ': false}, (isOne ? 6 : 60) * us);
      trace.hold({'DQ': true}, (isOne ? 64 : 10) * us);
    }
    trace.mark(index < writtenLabels.length ? writtenLabels[index] : 'write ${hex8(value)}', from);
  }
  final shown = read.take(maxReadBytes).toList();
  for (final (index, value) in shown.indexed) {
    from = trace.timeNs;
    for (var bit = 0; bit < 8; bit++) {
      final isOne = (value >> bit) & 1 == 1;
      trace.hold({'DQ': false}, (isOne ? 6 : 30) * us);
      trace.hold({'DQ': true}, (isOne ? 64 : 40) * us);
    }
    trace.mark('read [$index] ${hex8(value)}', from, WireMarkKind.data);
  }
  trace.hold({'DQ': true}, 20 * us);
  final more = read.length - shown.length;
  return trace.build(note: 'standard speed, 70 µs slots, LSB first${more > 0 ? ' · $more more bytes not drawn' : ''}');
}
