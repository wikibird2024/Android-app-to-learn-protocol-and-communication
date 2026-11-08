import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log/session_log.dart';
import '../../core/settings/tool_settings.dart';
import '../../core/transport/tcp_link.dart';
import '../../core/ui/form_parts.dart';
import '../../core/ui/log_view.dart';
import '../../core/ui/send_bar.dart';
import '../../core/ui/tool_scaffold.dart';
import '../../protocols/websocket/ws_client.dart';

/// WebSocket written by hand on a TCP (or TLS) link: the HTTP upgrade and
/// every frame (FIN, opcode, MASK, length, mask key) show in Inside.
class WebSocketTool extends ConsumerStatefulWidget {
  const WebSocketTool({super.key});

  @override
  ConsumerState<WebSocketTool> createState() => _WebSocketToolState();
}

class _WebSocketToolState extends ConsumerState<WebSocketTool> {
  late final _settings = ref.read(toolSettingsProvider('websocket'));
  late final _fields = SettingsControllers(_settings, {'url': 'wss://echo.websocket.org', 'protocol': ''});
  final _log = SessionLog();
  WsClient? _socket;
  bool _isBusy = false;

  @override
  void dispose() {
    unawaited(_socket?.close());
    _fields.dispose();
    _log.dispose();
    super.dispose();
  }

  Future<void> _toggle(BuildContext tabContext) async {
    if (_socket != null) {
      setState(() => _isBusy = true);
      await _socket!.close();
      if (mounted) setState(() => _isBusy = false);
      return;
    }
    setState(() => _isBusy = true);
    try {
      await _fields.remember();
      final url = Uri.parse(_fields.text('url'));
      if (url.scheme != 'ws' && url.scheme != 'wss') throw const FormatException('URL: starts with ws:// or wss://');
      final isTls = url.scheme == 'wss';
      final link = await TcpLink.connect(url.host, url.hasPort ? url.port : (isTls ? 443 : 80), useTls: isTls);
      _log.note('opened ${link.description}');
      final client = WsClient(link: link, log: _log);
      try {
        final protocol = await client.handshake(url, protocol: _fields.text('protocol'));
        if (protocol != null) _log.note('subprotocol $protocol');
      } on Object {
        await link.close();
        rethrow;
      }
      client.messages.listen(
        (_) {},
        onDone: () {
          _log.note('closed${client.closeCode == null ? '' : ': code ${client.closeCode}'}');
          if (mounted) setState(() => _socket = null);
        },
      );
      setState(() => _socket = client);
      if (tabContext.mounted) DefaultTabController.of(tabContext).animateTo(1);
    } on Object catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _send(Uint8List bytes) async {
    final socket = _socket;
    if (socket == null) return;
    final text = utf8.decode(bytes, allowMalformed: true);
    final isText = utf8.encode(text).length == bytes.length && !text.contains('\ufffd');
    await socket.send(bytes, isText: isText);
  }

  @override
  Widget build(BuildContext context) {
    return ToolScaffold(
      toolId: 'websocket',
      title: 'WebSocket',
      log: _log,
      status: _socket == null ? 'closed' : 'open',
      isConnected: _socket != null,
      onConnect: _toggle,
      isBusy: _isBusy,
      configure: Builder(
        builder: (tabContext) => FormColumn(
          children: [
            ProfileBar(controllers: _fields, onLoaded: () => setState(() {})),
            LabeledField(controller: _fields['url'], label: 'URL', hint: 'ws://192.168.1.50/ws'),
            LabeledField(controller: _fields['protocol'], label: 'Subprotocol (optional)', hint: 'mqtt, graphql-ws'),
            FilledButton.icon(
              onPressed: _isBusy ? null : () => _toggle(tabContext),
              icon: Icon(_socket == null ? Icons.link : Icons.link_off),
              label: Text(_socket == null ? 'Open' : 'Close'),
            ),
          ],
        ),
      ),
      talk: Column(children: [
        Expanded(child: LogView(log: _log)),
        Padding(padding: const EdgeInsets.all(8), child: SendBar(settings: _settings, isEnabled: _socket != null, onSend: _send)),
      ]),
    );
  }
}
