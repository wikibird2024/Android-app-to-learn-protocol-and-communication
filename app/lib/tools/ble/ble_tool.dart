import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:universal_ble/universal_ble.dart';

import '../../app/theme.dart';
import '../../core/bytes/hex.dart';
import '../../core/inspect/frame.dart';
import '../../core/log/session_log.dart';
import '../../core/settings/tool_settings.dart';
import '../../core/ui/form_parts.dart';
import '../../core/ui/frame_view.dart';
import '../../core/ui/log_view.dart';
import '../../core/ui/send_bar.dart';
import '../../core/ui/tool_scaffold.dart';
import '../../protocols/ble/ble_advert.dart';

/// BLE through the community package universal_ble (BSD-3). Chosen over
/// flutter_blue_plus, whose license needs a paid license for commercial use.
class BleTool extends ConsumerStatefulWidget {
  const BleTool({super.key});

  @override
  ConsumerState<BleTool> createState() => _BleToolState();
}

class _BleToolState extends ConsumerState<BleTool> {
  final _log = SessionLog();
  final _devices = <String, BleDevice>{};
  StreamSubscription<BleDevice>? _scanSubscription;
  bool _isScanning = false;
  bool _onlyNamed = true;
  String _nameFilter = '';

  @override
  void dispose() {
    unawaited(_stopScan());
    _log.dispose();
    super.dispose();
  }

  Future<void> _startScan(BuildContext tabContext) async {
    try {
      await UniversalBle.requestPermissions();
      final state = await UniversalBle.getBluetoothAvailabilityState();
      if (state != AvailabilityState.poweredOn) throw StateError('Bluetooth is ${state.name}');
      _devices.clear();
      _scanSubscription = UniversalBle.scanStream.listen((device) {
        if (mounted) setState(() => _devices[device.deviceId] = device);
      });
      await UniversalBle.startScan();
      _log.note('scan started');
      setState(() => _isScanning = true);
      if (tabContext.mounted) DefaultTabController.of(tabContext).animateTo(1);
    } on Object catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _stopScan() async {
    if (!_isScanning) return;
    await _scanSubscription?.cancel();
    await UniversalBle.stopScan().catchError((Object _) {});
    _isScanning = false;
    _log.note('scan stopped');
    if (mounted) setState(() {});
  }

  static Uint8List advertBytes(BleDevice device) => encodeAdvert(AdvertParts(
    name: device.name,
    serviceUuids: device.services,
    manufacturerData: {for (final data in device.manufacturerDataList) data.companyId: data.payload},
    serviceData: device.serviceData,
  ));

  @override
  Widget build(BuildContext context) {
    final devices = _devices.values
        .where((device) => !_onlyNamed || (device.name ?? '').isNotEmpty)
        .where((device) => _nameFilter.isEmpty || (device.name ?? '').toLowerCase().contains(_nameFilter.toLowerCase()))
        .toList()
      ..sort((left, right) => (right.rssi ?? -200).compareTo(left.rssi ?? -200));
    return ToolScaffold(
      toolId: 'ble',
      title: 'BLE scanner',
      log: _log,
      status: _isScanning ? 'scanning · ${_devices.length} seen' : 'idle',
      configure: Builder(
        builder: (tabContext) => FormColumn(
          children: [
            SwitchListTile(title: const Text('Only devices with a name'), value: _onlyNamed, onChanged: (value) => setState(() => _onlyNamed = value)),
            TextField(
              decoration: const InputDecoration(labelText: 'Name contains', border: OutlineInputBorder(), isDense: true),
              onChanged: (value) => setState(() => _nameFilter = value),
            ),
            FilledButton.icon(
              onPressed: _isScanning ? _stopScan : () => _startScan(tabContext),
              icon: Icon(_isScanning ? Icons.stop : Icons.bluetooth_searching),
              label: Text(_isScanning ? 'Stop scan' : 'Scan'),
            ),
            const Text('Scanning drains the battery; it stops when you leave this tool.'),
          ],
        ),
      ),
      talk: ListView(
        children: [
          for (final device in devices)
            ListTile(
              title: Text(device.name?.isNotEmpty == true ? device.name! : '(no name)'),
              subtitle: Text('${device.deviceId}\n${rssiText(device.rssi)}', style: monospace),
              isThreeLine: true,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Advert bytes',
                  icon: const Icon(Icons.data_object),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => Scaffold(appBar: AppBar(title: const Text('Advertising data')), body: FrameView(frame: decodeAdvert(advertBytes(device)))),
                  )),
                ),
                if (device.connectable != false)
                  IconButton(
                    tooltip: 'Connect',
                    icon: const Icon(Icons.link),
                    onPressed: () async {
                      await _stopScan();
                      if (!context.mounted) return;
                      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _GattScreen(device: device, log: _log)));
                    },
                  ),
              ]),
            ),
        ],
      ),
    );
  }
}

