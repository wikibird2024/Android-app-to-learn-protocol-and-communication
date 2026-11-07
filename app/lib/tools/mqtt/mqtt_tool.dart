import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/bytes/hex.dart';
import '../../core/log/log_export.dart';
import '../../core/log/session_log.dart';
import '../../core/settings/tool_settings.dart';
import '../../core/transport/tcp_link.dart';
import '../../core/ui/form_parts.dart';
import '../../core/ui/tool_scaffold.dart';
import '../../protocols/mqtt/mqtt_client.dart';
import '../../protocols/mqtt/mqtt_packet.dart';

class MqttTool extends ConsumerStatefulWidget {
  const MqttTool({super.key});

  @override
  ConsumerState<MqttTool> createState() => _MqttToolState();
}

class _ReceivedMessage {
  _ReceivedMessage(this.time, this.publish);
  final DateTime time;
  final MqttPublish publish;
}

class _MqttToolState extends ConsumerState<MqttTool> {
  late final _settings = ref.read(toolSettingsProvider('mqtt'));
  late final _fields = SettingsControllers(_settings, {
    'host': 'test.mosquitto.org',
    'port': '1883',
    'tls': 'false',
    'clientId': 'protolab-${Random().nextInt(0xffff).toRadixString(16)}',
    'username': '',
    'password': '',
    'keepAlive': '30',
    'cleanSession': 'true',
    'willTopic': '',
    'willMessage': 'offline',
    'subscribeTopic': 'protolab/#',
    'subscribeQos': '0',
    'publishTopic': 'protolab/hello',
    'publishPayload': '{"from":"phone"}',
    'publishQos': '0',
    'publishRetain': 'false',
  });
  final _log = SessionLog();
  MqttClient? _client;
  StreamSubscription<MqttPublish>? _messageSubscription;
  final _messages = <_ReceivedMessage>[];
  final _subscriptions = <String, int>{};
  bool _isBusy = false;

  MqttClientState get _state => _client?.state.value ?? MqttClientState.disconnected;

