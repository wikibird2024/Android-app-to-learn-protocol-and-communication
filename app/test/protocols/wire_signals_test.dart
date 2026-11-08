import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/inspect/wire_trace.dart';
import 'package:protocol_lab/protocols/bus/wire_signals.dart';

/// Level of [lane] in the middle of bit [index] (bit 0 starts at [startNs]).
bool _bitAt(WireLane lane, int startNs, int bitNs, int index) => lane.levelAt(startNs + index * bitNs + bitNs ~/ 2);

void main() {
  group('UART', () {
    test("'A' 8N1: start 0, data LSB first, stop 1", () {
      final trace = uartTrace([0x41], baud: 115200);
      final lane = trace.lanes.single;
      final bitNs = trace.bitTimeNs;
      // One idle bit, then: start, 1 0 0 0 0 0 1 0 (0x41 LSB first), stop.
      final bits = [for (var index = 0; index < 11; index++) _bitAt(lane, 0, bitNs, index) ? 1 : 0];
      expect(bits, [1, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1]);
    });

    test('even parity makes the count of ones even', () {
      // 0x41 has two ones: even parity bit = 0; 0x43 has three: bit = 1.
      for (final (value, parityBit) in [(0x41, false), (0x43, true)]) {
        final trace = uartTrace([value], baud: 9600, parity: UartParity.even);
        final lane = trace.lanes.single;
        expect(_bitAt(lane, 0, trace.bitTimeNs, 10), parityBit, reason: '0x${value.toRadixString(16)}');
      }
    });
  });

  group('I2C', () {
    test('START: SDA falls while SCL is high; ACK pulls SDA low on the 9th clock', () {
      final trace = i2cTrace(address: 0x76, written: [0xd0], read: []);
      final scl = trace.lanes[0];
      final sda = trace.lanes[1];
      final start = trace.marks.firstWhere((mark) => mark.label == 'S');
      final sdaFall = start.startNs + trace.bitTimeNs ~/ 2; // after the "both high" half
      expect(scl.levelAt(sdaFall + 1), isTrue);
      expect(sda.levelAt(sdaFall - 1), isTrue);
      expect(sda.levelAt(sdaFall + 1), isFalse);
      final ack = trace.marks.firstWhere((mark) => mark.label == 'ACK');
      final sclHigh = ack.startNs + trace.bitTimeNs * 3 ~/ 4;
      expect(scl.levelAt(sclHigh), isTrue);
      expect(sda.levelAt(sclHigh), isFalse);
    });

    test('address byte 0x76 + W is 0xEC on SDA, MSB first', () {
      final trace = i2cTrace(address: 0x76, written: [0xd0], read: []);
      final sda = trace.lanes[1];
      final address = trace.marks.firstWhere((mark) => mark.label.contains('+ W'));
      final bits = [
        for (var index = 0; index < 8; index++) sda.levelAt(address.startNs + index * trace.bitTimeNs + trace.bitTimeNs * 3 ~/ 4) ? 1 : 0,
      ];
      expect(bits, [1, 1, 1, 0, 1, 1, 0, 0]);
    });

    test('a read ends with NACK then STOP (SDA rises while SCL high)', () {
      final trace = i2cTrace(address: 0x76, written: [0xd0], read: [0x60]);
      expect(trace.marks.map((mark) => mark.label), containsAllInOrder(['S', 'Sr', 'NACK: last', 'P']));
      final stop = trace.marks.last;
      expect(trace.lanes[1].levelAt(stop.endNs - 1), isTrue);
      expect(trace.lanes[0].levelAt(stop.endNs - 1), isTrue);
    });
  });

  group('SPI', () {
    test('mode 0 idles low, mode 3 idles high; MOSI carries 0x9F MSB first', () {
      expect(spiTrace(mosi: [0x9f], miso: [0], mode: 0).lanes[1].levelAt(0), isFalse);
      expect(spiTrace(mosi: [0x9f], miso: [0], mode: 3).lanes[1].levelAt(0), isTrue);
      final trace = spiTrace(mosi: [0x9f], miso: [0xef], mode: 0);
      final byte = trace.marks.firstWhere((mark) => mark.kind == WireMarkKind.data);
      int read(WireLane lane) {
        var value = 0;
        for (var bit = 0; bit < 8; bit++) {
          // Mode 0 samples on the rising edge: the second half of each bit.
          value = value << 1 | (lane.levelAt(byte.startNs + bit * trace.bitTimeNs + trace.bitTimeNs * 3 ~/ 4) ? 1 : 0);
        }
        return value;
      }

      expect(read(trace.lanes[2]), 0x9f);
      expect(read(trace.lanes[3]), 0xef);
    });
  });

  group('CAN', () {
    test('CRC-15/CAN check value: "123456789" → 0x059E (CRC catalogue)', () {
      final bits = [
        for (final byte in utf8.encode('123456789'))
          for (var index = 7; index >= 0; index--) (byte >> index) & 1,
      ];
      expect(canCrc15(bits), 0x059e);
    });

    test('stuffing: never 6 equal bits from SOF to CRC, and the count matches', () {
      for (final (id, data) in [(0x000, <int>[0, 0, 0]), (0x7ff, <int>[0xff, 0xff]), (0x123, <int>[1, 2, 3, 4])]) {
        final result = canTrace(id: id, data: data);
        final lane = result.trace.lanes.single;
        final bitNs = result.trace.bitTimeNs;
        final crcMark = result.trace.marks.firstWhere((mark) => mark.label.startsWith('CRC ') && mark.kind == WireMarkKind.field);
        final sof = result.trace.marks.first;
        final count = (crcMark.endNs - sof.startNs) ~/ bitNs;
        var run = 0;
        bool? last;
        for (var index = 0; index < count; index++) {
          final level = _bitAt(lane, sof.startNs, bitNs, index);
          run = level == last ? run + 1 : 1;
          last = level;
          expect(run, lessThanOrEqualTo(5), reason: 'id 0x${id.toRadixString(16)} bit $index');
        }
        final rawBits = 1 + 11 + 3 + 4 + data.length * 8 + 15;
        expect(count, rawBits + result.stuffBits);
        expect(result.trace.marks.where((mark) => mark.kind == WireMarkKind.stuff).length, result.stuffBits);
      }
    });

    test('the ACK slot is dominant (low) when a receiver acked', () {
      final result = canTrace(id: 0x123, data: [1]);
      final ack = result.trace.marks.firstWhere((mark) => mark.label == 'ACK');
      expect(result.trace.lanes.single.levelAt(ack.startNs + 1), isFalse);
    });
  });

  group('1-Wire', () {
    test('reset low 480 µs, presence pulse, then write 1 = short low', () {
      final trace = oneWireTrace(written: [0x01], read: []);
      final lane = trace.lanes.single;
      final reset = trace.marks.firstWhere((mark) => mark.label.startsWith('reset'));
      expect(reset.endNs - reset.startNs, 480000);
      expect(trace.marks.any((mark) => mark.label == 'presence' && mark.kind == WireMarkKind.ack), isTrue);
      final write = trace.marks.firstWhere((mark) => mark.label.startsWith('write'));
      // Bit 0 of 0x01 is 1: low for 6 µs only.
      expect(lane.levelAt(write.startNs + 3000), isFalse);
      expect(lane.levelAt(write.startNs + 10000), isTrue);
      // Bit 1 is 0: still low at 30 µs into its slot.
      expect(lane.levelAt(write.startNs + 70000 + 30000), isFalse);
    });
  });
}
