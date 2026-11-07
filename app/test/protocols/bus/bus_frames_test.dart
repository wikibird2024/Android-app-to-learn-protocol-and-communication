import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/bytes/hex.dart';
import 'package:protocol_lab/protocols/bus/bus_frames.dart';

void main() {
  test('I2C register read shows address+W, register, address+R, data', () {
    final frame = describeI2cTransaction(address: 0x76, written: Uint8List.fromList([0xd0]), read: Uint8List.fromList([0x60]));
    expect(toHex(frame.bytes), 'ec d0 ed 60');
    expect(frame.fields.last.note, contains('NACK'));
    expect(frame.summary, 'I2C 0x76 write d0, read 60');
  });

  test('CAN frame to SocketCAN bytes (big-endian id, EFF flag)', () {
    final standard = CanFrame(id: 0x123, data: Uint8List.fromList([1, 2]));
    expect(toHex(standard.toSocketCan()), '00 00 01 23 02 00 00 00 01 02 00 00 00 00 00 00');
    final extended = CanFrame(id: 0x18daf110, data: Uint8List(0), isExtended: true);
    expect(toHex(extended.toSocketCan().sublist(0, 4)), '98 da f1 10');
    expect(describeCanFrame(standard).summary, '123 [2] 01 02');
  });

  test('CAN frame from a bridge event', () {
    final frame = CanFrame.fromEvent({'event': 'can', 'id': '7df', 'ext': false, 'rtr': false, 'data': '0201'});
    expect(frame!.id, 0x7df);
    expect(frame.data, [2, 1]);
    expect(CanFrame.fromEvent({'id': 'zz', 'data': ''}), isNull);
  });

  test('1-Wire CRC-8: the worked example of Maxim App Note 27', () {
    final rom = parseHex('02 1c b8 01 00 00 00 a2');
    expect(oneWireCrc8(rom.sublist(0, 7)), 0xa2);
    expect(describeOneWireRom(rom).error, isNull);
    expect(describeOneWireRom(parseHex('02 1c b8 01 00 00 00 00')).error, 'bad CRC');
  });

  test('DS18B20 scratchpad: 0x0191 = 25.0625 °C, negative values', () {
    Uint8List pad(int low, int high) {
      final body = [low, high, 0x4b, 0x46, 0x7f, 0xff, 0x0f, 0x10];
      return Uint8List.fromList([...body, oneWireCrc8(body)]);
    }
    expect(describeDs18b20Scratchpad(pad(0x91, 0x01)).celsius, 25.0625);
    expect(describeDs18b20Scratchpad(pad(0x5e, 0xff)).celsius, -10.125);
    final broken = pad(0x91, 0x01)..[8] ^= 1;
    expect(describeDs18b20Scratchpad(broken).celsius, isNull);
  });
}
