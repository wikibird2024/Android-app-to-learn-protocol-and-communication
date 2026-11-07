import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/log/log_export.dart';
import '../../core/settings/tool_settings.dart';
import '../../core/transport/serial_link.dart';
import '../../core/transport/tcp_link.dart';
import '../../core/ui/form_parts.dart';
import '../../core/ui/log_view.dart';
import '../../core/ui/tool_scaffold.dart';
import '../serial/serial_tool.dart';
import 'bridge_connection.dart';

class BridgeTool extends ConsumerStatefulWidget {
  const BridgeTool({super.key});

  @override
  ConsumerState<BridgeTool> createState() => _BridgeToolState();
}

class _BridgeToolState extends ConsumerState<BridgeTool> {
  late final _settings = ref.read(toolSettingsProvider('bridge'));
  late final _fields = SettingsControllers(_settings, {...SerialSettingsForm.defaults, 'via': 'wifi', 'host': '192.168.4.1', 'port': '3333'});
  final _command = TextEditingController();
  SerialDevice? _device;
  bool _isBusy = false;
  String _result = '';

  BridgeConnection get _bridge => ref.read(bridgeConnectionProvider);

  @override
  void dispose() {
    _fields.dispose();
    _command.dispose();
    super.dispose();
  }

  Future<void> _toggle(BuildContext tabContext) async {
    setState(() => _isBusy = true);
    try {
      if (_bridge.isConnected) {
        await _bridge.disconnect();
        return;
      }
      await _fields.remember();
      final link = _fields.text('via') == 'wifi'
          ? await TcpLink.connect(_fields.text('host'), _fields.number('port', min: 1, max: 65535, label: 'Port'))
          : await SerialPorts.open(_device ?? (throw const FormatException('Pick a serial port')), SerialSettingsForm.read(_fields));
      await _bridge.connect(link);
      if (tabContext.mounted) DefaultTabController.of(tabContext).animateTo(1);
    } on Object catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _run() async {
    final text = _command.text.trim();
    if (text.isEmpty) return;
    try {
      final data = await _bridge.command(text, timeout: const Duration(seconds: 10));
      setState(() => _result = const JsonEncoder.withIndent('  ').convert(data));
    } on Object catch (error) {
      setState(() => _result = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bridge = ref.watch(bridgeConnectionProvider);
    return ListenableBuilder(
      listenable: bridge,
      builder: (context, _) => ToolScaffold(
        toolId: 'bridge',
        title: 'ESP32 bridge',
        log: bridge.log,
        status: bridge.description,
        pcapLink: const PcapUser(),
        configure: Builder(
          builder: (tabContext) => FormColumn(
            children: [
              SegmentedButton<String>(
                segments: const [ButtonSegment(value: 'wifi', label: Text('Wi-Fi (TCP)')), ButtonSegment(value: 'serial', label: Text('USB / BT serial'))],
                selected: {_fields.text('via')},
                onSelectionChanged: bridge.isConnected ? null : (selection) => setState(() => _fields['via'].text = selection.first),
              ),
              if (_fields.text('via') == 'wifi') ...[
                LabeledField(controller: _fields['host'], label: 'Bridge address', helper: 'First start: join Wi-Fi "protolab-bridge", address 192.168.4.1'),
                LabeledField(controller: _fields['port'], label: 'Port', isNumber: true),
              ] else ...[
                SerialDevicePicker(selected: _device, onChanged: (device) => setState(() => _device = device)),
                SerialSettingsForm(fields: _fields),
              ],
              FilledButton.icon(
                onPressed: _isBusy ? null : () => _toggle(tabContext),
                icon: Icon(bridge.isConnected ? Icons.link_off : Icons.link),
                label: Text(bridge.isConnected ? 'Disconnect' : 'Connect'),
              ),
              if (bridge.info.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(bridge.info.entries.map((entry) => '${entry.key}: ${entry.value}').join('\n'), style: monospace),
                  ),
                ),
            ],
          ),
        ),
        talk: Column(children: [
          Expanded(child: LogView(log: bridge.log)),
          if (_result.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 160),
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: SingleChildScrollView(child: SelectableText(_result, style: monospace)),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _command,
                  decoration: const InputDecoration(hintText: 'help · ping · i2c scan', border: OutlineInputBorder(), isDense: true),
                  onSubmitted: bridge.isConnected ? (_) => _run() : null,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: bridge.isConnected ? _run : null, child: const Text('Run')),
            ]),
          ),
        ]),
      ),
    );
  }
}
