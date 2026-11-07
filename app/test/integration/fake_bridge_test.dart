@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/bytes/hex.dart';
import 'package:protocol_lab/core/log/session_log.dart';
import 'package:protocol_lab/core/transport/tcp_link.dart';
import 'package:protocol_lab/protocols/bridge/bridge_client.dart';
import 'package:protocol_lab/protocols/bus/bus_frames.dart';
import 'package:protocol_lab/protocols/modbus/modbus_codec.dart';
import 'package:protocol_lab/protocols/modbus/modbus_master.dart';

/// The app's clients against tool/fake_bridge.py, the contract the firmware
/// follows too:
///   python3 tool/fake_bridge.py --port 13333 --modbus-port 11502 &
///   FAKE_BRIDGE_PORT=13333 FAKE_MODBUS_PORT=11502 flutter test --tags integration
void main() {
  final bridgePort = int.tryParse(Platform.environment['FAKE_BRIDGE_PORT'] ?? '');
  final modbusPort = int.tryParse(Platform.environment['FAKE_MODBUS_PORT'] ?? '');

  test(
    'bridge: ping, I2C chip id, CAN echo event, DS18B20',
    () async {
      final client = BridgeClient(link: await TcpLink.connect('127.0.0.1', bridgePort!), log: SessionLog());
      final info = await client.command('ping') as Map<String, Object?>;
      expect(info['name'], 'protolab-bridge');

      await expectLater(client.command('i2c scan'), throwsA(isA<BridgeError>()));
      await client.command('i2c init 8 9 100000');
      expect(await client.command('i2c scan'), [0x3c, 0x76]);
      final read = await client.command('i2c xfer 0x76 d0 1') as Map<String, Object?>;
      expect(read['read'], '60');

      await client.command('can init 4 5 500000');
      final event = client.events.firstWhere((event) => event['event'] == 'can' && event['id'] == '7df');
      await client.command('can send 7df 0201');
      expect(CanFrame.fromEvent(await event)!.data, [2, 1]);

      await client.command('ow init 6');
      final roms = await client.command('ow search') as List<Object?>;
      expect(describeOneWireRom(parseHex('${roms.single}')).error, isNull);
      final pad = await client.command('ow ds18b20 ${roms.single}') as Map<String, Object?>;
      expect(describeDs18b20Scratchpad(parseHex('${pad['scratchpad']}')).celsius, 25.0625);
      await client.close();
    },
    skip: bridgePort == null ? 'set FAKE_BRIDGE_PORT to a running fake_bridge.py' : false,
  );

  test(
    'Modbus TCP master against the fake slave',
    () async {
      final master = ModbusMaster(link: await TcpLink.connect('127.0.0.1', modbusPort!), log: SessionLog(), mode: ModbusMode.tcp);
      final response = await master.send(const ModbusRequest(unitId: 1, function: ModbusFunction.readHoldingRegisters, address: 5, quantity: 3));
      expect(response.registers, [105, 106, 107]);
      await master.send(const ModbusRequest(unitId: 1, function: ModbusFunction.writeSingleRegister, address: 5, values: [999]));
      final after = await master.send(const ModbusRequest(unitId: 1, function: ModbusFunction.readHoldingRegisters, address: 5, quantity: 1));
      expect(after.registers, [999]);
      await expectLater(
        master.send(const ModbusRequest(unitId: 1, function: ModbusFunction.readHoldingRegisters, address: 99, quantity: 2)),
        throwsA(isA<ModbusException>()),
      );
      await master.close();
    },
    skip: modbusPort == null ? 'set FAKE_MODBUS_PORT to a running fake_bridge.py --modbus-port' : false,
  );
}
