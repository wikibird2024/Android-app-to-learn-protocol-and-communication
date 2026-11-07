import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:multicast_dns/multicast_dns.dart';

import '../../core/log/session_log.dart';
import '../../core/settings/tool_settings.dart';
import '../../core/ui/form_parts.dart';
import '../../core/ui/tool_scaffold.dart';

class _FoundService {
  _FoundService(this.instance, this.target, this.port);
  final String instance;
  final String target;
  final int port;
  final addresses = <String>{};
  final text = <String>[];
}

/// DNS-SD over mDNS (RFC 6762/6763): ask "who offers _service._tcp?" on
/// 224.0.0.251:5353 and every device answers for itself.
///   PTR _http._tcp.local → "Kitchen._http._tcp.local"
///   SRV Kitchen... → esp32.local:80      A esp32.local → 192.168.1.42
///   TXT Kitchen... → path=/api, version=2
class MdnsTool extends ConsumerStatefulWidget {
  const MdnsTool({super.key});

  @override
  ConsumerState<MdnsTool> createState() => _MdnsToolState();
}

class _MdnsToolState extends ConsumerState<MdnsTool> {
  static const _system = MethodChannel('protocol_lab/system');
  static const presets = ['_protolab._tcp', '_http._tcp', '_mqtt._tcp', '_coap._udp', '_esphomelib._tcp', '_arduino._tcp', '_googlecast._tcp', '_ipp._tcp'];

  late final _settings = ref.read(toolSettingsProvider('mdns'));
  late final _fields = SettingsControllers(_settings, {'service': '_http._tcp'});
  final _log = SessionLog();
  final _found = <String, _FoundService>{};
  bool _isSearching = false;

  @override
  void dispose() {
    _fields.dispose();
    _log.dispose();
    super.dispose();
  }

  Future<void> _search(BuildContext tabContext) async {
    final service = '${_fields.text('service')}.local';
    await _fields.remember();
    setState(() {
      _isSearching = true;
      _found.clear();
    });
    if (tabContext.mounted) DefaultTabController.of(tabContext).animateTo(1);
    final client = MDnsClient();
    try {
      await _system.invokeMethod<void>('multicastLock', {'hold': true}).catchError((Object _) {});
      await client.start();
      _log.note('query PTR $service');
      const window = Duration(seconds: 4);
      await for (final ptr in client.lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(service), timeout: window)) {
        _log.note('PTR → ${ptr.domainName}');
        await for (final srv in client.lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName), timeout: window)) {
          _log.note('SRV ${ptr.domainName} → ${srv.target}:${srv.port}');
          final found = _found.putIfAbsent(ptr.domainName, () => _FoundService(ptr.domainName, srv.target, srv.port));
          await for (final txt in client.lookup<TxtResourceRecord>(ResourceRecordQuery.text(ptr.domainName), timeout: window)) {
            found.text.add(txt.text);
          }
          await for (final address in client.lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target), timeout: window)) {
            _log.note('A ${srv.target} → ${address.address.address}');
            found.addresses.add(address.address.address);
          }
          if (mounted) setState(() {});
        }
      }
      _log.note('done: ${_found.length} found');
    } on Object catch (error) {
      if (mounted) showError(context, error);
    } finally {
      client.stop();
      await _system.invokeMethod<void>('multicastLock', {'hold': false}).catchError((Object _) {});
      if (mounted) setState(() => _isSearching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ToolScaffold(
      toolId: 'mdns',
      title: 'mDNS finder',
      log: _log,
      status: _isSearching ? 'searching...' : '${_found.length} found',
      configure: Builder(
        builder: (tabContext) => FormColumn(
          children: [
            LabeledField(controller: _fields['service'], label: 'Service type', helper: '_name._tcp or _name._udp'),
            Wrap(spacing: 6, children: [
              for (final preset in presets)
                ActionChip(label: Text(preset), onPressed: () => setState(() => _fields['service'].text = preset)),
            ]),
            FilledButton.icon(
              onPressed: _isSearching ? null : () => _search(tabContext),
              icon: const Icon(Icons.travel_explore),
              label: const Text('Search'),
            ),
          ],
        ),
      ),
      talk: ListView(
        children: [
          if (_isSearching) const LinearProgressIndicator(),
          for (final service in _found.values)
            ListTile(
              title: Text(service.instance.split('.').first),
              subtitle: Text([
                '${service.target}:${service.port}',
                if (service.addresses.isNotEmpty) service.addresses.join(', '),
                if (service.text.isNotEmpty) service.text.join(' · '),
              ].join('\n')),
              isThreeLine: true,
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                tooltip: 'Copy host:port',
                onPressed: () => Clipboard.setData(ClipboardData(text: '${service.addresses.isEmpty ? service.target : service.addresses.first}:${service.port}')),
              ),
            ),
        ],
      ),
    );
  }
}