/// One connected device: services → characteristics → read/write/notify.
class _GattScreen extends ConsumerStatefulWidget {
  const _GattScreen({required this.device, required this.log});

  final BleDevice device;
  final SessionLog log;

  @override
  ConsumerState<_GattScreen> createState() => _GattScreenState();
}

class _GattScreenState extends ConsumerState<_GattScreen> {
  List<BleService> _services = const [];
  final _values = <String, Uint8List>{};
  final _notifySubscriptions = <String, StreamSubscription<Uint8List>>{};
  String _state = 'connecting...';
  int? _mtu;

  String get _deviceId => widget.device.deviceId;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    for (final subscription in _notifySubscriptions.values) {
      unawaited(subscription.cancel());
    }
    unawaited(UniversalBle.disconnect(_deviceId).catchError((Object _) {}));
    widget.log.note('disconnect ${widget.device.name ?? _deviceId}');
    super.dispose();
  }

  Future<void> _connect() async {
    try {
      widget.log.note('connect ${widget.device.name ?? _deviceId}');
      await UniversalBle.connect(_deviceId, timeout: const Duration(seconds: 15));
      // Bigger MTU = longer values per packet (default 23 bytes, 20 of data).
      _mtu = await UniversalBle.requestMtu(_deviceId, 247).catchError((Object _) => 23);
      final services = await UniversalBle.discoverServices(_deviceId);
      widget.log.note('connected, MTU $_mtu, ${services.length} services');
      if (mounted) {
        setState(() {
          _services = services;
          _state = 'connected · MTU $_mtu';
        });
      }
    } on Object catch (error) {
      widget.log.note('connect failed: $error');
      if (mounted) setState(() => _state = 'failed: $error');
    }
  }

  Frame _valueFrame(String what, String characteristic, Uint8List value) =>
      Frame.raw('GATT', value, summary: '$what ${shortUuid(characteristic)}: ${textOrHex(value)}');

  Future<void> _read(BleService service, BleCharacteristic characteristic) async {
    try {
      final value = await UniversalBle.read(_deviceId, service.uuid, characteristic.uuid);
      widget.log.received(_valueFrame('read', characteristic.uuid, value));
      setState(() => _values[characteristic.uuid] = value);
    } on Object catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _write(BleService service, BleCharacteristic characteristic) async {
    final settings = ref.read(toolSettingsProvider('ble'));
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + MediaQuery.of(sheetContext).viewInsets.bottom),
        child: SendBar(
          settings: settings,
          onSend: (bytes) async {
            final withoutResponse = !characteristic.properties.contains(CharacteristicProperty.write);
            await UniversalBle.write(_deviceId, service.uuid, characteristic.uuid, bytes, withoutResponse: withoutResponse);
            widget.log.sent(_valueFrame(withoutResponse ? 'write (no response)' : 'write', characteristic.uuid, bytes));
            if (sheetContext.mounted) Navigator.pop(sheetContext);
          },
        ),
      ),
    );
  }

  Future<void> _toggleNotify(BleService service, BleCharacteristic characteristic) async {
    final key = characteristic.uuid;
    try {
      if (_notifySubscriptions.containsKey(key)) {
        await _notifySubscriptions.remove(key)!.cancel();
        await UniversalBle.unsubscribe(_deviceId, service.uuid, key);
        widget.log.note('notify off ${shortUuid(key)}');
      } else {
        _notifySubscriptions[key] = UniversalBle.characteristicValueStream(_deviceId, key).listen((value) {
          widget.log.received(_valueFrame('notify', key, value));
          if (mounted) setState(() => _values[key] = value);
        });
        if (characteristic.properties.contains(CharacteristicProperty.notify)) {
          await UniversalBle.subscribeNotifications(_deviceId, service.uuid, key);
        } else {
          await UniversalBle.subscribeIndications(_deviceId, service.uuid, key);
        }
        // Subscribing writes 0x0001 (notify) or 0x0002 (indicate) to the CCCD descriptor 2902.
        widget.log.note('notify on ${shortUuid(key)} (CCCD 2902 written)');
      }
      setState(() {});
    } on Object catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.device.name ?? _deviceId),
          Text(_state, style: Theme.of(context).textTheme.bodySmall),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.list_alt),
            tooltip: 'Log',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => Scaffold(appBar: AppBar(title: const Text('BLE log')), body: LogView(log: widget.log, showTools: true)),
            )),
          ),
        ],
      ),
      body: ListView(
        children: [
          for (final service in _services)
            ExpansionTile(
              initiallyExpanded: true,
              title: Text('Service ${shortUuid(service.uuid)}'),
              subtitle: Text(_knownServices[shortUuid(service.uuid)] ?? service.uuid, style: monospace.copyWith(fontSize: 11)),
              children: [
                for (final characteristic in service.characteristics)
                  ListTile(
                    title: Text('${shortUuid(characteristic.uuid)} ${_knownCharacteristics[shortUuid(characteristic.uuid)] ?? ''}'),
                    subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(characteristic.properties.map((property) => property.name).join(' · '), style: Theme.of(context).textTheme.bodySmall),
                      if (_values[characteristic.uuid] != null) Text(textOrHex(_values[characteristic.uuid]!), style: monospace),
                    ]),
                    trailing: Wrap(children: [
                      if (characteristic.properties.contains(CharacteristicProperty.read))
                        IconButton(icon: const Icon(Icons.download), tooltip: 'Read', onPressed: () => _read(service, characteristic)),
                      if (characteristic.properties.contains(CharacteristicProperty.write) ||
                          characteristic.properties.contains(CharacteristicProperty.writeWithoutResponse))
                        IconButton(icon: const Icon(Icons.upload), tooltip: 'Write', onPressed: () => _write(service, characteristic)),
                      if (characteristic.properties.contains(CharacteristicProperty.notify) ||
                          characteristic.properties.contains(CharacteristicProperty.indicate))
                        IconButton(
                          icon: Icon(_notifySubscriptions.containsKey(characteristic.uuid) ? Icons.notifications_active : Icons.notifications_none),
                          tooltip: 'Notify',
                          onPressed: () => _toggleNotify(service, characteristic),
                        ),
                    ]),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  static const _knownServices = {
    '1800': 'Generic Access',
    '1801': 'Generic Attribute',
    '180a': 'Device Information',
    '180f': 'Battery',
    '180d': 'Heart Rate',
    '181a': 'Environmental Sensing',
    '6e400001-b5a3-f393-e0a9-e50e24dcca9e': 'Nordic UART (NUS)',
  };

  static const _knownCharacteristics = {
    '2a00': 'Device Name',
    '2a19': 'Battery Level',
    '2a29': 'Manufacturer',
    '2a24': 'Model Number',
    '2a26': 'Firmware Revision',
    '2a37': 'Heart Rate Measurement',
    '2a6e': 'Temperature',
  };
}
