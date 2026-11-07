import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/bytes/hex.dart';
import '../../core/log/log_export.dart';
import '../../core/log/session_log.dart';
import '../../core/settings/tool_settings.dart';
import '../../core/transport/udp_link.dart';
import '../../core/ui/form_parts.dart';
import '../../core/ui/tool_scaffold.dart';
import '../../protocols/coap/coap_client.dart';
import '../../protocols/coap/coap_codec.dart';

class CoapTool extends ConsumerStatefulWidget {
  const CoapTool({super.key});

  @override
  ConsumerState<CoapTool> createState() => _CoapToolState();
}

class _CoapToolState extends ConsumerState<CoapTool> {
  late final _settings = ref.read(toolSettingsProvider('coap'));
  late final _fields = SettingsControllers(_settings, {
    'host': 'coap.me',
    'port': '5683',
    'method': '1',
    'path': '/.well-known/core',
    'payload': '',
    'contentFormat': '',
    'confirmable': 'true',
    'observe': 'false',
  });
  final _log = SessionLog();
  CoapClient? _client;
  StreamSubscription<CoapMessage>? _observation;
  final _responses = <CoapMessage>[];
  bool _isBusy = false;

  @override
  void dispose() {
    unawaited(_observation?.cancel());
    unawaited(_client?.close());
    _fields.dispose();
    _log.dispose();
    super.dispose();
  }

  String? _clientKey;

  /// One UDP socket per host:port, reused so observe notifications and
  /// late responses still reach us.
  Future<CoapClient> _clientFor(String host, int port) async {
    final key = '$host:$port';
    if (_client != null && _clientKey != key) {
      await _client!.close();
      _client = null;
    }
    _clientKey = key;
    return _client ??= CoapClient(link: await UdpLink.open(host, port), log: _log);
  }

  Future<void> _send(BuildContext tabContext) async {
    setState(() => _isBusy = true);
    try {
      await _observation?.cancel();
      await _fields.remember();
      final host = _fields.text('host');
      final port = _fields.number('port', min: 1, max: 65535, label: 'Port');
      final client = await _clientFor(host, port);
      final payload = _fields['payload'].text;
      final contentFormat = _fields.text('contentFormat');
      final responses = client.request(
        method: _fields.number('method', min: 1, max: 4),
        path: _fields.text('path'),
        payload: payload.isEmpty ? null : Uint8List.fromList(utf8.encode(payload)),
        contentFormat: contentFormat.isEmpty ? null : int.tryParse(contentFormat),
        confirmable: _fields.text('confirmable') == 'true',
        observe: _fields.text('observe') == 'true',
      );
      if (tabContext.mounted) DefaultTabController.of(tabContext).animateTo(1);
      _observation = responses.listen(
        (message) {
          if (mounted) setState(() => _responses.insert(0, message));
        },
        onError: (Object error) {
          if (mounted) showError(context, error);
        },
      );
    } on Object catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ToolScaffold(
      toolId: 'coap',
      title: 'CoAP',
      log: _log,
      pcapLink: PcapUdp(int.tryParse(_fields.text('port')) ?? 5683),
      configure: Builder(
        builder: (tabContext) => FormColumn(
          children: [
            ProfileBar(controllers: _fields, onLoaded: () => setState(() {})),
            Row(children: [
              Expanded(flex: 3, child: LabeledField(controller: _fields['host'], label: 'Host', hint: 'coap.me (public test server)')),
              const SizedBox(width: 8),
              Expanded(child: LabeledField(controller: _fields['port'], label: 'Port', isNumber: true)),
            ]),
            Row(children: [
              SizedBox(
                width: 120,
                child: ChoiceField<String>(
                  label: 'Method',
                  value: _fields.text('method'),
                  options: {for (final entry in coapMethods.entries) '${entry.key}': entry.value},
                  onChanged: (value) => setState(() => _fields['method'].text = value),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: LabeledField(controller: _fields['path'], label: 'Path', hint: '/sensors/temp?unit=c')),
            ]),
            LabeledField(controller: _fields['payload'], label: 'Payload (POST / PUT)', maxLines: 3),
            ChoiceField<String>(
              label: 'Content-Format',
              value: _fields.text('contentFormat'),
              options: {'': '(none)', for (final entry in coapContentFormats.entries) '${entry.key}': '${entry.key} ${entry.value}'},
              onChanged: (value) => setState(() => _fields['contentFormat'].text = value),
            ),
            SwitchListTile(
              title: const Text('Confirmable (CON)'),
              subtitle: const Text('Off = NON: no ACK, no resend'),
              value: _fields.text('confirmable') == 'true',
              onChanged: (value) => setState(() => _fields['confirmable'].text = '$value'),
            ),
            SwitchListTile(
              title: const Text('Observe'),
              subtitle: const Text('Server pushes every change until you send again'),
              value: _fields.text('observe') == 'true',
              onChanged: (value) => setState(() => _fields['observe'].text = '$value'),
            ),
            FilledButton.icon(onPressed: _isBusy ? null : () => _send(tabContext), icon: const Icon(Icons.send), label: const Text('Send')),
          ],
        ),
      ),
      talk: _responses.isEmpty
          ? const Center(child: Text('Responses show up here.'))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final response in _responses)
                  Card(
                    child: ListTile(
                      title: Text('${coapCodeText(response.code)} · ${coapTypeShort[response.type.index]} #${response.messageId}'),
                      subtitle: SelectableText(textOrHex(response.payload), style: monospace),
                    ),
                  ),
              ],
            ),
    );
  }
}
