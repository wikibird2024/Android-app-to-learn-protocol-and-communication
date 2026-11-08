import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/bytes/hex.dart';
import '../../core/ui/form_parts.dart';
import '../../protocols/radio/radio_frames.dart';
import 'bus_tools.dart';

// ---- Wi-Fi setup -----------------------------------------------------------

class WifiTool extends ConsumerStatefulWidget {
  const WifiTool({super.key});

  @override
  ConsumerState<WifiTool> createState() => _WifiToolState();
}

class _WifiToolState extends ConsumerState<WifiTool> with BridgeToolState<WifiTool> {
  @override
  String get toolId => 'wifi';

  @override
  Map<String, String> get defaults => {'ssid': '', 'password': ''};

  Map<String, Object?> _status = const {};
  List<Map<String, Object?>> _networks = const [];

  Future<void> _refresh() async {
    final reply = await run('wifi status');
    if (reply is Map<String, Object?>) setState(() => _status = reply);
  }

  Future<void> _scan() async {
    final reply = await run('wifi scan', timeout: const Duration(seconds: 10));
    if (reply is List) setState(() => _networks = [for (final item in reply) (item as Map).cast<String, Object?>()]);
  }

  Future<void> _join() async {
    final ssid = fields.text('ssid');
    final password = fields['password'].text;
    if (ssid.isEmpty || ssid.contains(' ') || password.contains(' ')) {
      return showError(context, 'SSID and password without spaces (the bridge splits words on spaces)');
    }
    final reply = await run('wifi set $ssid ${password.isEmpty ? '-' : password}', timeout: const Duration(seconds: 20));
    if (!identical(reply, bridgeFailed)) {
      log.note('saved; the bridge joins $ssid and keeps it after a reboot');
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) => scaffold(
    title: 'Wi-Fi setup',
    configure: FormColumn(children: [
      LabeledField(controller: fields['ssid'], label: 'Network (SSID)'),
      LabeledField(controller: fields['password'], label: 'Password', isSecret: true, helper: 'empty for an open network'),
      FilledButton(onPressed: isBusy ? null : _join, child: const Text('Join')),
      const Text('Sent in clear text over the bridge link; fine on the bench, not for a shared network.'),
    ]),
    talk: ListView(padding: const EdgeInsets.all(12), children: [
      Row(children: [
        FilledButton(onPressed: isBusy ? null : _refresh, child: const Text('Status')),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: isBusy ? null : _scan, child: const Text('Scan networks')),
      ]),
      if (_status.isNotEmpty) Padding(padding: const EdgeInsets.all(8), child: Text(_status.entries.map((entry) => '${entry.key}: ${entry.value}').join('\n'), style: monospace)),
      for (final network in _networks)
        ListTile(
          dense: true,
          title: Text('${network['ssid']}'),
          subtitle: Text('${network['rssi']} dBm · channel ${network['channel']} · ${network['auth']}'),
          onTap: () => setState(() => fields['ssid'].text = '${network['ssid']}'),
        ),
    ]),
  );
}

// ---- ESP-NOW -------------------------------------------------------------

class EspNowTool extends ConsumerStatefulWidget {
  const EspNowTool({super.key});

  @override
  ConsumerState<EspNowTool> createState() => _EspNowToolState();
}

class _EspNowToolState extends ConsumerState<EspNowTool> with BridgeToolState<EspNowTool> {
  @override
  String get toolId => 'espnow';

  @override
  Map<String, String> get defaults => {'peer': 'ff:ff:ff:ff:ff:ff', 'data': 'hello'};

  StreamSubscription<Map<String, Object?>>? _events;

  @override
  void initState() {
    super.initState();
    _events = bridge.events.where((event) => event['event'] == 'espnow').listen((event) {
      final data = parseHex('${event['data'] ?? ''}');
      log.received(describeEspNow(data, peer: '${event['mac']}', isSent: false, detail: ' (${event['rssi']} dBm)'));
    });
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  Future<void> _send() async {
    final peer = fields.text('peer').toLowerCase();
    if (!RegExp(r'^([0-9a-f]{2}:){5}[0-9a-f]{2}$').hasMatch(peer)) return showError(context, 'Peer MAC like 24:6f:28:aa:bb:cc');
    final data = utf8.encode(fields['data'].text);
    if (data.isEmpty || data.length > 250) return showError(context, 'ESP-NOW carries 1..250 bytes');
    final reply = await run('espnow send $peer ${toHex(data, separator: '')}');
    if (!identical(reply, bridgeFailed)) log.sent(describeEspNow(data, peer: peer, isSent: true));
  }

  @override
  Widget build(BuildContext context) => scaffold(
    title: 'ESP-NOW',
    feature: 'espnow',
    configure: FormColumn(children: [
      initButton('Start ESP-NOW', () => 'espnow init'),
      Text('This bridge: ${bridge.info['mac'] ?? '?'}'),
      const Text('ESP-NOW sends Wi-Fi action frames straight between ESP32s: no router, no IP, 250 bytes max. '
          'Both sides must be on the same Wi-Fi channel.'),
    ]),
    talk: Column(children: [
      Expanded(child: ListView(children: const [ListTile(title: Text('Received frames are in the Inside tab.'))])),
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          Expanded(flex: 2, child: LabeledField(controller: fields['peer'], label: 'Peer MAC (ff:..:ff = all)')),
          const SizedBox(width: 8),
          Expanded(flex: 2, child: LabeledField(controller: fields['data'], label: 'Text')),
          IconButton.filled(onPressed: isBusy ? null : _send, icon: const Icon(Icons.send)),
        ]),
      ),
    ]),
  );
}