  @override
  void dispose() {
    unawaited(_messageSubscription?.cancel());
    unawaited(_client?.disconnect().catchError((Object _) {}));
    _fields.dispose();
    _log.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _isBusy = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _connect(BuildContext tabContext) => _run(() async {
    if (_client != null) {
      await _client!.disconnect();
      _client = null;
      _subscriptions.clear();
      return;
    }
    final host = _fields.text('host');
    final port = _fields.number('port', min: 1, max: 65535, label: 'Port');
    final keepAlive = _fields.number('keepAlive', max: 65535, label: 'Keep alive');
    await _fields.remember();
    final link = await TcpLink.connect(host, port, useTls: _fields.text('tls') == 'true');
    final client = MqttClient(link: link, log: _log);
    client.state.addListener(() {
      if (mounted) setState(() {});
      if (client.state.value == MqttClientState.disconnected && identical(_client, client)) {
        _client = null;
        _subscriptions.clear();
      }
    });
    _messageSubscription = client.messages.listen((publish) {
      if (!mounted) return;
      setState(() {
        _messages.insert(0, _ReceivedMessage(DateTime.now(), publish));
        if (_messages.length > 500) _messages.removeLast();
      });
    });
    _client = client;
    final willTopic = _fields.text('willTopic');
    await client.connect(MqttConnect(
      clientId: _fields.text('clientId'),
      keepAliveSeconds: keepAlive,
      cleanSession: _fields.text('cleanSession') == 'true',
      username: _fields.text('username').isEmpty ? null : _fields.text('username'),
      password: _fields.text('password').isEmpty ? null : _fields.text('password'),
      will: willTopic.isEmpty
          ? null
          : MqttWill(topic: willTopic, message: Uint8List.fromList(utf8.encode(_fields.text('willMessage'))), qos: 1),
    ));
    if (tabContext.mounted) DefaultTabController.of(tabContext).animateTo(1);
  });

  Future<void> _subscribe() => _run(() async {
    final topic = _fields.text('subscribeTopic');
    final qos = _fields.number('subscribeQos', max: 2);
    await _fields.remember();
    final ack = await _client!.subscribe([MqttSubscription(topic, qos)]);
    final granted = ack.returnCodes.first;
    if (granted == 0x80) throw StateError('broker refused $topic');
    setState(() => _subscriptions[topic] = granted);
  });

  Future<void> _unsubscribe(String topic) => _run(() async {
    await _client!.unsubscribe([topic]);
    setState(() => _subscriptions.remove(topic));
  });

  Future<void> _publish() => _run(() async {
    await _fields.remember();
    await _client!.publish(
      _fields.text('publishTopic'),
      Uint8List.fromList(utf8.encode(_fields['publishPayload'].text)),
      qos: _fields.number('publishQos', max: 2),
      retain: _fields.text('publishRetain') == 'true',
    );
  });

  @override
  Widget build(BuildContext context) {
    final isConnected = _state == MqttClientState.connected;
    return ToolScaffold(
      toolId: 'mqtt',
      title: 'MQTT',
      log: _log,
      status: '${_state.name}${isConnected ? ' · ${_fields.text('host')}' : ''}',
      pcapLink: PcapTcp(int.tryParse(_fields.text('port')) ?? 1883),
      configure: Builder(
        builder: (tabContext) => FormColumn(
          children: [
            ProfileBar(controllers: _fields, onLoaded: () => setState(() {})),
            LabeledField(controller: _fields['host'], label: 'Broker host', hint: 'test.mosquitto.org, 192.168.1.10'),
            Row(children: [
              Expanded(child: LabeledField(controller: _fields['port'], label: 'Port', isNumber: true, helper: '1883 plain · 8883 TLS')),
              const SizedBox(width: 8),
              Expanded(child: SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('TLS'), value: _fields.text('tls') == 'true',
                  onChanged: (value) => setState(() => _fields['tls'].text = '$value'))),
            ]),
            LabeledField(controller: _fields['clientId'], label: 'Client id', helper: 'unique per broker: a second client with the same id kicks the first'),
            Row(children: [
              Expanded(child: LabeledField(controller: _fields['username'], label: 'User name')),
              const SizedBox(width: 8),
              Expanded(child: LabeledField(controller: _fields['password'], label: 'Password', isSecret: true)),
            ]),
            Row(children: [
              Expanded(child: LabeledField(controller: _fields['keepAlive'], label: 'Keep alive (s)', isNumber: true)),
              const SizedBox(width: 8),
              Expanded(child: SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Clean session'), value: _fields.text('cleanSession') == 'true',
                  onChanged: (value) => setState(() => _fields['cleanSession'].text = '$value'))),
            ]),
            LabeledField(controller: _fields['willTopic'], label: 'Will topic (optional)', helper: 'broker publishes the will message if we vanish without DISCONNECT'),
            LabeledField(controller: _fields['willMessage'], label: 'Will message'),
            FilledButton.icon(
              onPressed: _isBusy ? null : () => _connect(tabContext),
              icon: Icon(_client == null ? Icons.link : Icons.link_off),
              label: Text(_client == null ? 'Connect' : 'Disconnect'),
            ),
          ],
        ),
      ),
      talk: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text('Subscribe', style: Theme.of(context).textTheme.titleSmall),
          Row(children: [
            Expanded(flex: 3, child: LabeledField(controller: _fields['subscribeTopic'], label: 'Topic filter', helper: '+ = one level, # = everything below')),
            const SizedBox(width: 8),
            Expanded(child: _qosField('subscribeQos')),
            IconButton(onPressed: isConnected && !_isBusy ? _subscribe : null, icon: const Icon(Icons.add_circle)),
          ]),
          Wrap(spacing: 6, children: [
            for (final entry in _subscriptions.entries)
              InputChip(label: Text('${entry.key} · QoS ${entry.value}'), onDeleted: isConnected ? () => _unsubscribe(entry.key) : null),
          ]),
          const Divider(height: 24),
          Text('Publish', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          LabeledField(controller: _fields['publishTopic'], label: 'Topic'),
          const SizedBox(height: 8),
          LabeledField(controller: _fields['publishPayload'], label: 'Payload', maxLines: 3),
          Row(children: [
            Expanded(child: _qosField('publishQos')),
            Expanded(child: CheckboxListTile(title: const Text('Retain'), value: _fields.text('publishRetain') == 'true',
                onChanged: (value) => setState(() => _fields['publishRetain'].text = '${value ?? false}'))),
            FilledButton(onPressed: isConnected && !_isBusy ? _publish : null, child: const Text('Publish')),
          ]),
          const Divider(height: 24),
          Row(children: [
            Text('Messages (${_messages.length})', style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            TextButton(onPressed: () => setState(_messages.clear), child: const Text('Clear')),
          ]),
          for (final message in _messages)
            ListTile(
              dense: true,
              title: Text(message.publish.topic),
              subtitle: Text(textOrHex(message.publish.payload), style: monospace, maxLines: 4, overflow: TextOverflow.ellipsis),
              trailing: Text('QoS ${message.publish.qos}${message.publish.retain ? '\nretained' : ''}', textAlign: TextAlign.end),
            ),
        ],
      ),
    );
  }

  Widget _qosField(String key) => ChoiceField<String>(
    label: 'QoS',
    value: _fields.text(key),
    options: const {'0': '0', '1': '1', '2': '2'},
    onChanged: (value) => setState(() => _fields[key].text = value),
  );
}
