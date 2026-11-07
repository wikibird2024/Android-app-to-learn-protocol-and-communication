import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/bytes/hex.dart';
import 'package:protocol_lab/core/log/session_log.dart';
import 'package:protocol_lab/core/transport/link.dart';
import 'package:protocol_lab/protocols/modbus/modbus_codec.dart';
import 'package:protocol_lab/protocols/modbus/modbus_master.dart';

const _readExample = ModbusRequest(
  unitId: 0x11,
  function: ModbusFunction.readHoldingRegisters,
  address: 0x006b,
  quantity: 3,
);

void main() {
  test('CRC of the classic spec example 11 03 00 6B 00 03 is 76 87', () {
    expect(toHex(encodeModbusRtu(_readExample)), '11 03 00 6b 00 03 76 87');
  });

  test('TCP wraps the same PDU in MBAP', () {
    expect(toHex(encodeModbusTcp(_readExample, 1)), '00 01 00 00 00 06 11 03 00 6b 00 03');
  });

  test('write requests', () {
    expect(
      toHex(encodeModbusPdu(const ModbusRequest(unitId: 1, function: ModbusFunction.writeSingleCoil, address: 0xac, values: [1]))),
      '05 00 ac ff 00',
    );
    // Spec example: coils 20..29 = 1100 1101 01
    expect(
      toHex(encodeModbusPdu(const ModbusRequest(
        unitId: 1,
        function: ModbusFunction.writeMultipleCoils,
        address: 0x13,
        values: [1, 0, 1, 1, 0, 0, 1, 1, 1, 0],
      ))),
      '0f 00 13 00 0a 02 cd 01',
    );
    expect(
      toHex(encodeModbusPdu(const ModbusRequest(
        unitId: 1,
        function: ModbusFunction.writeMultipleRegisters,
        address: 1,
        values: [0x000a, 0x0102],
      ))),
      '10 00 01 00 02 04 00 0a 01 02',
    );
  });

  test('bad requests are refused before sending', () {
    for (final request in const [
      ModbusRequest(unitId: 1, function: ModbusFunction.readHoldingRegisters, address: 0, quantity: 126),
      ModbusRequest(unitId: 1, function: ModbusFunction.readCoils, address: 0, quantity: 0),
      ModbusRequest(unitId: 1, function: ModbusFunction.writeSingleRegister, address: 0, values: [70000]),
      ModbusRequest(unitId: 1, function: ModbusFunction.readInputRegisters, address: 65535, quantity: 2),
    ]) {
      expect(() => encodeModbusPdu(request), throwsArgumentError);
    }
  });

  test('decode the spec read response', () {
    final reply = parseHex('11 03 06 ae 41 56 52 43 40');
    final crc = modbusCrc16(reply);
    final bytes = Uint8List.fromList([...reply, crc & 0xff, crc >> 8]);
    expect(rtuResponseLength(bytes), bytes.length);
    final decoded = decodeModbusRtu(bytes, isRequest: false);
    expect(decoded.frame.error, isNull);
    expect(decoded.response!.registers, [0xae41, 0x5652, 0x4340]);
    expect(decoded.frame.fields.last.name, 'CRC');
  });

  test('bad CRC and exception replies', () {
    final badCrc = decodeModbusRtu(parseHex('11 03 00 6b 00 03 76 88'), isRequest: true);
    expect(badCrc.frame.error, contains('CRC'));
    final exception = Uint8List.fromList([0x11, 0x83, 0x02]);
    final crc = modbusCrc16(exception);
    final decoded = decodeModbusRtu(Uint8List.fromList([...exception, crc & 0xff, crc >> 8]), isRequest: false);
    expect(decoded.response!.exceptionCode, 2);
    expect(decoded.frame.summary, contains('illegal data address'));
  });

  test('read coils response unpacks bits lowest first', () {
    final decoded = decodeModbusTcp(parseHex('00 07 00 00 00 05 01 01 02 cd 01'), isRequest: false);
    expect(decoded.transactionId, 7);
    expect(decoded.response!.bits.take(10), [true, false, true, true, false, false, true, true, true, false]);
  });

  group('master', () {
    /// A slave with registers 0..9 = 100..109; anything past 9 is an
    /// illegal address. Answers in [chunkSize]-byte pieces like a slow UART.
    FakeLink slaveLink({required bool isTcp, int chunkSize = 3, bool isSilent = false}) {
      final link = FakeLink();
      link.onSend = (request) {
        if (isSilent) return;
        final pdu = isTcp ? request.sublist(7) : request.sublist(1, request.length - 2);
        final unit = isTcp ? request[6] : request[0];
        final address = pdu[1] << 8 | pdu[2];
        final quantity = pdu[3] << 8 | pdu[4];
        final List<int> replyPdu = address + quantity > 10
            ? [0x83, 0x02]
            : [0x03, quantity * 2, for (var index = 0; index < quantity; index++) ...[0, 100 + address + index]];
        final List<int> frame;
        if (isTcp) {
          frame = [request[0], request[1], 0, 0, 0, replyPdu.length + 1, unit, ...replyPdu];
        } else {
          final body = [unit, ...replyPdu];
          final crc = modbusCrc16(body);
          frame = [...body, crc & 0xff, crc >> 8];
        }
        scheduleMicrotask(() {
          for (var start = 0; start < frame.length; start += chunkSize) {
            link.deliver(frame.sublist(start, (start + chunkSize).clamp(0, frame.length)));
          }
        });
      };
      return link;
    }

    for (final mode in ModbusMode.values) {
      test('$mode reads registers', () async {
        final log = SessionLog();
        final master = ModbusMaster(link: slaveLink(isTcp: mode == ModbusMode.tcp), log: log, mode: mode);
        final response = await master.send(const ModbusRequest(unitId: 1, function: ModbusFunction.readHoldingRegisters, address: 2, quantity: 3));
        expect(response.registers, [102, 103, 104]);
        await expectLater(
          master.send(const ModbusRequest(unitId: 1, function: ModbusFunction.readHoldingRegisters, address: 9, quantity: 2)),
          throwsA(isA<ModbusException>().having((error) => error.code, 'code', 2)),
        );
        expect(log.length, 4);
      });
    }

    test('silent slave times out, next request still works', () async {
      final master = ModbusMaster(
        link: slaveLink(isTcp: false, isSilent: true),
        log: SessionLog(),
        mode: ModbusMode.rtu,
        timeout: const Duration(milliseconds: 50),
      );
      await expectLater(
        master.send(const ModbusRequest(unitId: 1, function: ModbusFunction.readHoldingRegisters, address: 0, quantity: 1)),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
