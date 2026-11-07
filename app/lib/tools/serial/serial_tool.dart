import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:universal_ble/universal_ble.dart';

import '../../core/log/log_export.dart';
import '../../core/settings/tool_settings.dart';
import '../../core/transport/serial_link.dart';
import '../../core/ui/form_parts.dart';
import '../../core/ui/log_view.dart';
import '../../core/ui/send_bar.dart';
import '../../core/ui/tool_scaffold.dart';
import '../link_session.dart';

/// Lists the serial ports the phone can open right now: USB-UART adapters
/// on the OTG port and paired Bluetooth SPP devices. Asks for the Bluetooth
/// permissions first (universal_ble's request includes BLUETOOTH_CONNECT),
/// so paired devices can be listed; USB still works if the user says no.
Future<List<SerialDevice>> listSerialDevices() async {
  try {
    await UniversalBle.requestPermissions();
  } on Object {
    // Denied: only USB ports will be listed.
  }
  return SerialPorts.list();
}

/// Picks a serial device; shared by the serial terminal, Modbus RTU and the
/// bridge connection.
class SerialDevicePicker extends StatefulWidget {
  const SerialDevicePicker({super.key, required this.selected, required this.onChanged});

  final SerialDevice? selected;
  final ValueChanged<SerialDevice?> onChanged;

  @override
  State<SerialDevicePicker> createState() => _SerialDevicePickerState();
}

class _SerialDevicePickerState extends State<SerialDevicePicker> {
  List<SerialDevice> _devices = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final devices = await listSerialDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _error = null;
      });
      if (widget.selected == null && devices.isNotEmpty) widget.onChanged(devices.first);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedId = widget.selected?.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Port', style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            TextButton.icon(onPressed: _refresh, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
          ],
        ),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (_devices.isEmpty)
          const Text('No port found. Plug a USB-UART adapter (OTG) or pair a Bluetooth SPP device in Android settings.'),
        RadioGroup<String>(
          groupValue: selectedId,
          onChanged: (id) => widget.onChanged(_devices.where((device) => device.id == id).firstOrNull),
          child: Column(
            children: [
              for (final device in _devices)
                RadioListTile<String>(
                  value: device.id,
                  title: Text(device.name),
                  subtitle: Text('${device.kind == SerialKind.usb ? 'USB' : 'Bluetooth'} · ${device.detail.isEmpty ? device.id : device.detail}'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Baud rate, data bits, parity, stop bits: "115200 8N1".
class SerialSettingsForm extends StatelessWidget {
  const SerialSettingsForm({super.key, required this.fields});

  final SettingsControllers fields;

  static const defaults = {'baud': '115200', 'dataBits': '8', 'parity': 'none', 'stopBits': '1'};

  static SerialSettings read(SettingsControllers fields) => SerialSettings(
    baudRate: fields.number('baud', min: 300, max: 4000000, label: 'Baud rate'),
    dataBits: fields.number('dataBits', min: 5, max: 8, label: 'Data bits'),
    stopBits: fields.number('stopBits', min: 1, max: 2, label: 'Stop bits'),
    parity: Parity.values.asNameMap()[fields.text('parity')] ?? Parity.none,
  );

  @override
  Widget build(BuildContext context) {
    return StatefulBuilder(
      builder: (context, setState) => Column(
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: LabeledField(controller: fields['baud'], label: 'Baud rate', isNumber: true, helper: '9600 · 115200 · 921600'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ChoiceField<String>(
                  label: 'Data bits',
                  value: fields.text('dataBits'),
                  options: const {'5': '5', '6': '6', '7': '7', '8': '8'},
                  onChanged: (value) => setState(() => fields['dataBits'].text = value),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ChoiceField<String>(
                  label: 'Parity',
                  value: fields.text('parity'),
                  options: {for (final parity in Parity.values) parity.name: parity.name},
                  onChanged: (value) => setState(() => fields['parity'].text = value),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ChoiceField<String>(
                  label: 'Stop bits',
                  value: fields.text('stopBits'),
                  options: const {'1': '1', '2': '2'},
                  onChanged: (value) => setState(() => fields['stopBits'].text = value),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class SerialTool extends ConsumerStatefulWidget {
  const SerialTool({super.key});

  @override
  ConsumerState<SerialTool> createState() => _SerialToolState();
}

class _SerialToolState extends ConsumerState<SerialTool> {
  late final _settings = ref.read(toolSettingsProvider('serial'));
  late final _fields = SettingsControllers(_settings, SerialSettingsForm.defaults);
  final _session = LinkSession(protocol: 'UART');
  SerialDevice? _device;
  bool _dtr = false;
  bool _rts = false;

  @override
  void dispose() {
    _session.dispose();
    _fields.dispose();
    super.dispose();
  }

  Future<void> _toggle(BuildContext tabContext) async {
    if (_session.isOpen) return _session.close();
    final device = _device;
    if (device == null) return showError(context, 'Pick a port first');
    try {
      final settings = SerialSettingsForm.read(_fields);
      await _fields.remember();
      await _session.open(() => SerialPorts.open(device, settings));
      if (tabContext.mounted) DefaultTabController.of(tabContext).animateTo(1);
    } on Object catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _setLines() async {
    final link = _session.link;
    if (link is SerialLink) {
      await link.setControlLines(dtr: _dtr, rts: _rts);
      _session.log.note('DTR ${_dtr ? 'on' : 'off'}, RTS ${_rts ? 'on' : 'off'}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) => ToolScaffold(
        toolId: 'serial',
        title: 'Serial terminal',
        log: _session.log,
        status: _session.isOpen ? _session.link!.description : 'not connected',
        pcapLink: const PcapUser(),
        configure: Builder(
          builder: (tabContext) => FormColumn(
            children: [
              SerialDevicePicker(selected: _device, onChanged: (device) => setState(() => _device = device)),
              ProfileBar(controllers: _fields, onLoaded: () => setState(() {})),
              SerialSettingsForm(fields: _fields),
              FilledButton.icon(
                onPressed: _session.isBusy ? null : () => _toggle(tabContext),
                icon: Icon(_session.isOpen ? Icons.link_off : Icons.link),
                label: Text(_session.isOpen ? 'Close port' : 'Open port'),
              ),
            ],
          ),
        ),
        talk: Column(
          children: [
            if (_session.link is SerialLink)
              Wrap(
                spacing: 8,
                children: [
                  FilterChip(label: const Text('DTR'), selected: _dtr, onSelected: (value) => setState(() {
                    _dtr = value;
                    _setLines();
                  })),
                  FilterChip(label: const Text('RTS'), selected: _rts, onSelected: (value) => setState(() {
                    _rts = value;
                    _setLines();
                  })),
                ],
              ),
            Expanded(child: LogView(log: _session.log)),
            Padding(
              padding: const EdgeInsets.all(8),
              child: SendBar(settings: _settings, isEnabled: _session.isOpen, onSend: _session.send, defaultEnding: LineEnding.lf),
            ),
          ],
        ),
      ),
    );
  }
}
