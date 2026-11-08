import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log/log_export.dart';
import '../../core/settings/tool_settings.dart';
import '../../core/transport/tcp_link.dart';
import '../../core/transport/udp_link.dart';
import '../../core/ui/form_parts.dart';
import '../../core/ui/log_view.dart';
import '../../core/ui/send_bar.dart';
import '../../core/ui/tool_scaffold.dart';
import '../link_session.dart';

/// Raw TCP or UDP: the layer every network protocol in this app sits on.
class SocketTool extends ConsumerStatefulWidget {
  const SocketTool({super.key, required this.isUdp});

  final bool isUdp;

  @override
  ConsumerState<SocketTool> createState() => _SocketToolState();
}

class _SocketToolState extends ConsumerState<SocketTool> {
  late final String _toolId = widget.isUdp ? 'udp' : 'tcp';
  late final _settings = ref.read(toolSettingsProvider(_toolId));
  late final _fields = SettingsControllers(_settings, {'host': '192.168.4.1', 'port': widget.isUdp ? '5683' : '3333', 'localPort': '0', 'tls': 'false'});
  late final _session = LinkSession(protocol: widget.isUdp ? 'UDP' : 'TCP');

  @override
  void dispose() {
    _session.dispose();
    _fields.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_session.isOpen) return _session.close();
    try {
      final host = _fields.text('host');
      final port = _fields.number('port', min: 1, max: 65535);
      await _fields.remember();
      await _session.open(() async => widget.isUdp
          ? await UdpLink.open(host, port, localPort: _fields.number('localPort', max: 65535))
          : await TcpLink.connect(host, port, useTls: _fields.text('tls') == 'true'));
    } on Object catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) => ToolScaffold(
        toolId: _toolId,
        title: widget.isUdp ? 'UDP socket' : 'TCP socket',
        log: _session.log,
        status: _session.isOpen ? _session.link!.description : 'not connected',
        isConnected: _session.isOpen,
        onConnect: _toggleFrom,
        isBusy: _session.isBusy,
        pcapLink: widget.isUdp
            ? PcapUdp(int.tryParse(_fields.text('port')) ?? 0)
            : PcapTcp(int.tryParse(_fields.text('port')) ?? 0),
        configure: Builder(
          builder: (context) => FormColumn(
            children: [
              ProfileBar(controllers: _fields),
              LabeledField(controller: _fields['host'], label: 'Host', hint: '192.168.1.50 or name.local'),
              LabeledField(controller: _fields['port'], label: 'Port', isNumber: true),
              if (widget.isUdp)
                LabeledField(controller: _fields['localPort'], label: 'Local port', isNumber: true, helper: '0 = any free port'),
              if (!widget.isUdp)
                SwitchListTile(
                  title: const Text('TLS'),
                  subtitle: const Text('Encrypted (port 8883 MQTT, 443 HTTPS)'),
                  value: _fields.text('tls') == 'true',
                  onChanged: (value) => setState(() => _fields['tls'].text = '$value'),
                ),
              FilledButton.icon(
                onPressed: _session.isBusy ? null : () => _toggleFrom(context),
                icon: Icon(_session.isOpen ? Icons.link_off : Icons.link),
                label: Text(_session.isOpen ? 'Close' : (widget.isUdp ? 'Open' : 'Connect')),
              ),
            ],
          ),
        ),
        talk: Column(
          children: [
            Expanded(child: LogView(log: _session.log)),
            Padding(
              padding: const EdgeInsets.all(8),
              child: SendBar(settings: _settings, isEnabled: _session.isOpen, onSend: _session.send),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleFrom(BuildContext tabContext) async {
    await _toggle();
    if (_session.isOpen && tabContext.mounted) DefaultTabController.of(tabContext).animateTo(1);
  }
}
