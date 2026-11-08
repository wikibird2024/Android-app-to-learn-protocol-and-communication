import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/log/session_log.dart';
import '../../core/transport/link.dart';
import '../../protocols/bridge/bridge_client.dart';

/// The one connection to the ESP32 bridge, shared by every bus tool (I2C,
/// SPI, CAN...). It lives while the app runs, so moving between tools
/// keeps the bridge connected.
class BridgeConnection extends ChangeNotifier {
  /// Text lines to and from the bridge; each bus tool logs its own decoded
  /// bus frames separately.
  final log = SessionLog();
  BridgeClient? _client;
  Map<String, Object?> info = const {};

  bool get isConnected => _client != null;
  String get description => _client?.link.description ?? 'not connected';
  Stream<Map<String, Object?>> get events => _client?.events ?? const Stream.empty();

  /// Features the firmware reports in `ping`: i2c, spi, can, onewire,
  /// espnow, zigbee, thread.
  List<String> get features => [for (final feature in (info['features'] as List<dynamic>? ?? const [])) '$feature'];

  Future<void> connect(Link link) async {
    await disconnect();
    final client = BridgeClient(link: link, log: log);
    _client = client;
    log.note('opened ${link.description}');
    unawaited(link.incoming.drain<void>().whenComplete(() {
      if (identical(_client, client)) {
        _client = null;
        log.note('bridge link closed');
        notifyListeners();
      }
    }));
    try {
      final reply = await client.command('ping');
      info = reply is Map<String, Object?> ? reply : const {};
    } on Object {
      await disconnect();
      rethrow;
    }
    notifyListeners();
  }

  /// Throws [StateError] when not connected, [BridgeError] for an error
  /// reply, [TimeoutException] when the bridge is silent.
  Future<Object?> command(String text, {Duration? timeout}) {
    final client = _client;
    if (client == null) throw StateError('Bridge not connected: open the ESP32 bridge tool first');
    return client.command(text, timeout: timeout);
  }

  Future<void> disconnect() async {
    final client = _client;
    _client = null;
    info = const {};
    if (client != null) {
      await client.close();
      log.note('closed');
    }
    notifyListeners();
  }
}

final bridgeConnectionProvider = Provider<BridgeConnection>((ref) {
  final connection = BridgeConnection();
  ref.onDispose(connection.dispose);
  return connection;
});

/// Shown by bus tools while the bridge is not connected.
class BridgeMissing extends StatelessWidget {
  const BridgeMissing({super.key, this.feature});

  final String? feature;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.developer_board_off, size: 48),
        const SizedBox(height: 12),
        Text(feature == null
            ? 'This tool talks through the ESP32 bridge. Connect it first.'
            : 'The connected bridge has no "$feature" (wrong chip or turned off in its build).'),
        const SizedBox(height: 12),
        // push, not go: go replaces this tool, so Back would skip it to Home.
        FilledButton(onPressed: () => context.push('/tool/bridge'), child: const Text('Open ESP32 bridge')),
      ]),
    ),
  );
}
