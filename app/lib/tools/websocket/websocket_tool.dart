import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/inspect/frame.dart';
import '../../core/log/session_log.dart';
import '../../core/settings/tool_settings.dart';
import '../../core/ui/form_parts.dart';
import '../../core/ui/log_view.dart';
import '../../core/ui/send_bar.dart';
import '../../core/ui/tool_scaffold.dart';

/// WebSocket via dart:io. The handshake and frame format are in the Learn
/// tab; dart:io hides the frame bytes, so the log shows messages.
class WebSocketTool extends ConsumerStatefulWidget {
  const WebSocketTool({super.key});

  @override
  ConsumerState<WebSocketTool> createState() => _WebSocketToolState();
}

class _WebSocketToolState extends ConsumerState<WebSocketTool> {
  late final _settings = ref.read(toolSettingsProvider('websocket'));
  late final _fields = SettingsControllers(_settings, {'url': 'wss://echo.websocket.org', 'protocol': ''});
  final _log = SessionLog();
  WebSocket? _socket;
  bool _isBusy = false;

  @override
  void dispose() {
    unawaited(_socket?.close());
    _fields.dispose();
    _log.dispose();
    super.dispose();
  }

  Frame _messageFrame(Object message) => message is String
      ? Frame.raw('WebSocket text', Uint8List.fromList(utf8.encode(message)), summary: message)
      : Frame.raw('WebSocket binary', Uint8List.fromList(message as List<int>));

  Future<void> _toggle(BuildContext tabContext) async {
    if (_socket != null) {
      await _socket!.close(WebSocketStatus.normalClosure);
      return;
    }
    setState(() => _isBusy = true);
    try {
      await _fields.remember();
      final protocol = _fields.text('protocol');
      final socket = await WebSocket.connect(_fields.text('url'), protocols: protocol.isEmpty ? null : [protocol])
          .timeout(const Duration(seconds: 10));
      socket.pingInterval = const Duration(seconds: 20);
      _log.note('open ${_fields.text('url')}${socket.protocol == null ? '' : ' subprotocol ${socket.protocol}'}');
      socket.listen(
        (message) => _log.received(_messageFrame(message as Object)),
        onDone: () {
          _log.note('closed: code ${socket.closeCode} ${socket.closeReason ?? ''}');
          if (mounted) setState(() => _socket = null);
        },
        onError: (Object error) => _log.note('error: $error'),
      );
      setState(() => _socket = socket);
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
    final isText = utf8.encode(text).length == bytes.length && !text.contains('�');
    socket.add(isText ? text : bytes);
    _log.sent(_messageFrame(isText ? text : bytes));
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
