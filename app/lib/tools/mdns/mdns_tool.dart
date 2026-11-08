import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log/session_log.dart';
import '../../core/settings/tool_settings.dart';
import '../../core/transport/mdns_socket.dart';
import '../../core/ui/form_parts.dart';
import '../../core/ui/tool_scaffold.dart';
import '../../protocols/dns/dns_codec.dart';

class _FoundService {
  _FoundService(this.instance);
  final String instance;
  String target = '';
  int port = 0;
  final addresses = <String>{};
  final text = <String>[];
}

/// DNS-SD over mDNS (RFC 6762/6763): ask "who offers _service._tcp?" on
/// 224.0.0.251:5353 and every device answers for itself. The DNS packets
/// are built and read by hand (protocols/dns), so Inside shows them.
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
    MdnsSocket? socket;
    StreamSubscription<Object?>? subscription;
    final records = <DnsRecord>[];
    try {
      await _system.invokeMethod<void>('multicastLock', {'hold': true}).catchError((Object _) {});
      final opened = socket = await MdnsSocket.open();
      _log.note('joined 224.0.0.251:5353 (multicast lock held)');
      bool isOurs(DnsRecord record) =>
          record.name == service || _found.containsKey(record.name) || _found.values.any((found) => found.target == record.name);
      subscription = opened.datagrams.listen((datagram) {
        final decoded = decodeDns(datagram.bytes);
        final message = decoded.message;
        // Everyone's queries and unrelated answers pass by on the group:
        // keep only answers about this search.
        if (message == null || !message.isResponse || !message.records.any(isOurs)) return;
        _log.received(decoded.frame.copyWith(summary: 'from ${datagram.from.address}: ${decoded.frame.summary}'));
        records.addAll(message.records);
        _collect(records, service);
        if (mounted) setState(() {});
      });
      void ask(List<DnsQuestion> questions) {
        final bytes = encodeDnsQuery(questions);
        _log.sent(decodeDns(bytes).frame);
        opened.send(bytes);
      }

      ask([DnsQuestion(service, dnsTypeCode('PTR'))]);
      await Future<void>.delayed(const Duration(seconds: 1));
      ask([DnsQuestion(service, dnsTypeCode('PTR'))]); // multicast has no retransmit: ask twice
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      // Responders usually add SRV/TXT/A as "additional" records; ask only
      // for what is still missing.
      for (final found in _found.values.toList()) {
        if (found.port == 0) ask([DnsQuestion(found.instance, dnsTypeCode('SRV')), DnsQuestion(found.instance, dnsTypeCode('TXT'))]);
        if (found.target.isNotEmpty && found.addresses.isEmpty) ask([DnsQuestion(found.target, dnsTypeCode('A'))]);
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      _log.note('done: ${_found.length} found');
    } on Object catch (error) {
      if (mounted) showError(context, error);
    } finally {
      await subscription?.cancel();
      socket?.close();
      await _system.invokeMethod<void>('multicastLock', {'hold': false}).catchError((Object _) {});
      if (mounted) setState(() => _isSearching = false);
    }
  }

  /// PTR → instance; SRV → host:port; TXT → key=value; A → address.
  void _collect(List<DnsRecord> records, String service) {
    for (final record in records.where((record) => record.type == dnsTypeCode('PTR') && record.name == service && record.target != null)) {
      _found.putIfAbsent(record.target!, () => _FoundService(record.target!));
    }
    for (final found in _found.values) {
      for (final record in records.where((record) => record.name == found.instance)) {
        if (record.type == dnsTypeCode('SRV')) {
          found.target = record.target ?? '';
          found.port = record.port ?? 0;
        }
        if (record.type == dnsTypeCode('TXT')) found.text.addAll(record.texts.where((text) => !found.text.contains(text)));
      }
      for (final record in records.where((record) => record.type == dnsTypeCode('A') && record.name == found.target && record.address != null)) {
        found.addresses.add(record.address!);
      }
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
