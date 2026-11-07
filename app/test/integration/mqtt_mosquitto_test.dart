@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/log/session_log.dart';
import 'package:protocol_lab/core/transport/tcp_link.dart';
import 'package:protocol_lab/protocols/mqtt/mqtt_client.dart';
import 'package:protocol_lab/protocols/mqtt/mqtt_packet.dart';

/// Our hand-written client against the real Mosquitto broker:
///   mosquitto -p 18830 &
///   MQTT_TEST_PORT=18830 flutter test --tags integration
void main() {
  final port = int.tryParse(Platform.environment['MQTT_TEST_PORT'] ?? '');

  Future<MqttClient> connect(String clientId, {MqttWill? will}) async {
    final link = await TcpLink.connect('127.0.0.1', port!);
    final client = MqttClient(link: link, log: SessionLog());
    await client.connect(MqttConnect(clientId: clientId, keepAliveSeconds: 5, will: will));
    return client;
  }

  test(
    'publish QoS 0/1/2 reaches a subscriber through Mosquitto',
    () async {
      final subscriber = await connect('lab-sub');
      final ack = await subscriber.subscribe(const [MqttSubscription('lab/test/#', 2)]);
      expect(ack.returnCodes, [2]);
      final received = <String>[];
      subscriber.messages.listen((message) => received.add(utf8.decode(message.payload)));

      final publisher = await connect('lab-pub');
      for (final qos in [0, 1, 2]) {
        await publisher.publish('lab/test/qos$qos', Uint8List.fromList(utf8.encode('q$qos')), qos: qos);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(received, unorderedEquals(['q0', 'q1', 'q2']));
      await publisher.disconnect();
      await subscriber.disconnect();
    },
    skip: port == null ? 'set MQTT_TEST_PORT to a running mosquitto' : false,
  );

  test(
    'will message is published when a client drops without DISCONNECT',
    () async {
      final watcher = await connect('lab-watch');
      await watcher.subscribe(const [MqttSubscription('lab/will', 1)]);
      final willMessage = watcher.messages.first;

      final dropped = await connect(
        'lab-drop',
        will: MqttWill(topic: 'lab/will', message: Uint8List.fromList(utf8.encode('gone')), qos: 1),
      );
      await dropped.close(); // no DISCONNECT, like a power cut

      final message = await willMessage.timeout(const Duration(seconds: 5));
      expect(utf8.decode(message.payload), 'gone');
      await watcher.disconnect();
    },
    skip: port == null ? 'set MQTT_TEST_PORT to a running mosquitto' : false,
  );
}
