import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/log/log_export.dart';
import '../../core/log/session_log.dart';
import '../../core/settings/tool_settings.dart';
import '../../core/transport/serial_link.dart';
import '../../core/transport/tcp_link.dart';
import '../../core/ui/form_parts.dart';
import '../../core/ui/tool_scaffold.dart';
import '../../protocols/modbus/modbus_codec.dart';
import '../../protocols/modbus/modbus_master.dart';
import '../serial/serial_tool.dart';

class ModbusTool extends ConsumerStatefulWidget {
  const ModbusTool({super.key});

  @override
  ConsumerState<ModbusTool> createState() => _ModbusToolState();
}

class _ModbusToolState extends ConsumerState<ModbusTool> {
  late final _settings = ref.read(toolSettingsProvider('modbus'));
  late final _fields = SettingsControllers(_settings, {
    ...SerialSettingsForm.defaults,
    'baud': '9600',
    'parity': 'even',
    'mode': 'tcp',
    'host': '192.168.1.100',
    'port': '502',
    'timeoutMs': '1000',
    'unit': '1',
    'function': '3',
    'address': '0',
    'quantity': '10',
    'values': '',
    'pollMs': '1000',
  });
  final _log = SessionLog();
  ModbusMaster? _master;
  SerialDevice? _device;
  ModbusResponse? _lastResponse;
  int _lastAddress = 0;
  Timer? _pollTimer;
  bool _isBusy = false;
  int _okCount = 0;
  int _failCount = 0;

  ModbusMode get _mode => _fields.text('mode') == 'rtu' ? ModbusMode.rtu : ModbusMode.tcp;
  ModbusFunction get _function => ModbusFunction.fromCode(int.tryParse(_fields.text('function')) ?? 3) ?? ModbusFunction.readHoldingRegisters;

  @override
  void dispose() {
    _pollTimer?.cancel();
    unawaited(_master?.close());
    _fields.dispose();
    _log.dispose();
    super.dispose();
  }

