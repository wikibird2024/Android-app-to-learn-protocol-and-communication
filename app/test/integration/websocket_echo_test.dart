@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/log/session_log.dart';
import 'package:protocol_lab/core/transport/tcp_link.dart';
import 'package:protocol_lab/protocols/websocket/ws_client.dart';

/// The hand-written WebSocket client against a real socket server (the
/// echo in tool/fake_bridge.py, written separately in Python):
///   python3 tool/fake_bridge.py --ws-port 18081 &
///   FAKE_WS_PORT=18081 flutter test --tags integration
void main() {
  final port = int.tryParse(Platform.environment['FAKE_WS_PORT'] ?? '');

  test(
    'upgrade, text and 300-byte binary echo, close handshake',
    () async {
      final log = SessionLog();
      final client = WsClient(link: await TcpLink.connect('127.0.0.1', port!), log: log);
      await client.handshake(Uri.parse('ws://127.0.0.1:$port/echo'));
      final messages = client.messages.take(2).toList();
      await client.send(Uint8List.fromList(utf8.encode('hello bench')), isText: true);
      await client.send(Uint8List.fromList(List.generate(300, (index) => index & 0xff)), isText: false);
      final echoed = await messages.timeout(const Duration(seconds: 5));
      expect((echoed[0].isText, utf8.decode(echoed[0].payload)), (true, 'hello bench'));
      expect(echoed[1].payload, List.generate(300, (index) => index & 0xff));
      await client.close();
      expect(client.closeCode, 1000);
      expect(log.entries.any((entry) => entry.frame.summary.startsWith('CLOSE')), isTrue);
    },
    skip: port == null ? 'set FAKE_WS_PORT to a running fake_bridge.py --ws-port' : false,
  );
}