// ---- Zigbee --------------------------------------------------------------

class ZigbeeTool extends ConsumerStatefulWidget {
  const ZigbeeTool({super.key});

  @override
  ConsumerState<ZigbeeTool> createState() => _ZigbeeToolState();
}

class _ZigbeeToolState extends ConsumerState<ZigbeeTool> with BridgeToolState<ZigbeeTool> {
  @override
  String get toolId => 'zigbee';

  @override
  Map<String, String> get defaults => {'permitSeconds': '60', 'endpoint': '1'};

  List<Map<String, Object?>> _devices = const [];
  StreamSubscription<Map<String, Object?>>? _events;

  @override
  void initState() {
    super.initState();
    _events = bridge.events.where((event) => event['event'] == 'zigbee').listen((event) {
      log.received(describeZigbeeEvent(event));
      if (event['type'] == 'joined') unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  Future<void> _refresh() async {
    final reply = await run('zb devices');
    if (reply is List) setState(() => _devices = [for (final item in reply) (item as Map).cast<String, Object?>()]);
  }

  Future<void> _onOff(String shortAddress, String action) async {
    final endpoint = fields.number('endpoint', min: 1, max: 240, label: 'Endpoint');
    final reply = await run('zb onoff $shortAddress $endpoint $action');
    if (!identical(reply, bridgeFailed)) {
      log.sent(describeZclOnOff(shortAddress: shortAddress, endpoint: endpoint, action: action));
    }
  }

  @override
  Widget build(BuildContext context) => scaffold(
    title: 'Zigbee',
    feature: 'zigbee',
    configure: FormColumn(children: [
      initButton('Form network (coordinator)', () => 'zb form'),
      LabeledField(controller: fields['permitSeconds'], label: 'Permit join (s)', isNumber: true),
      initButton('Open for joining', () => 'zb permit ${fields.number('permitSeconds', max: 254)}'),
      const Text('Reset the bulb or sensor (often: power on/off 5 times) while joining is open.'),
    ]),
    talk: ListView(padding: const EdgeInsets.all(12), children: [
      Row(children: [
        FilledButton(onPressed: isBusy ? null : _refresh, child: const Text('Devices')),
        const SizedBox(width: 8),
        SizedBox(width: 110, child: LabeledField(controller: fields['endpoint'], label: 'Endpoint', isNumber: true)),
      ]),
      for (final device in _devices)
        ListTile(
          title: Text('${device['short']} · ${device['ieee']}', style: monospace),
          trailing: Wrap(children: [
            for (final action in const ['on', 'off', 'toggle'])
              TextButton(onPressed: isBusy ? null : () => _onOff('${device['short']}', action), child: Text(action)),
          ]),
        ),
    ]),
  );
}

// ---- Thread --------------------------------------------------------------

class ThreadTool extends ConsumerStatefulWidget {
  const ThreadTool({super.key});

  @override
  ConsumerState<ThreadTool> createState() => _ThreadToolState();
}

class _ThreadToolState extends ConsumerState<ThreadTool> with BridgeToolState<ThreadTool> {
  @override
  String get toolId => 'thread';

  @override
  Map<String, String> get defaults => {'command': 'state'};

  String _output = '';

  Future<void> _run() async {
    final reply = await run('ot ${fields.text('command')}', timeout: const Duration(seconds: 10));
    if (reply is Map) setState(() => _output = '${reply['output'] ?? ''}');
  }

  @override
  Widget build(BuildContext context) => scaffold(
    title: 'Thread',
    feature: 'thread',
    configure: FormColumn(children: [
      const Text('Runs OpenThread CLI commands on the bridge (the community CLI, unchanged). '
          'Start a network: dataset init new → dataset commit active → ifconfig up → thread start.'),
      Wrap(spacing: 6, children: [
        for (final preset in const ['state', 'dataset init new', 'dataset commit active', 'ifconfig up', 'thread start', 'ipaddr', 'neighbor table', 'dataset active'])
          ActionChip(label: Text(preset), onPressed: () => setState(() => fields['command'].text = preset)),
      ]),
    ]),
    talk: ListView(padding: const EdgeInsets.all(12), children: [
      Row(children: [
        Expanded(child: LabeledField(controller: fields['command'], label: 'ot command')),
        IconButton.filled(onPressed: isBusy ? null : _run, icon: const Icon(Icons.play_arrow)),
      ]),
      SelectableText(_output, style: monospace),
    ]),
  );
}