  Future<void> _toggleConnection(BuildContext tabContext) async {
    if (_master != null) {
      _pollTimer?.cancel();
      _pollTimer = null;
      await _master!.close();
      _log.note('closed');
      setState(() => _master = null);
      return;
    }
    setState(() => _isBusy = true);
    try {
      await _fields.remember();
      final timeout = Duration(milliseconds: _fields.number('timeoutMs', min: 50, max: 60000, label: 'Timeout'));
      final link = _mode == ModbusMode.tcp
          ? await TcpLink.connect(_fields.text('host'), _fields.number('port', min: 1, max: 65535, label: 'Port'))
          : await SerialPorts.open(_device ?? (throw const FormatException('Pick a serial port')), SerialSettingsForm.read(_fields));
      _log.note('opened ${link.description}');
      setState(() => _master = ModbusMaster(link: link, log: _log, mode: _mode, timeout: timeout));
      if (tabContext.mounted) DefaultTabController.of(tabContext).animateTo(1);
    } on Object catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  ModbusRequest _request() {
    final function = _function;
    final isWrite = !(function.readsBits || function.readsRegisters);
    final values = isWrite
        ? [
            for (final part in _fields.text('values').split(RegExp(r'[,\s]+')).where((part) => part.isNotEmpty))
              part.startsWith('0x') ? int.parse(part.substring(2), radix: 16) : int.parse(part),
          ]
        : const <int>[];
    final request = ModbusRequest(
      unitId: _fields.number('unit', max: 255, label: 'Unit id'),
      function: function,
      address: _fields.number('address', max: 65535, label: 'Address'),
      quantity: isWrite ? 1 : _fields.number('quantity', min: 1, max: 2000, label: 'Quantity'),
      values: values,
    )..check();
    return request;
  }

  Future<void> _sendOnce() async {
    final master = _master;
    if (master == null) return;
    try {
      final request = _request();
      final response = await master.send(request);
      if (!mounted) return;
      setState(() {
        _okCount++;
        _lastAddress = request.address;
        _lastResponse = response;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _failCount++);
      if (_pollTimer == null) showError(context, error);
    }
  }

  void _togglePoll() {
    if (_pollTimer != null) {
      _pollTimer!.cancel();
      setState(() => _pollTimer = null);
      return;
    }
    try {
      final period = Duration(milliseconds: _fields.number('pollMs', min: 50, max: 3600000, label: 'Poll interval'));
      _request();
      var isRunning = false;
      setState(() => _pollTimer = Timer.periodic(period, (_) async {
        if (isRunning) return; // a slow device: skip a tick, never pile up
        isRunning = true;
        await _sendOnce();
        isRunning = false;
      }));
    } on Object catch (error) {
      showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final function = _function;
    final isWrite = !(function.readsBits || function.readsRegisters);
    return ToolScaffold(
      toolId: 'modbus',
      title: 'Modbus master',
      log: _log,
      status: _master == null ? 'not connected' : '${_mode.name.toUpperCase()} · ok $_okCount · failed $_failCount',
      isConnected: _master != null,
      onConnect: _toggleConnection,
      isBusy: _isBusy,
      pcapLink: _mode == ModbusMode.tcp ? PcapTcp(int.tryParse(_fields.text('port')) ?? 502) : const PcapUser(),
      configure: Builder(
        builder: (tabContext) => FormColumn(
          children: [
            ProfileBar(controllers: _fields, onLoaded: () => setState(() {})),
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'tcp', label: Text('TCP (Ethernet/Wi-Fi)')), ButtonSegment(value: 'rtu', label: Text('RTU (RS-485)'))],
              selected: {_fields.text('mode')},
              onSelectionChanged: _master != null ? null : (selection) => setState(() => _fields['mode'].text = selection.first),
            ),
            if (_mode == ModbusMode.tcp) ...[
              LabeledField(controller: _fields['host'], label: 'Device / gateway host'),
              LabeledField(controller: _fields['port'], label: 'Port', isNumber: true, helper: '502 is the Modbus TCP port'),
            ] else ...[
              SerialDevicePicker(selected: _device, onChanged: (device) => setState(() => _device = device)),
              SerialSettingsForm(fields: _fields),
              const Text('RS-485 needs a USB-RS485 adapter with automatic direction control.'),
            ],
            LabeledField(controller: _fields['timeoutMs'], label: 'Reply timeout (ms)', isNumber: true),
            FilledButton.icon(
              onPressed: _isBusy ? null : () => _toggleConnection(tabContext),
              icon: Icon(_master == null ? Icons.link : Icons.link_off),
              label: Text(_master == null ? 'Open' : 'Close'),
            ),
          ],
        ),
      ),
      talk: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          ChoiceField<String>(
            label: 'Function',
            value: _fields.text('function'),
            options: {for (final function in ModbusFunction.values) '${function.code}': '${function.code} · ${function.label}'},
            onChanged: (value) => setState(() => _fields['function'].text = value),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: LabeledField(controller: _fields['unit'], label: 'Unit id', isNumber: true)),
            const SizedBox(width: 8),
            Expanded(child: LabeledField(controller: _fields['address'], label: 'Address', isNumber: true, helper: '0-based: 40001 → 0')),
            const SizedBox(width: 8),
            if (!isWrite) Expanded(child: LabeledField(controller: _fields['quantity'], label: 'Quantity', isNumber: true)),
          ]),
          if (isWrite) ...[
            const SizedBox(height: 8),
            LabeledField(
              controller: _fields['values'],
              label: function == ModbusFunction.writeSingleCoil || function == ModbusFunction.writeMultipleCoils ? 'Values (0/1, comma separated)' : 'Values (0..65535 or 0x..)',
            ),
          ],
          const SizedBox(height: 8),
          Row(children: [
            FilledButton(onPressed: _master == null ? null : _sendOnce, child: const Text('Send')),
            const SizedBox(width: 12),
            if (!isWrite) ...[
              SizedBox(width: 110, child: LabeledField(controller: _fields['pollMs'], label: 'Poll (ms)', isNumber: true)),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _master == null ? null : _togglePoll, child: Text(_pollTimer == null ? 'Poll' : 'Stop')),
            ],
          ]),
          const Divider(height: 24),
          _ResultTable(response: _lastResponse, startAddress: _lastAddress),
        ],
      ),
    );
  }
}

/// Registers shown the ways a datasheet may mean them: unsigned, signed,
/// hex. (Two registers can also hold one 32-bit value or a float; the order
/// of the two words differs between vendors.)
class _ResultTable extends StatelessWidget {
  const _ResultTable({required this.response, required this.startAddress});

  final ModbusResponse? response;
  final int startAddress;

  @override
  Widget build(BuildContext context) {
    final response = this.response;
    if (response == null) return const Text('No reply yet.');
    if (response.registers.isNotEmpty) {
      return Table(
        columnWidths: const {0: IntrinsicColumnWidth()},
        children: [
          const TableRow(children: [Text('address'), Text('unsigned'), Text('signed'), Text('hex')]),
          for (final (index, value) in response.registers.indexed)
            TableRow(children: [
              Text('${startAddress + index}', style: monospace),
              Text('$value', style: monospace),
              Text('${value.toSigned(16)}', style: monospace),
              Text('0x${value.toRadixString(16).padLeft(4, '0')}', style: monospace),
            ]),
        ],
      );
    }
    if (response.bits.isNotEmpty) {
      return Wrap(spacing: 4, runSpacing: 4, children: [
        for (final (index, bit) in response.bits.indexed)
          Chip(label: Text('${startAddress + index}: ${bit ? 1 : 0}'), backgroundColor: bit ? Theme.of(context).colorScheme.primaryContainer : null),
      ]);
    }
    return Text('Write ok: address ${response.address}, ${response.value}');
  }
}
