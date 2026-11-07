import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/bytes/hex.dart';
import '../../core/inspect/frame.dart';
import '../../core/log/log_export.dart';
import '../../core/log/session_log.dart';
import '../../core/settings/tool_settings.dart';
import '../../core/ui/form_parts.dart';
import '../../core/ui/tool_scaffold.dart';
import '../../protocols/bus/bus_frames.dart';
import 'bridge_connection.dart';

/// What [BridgeToolState.run] returns when the command failed (the error
/// is already shown). Success can carry null data, so null cannot mean
/// failure.
const bridgeFailed = Object();

/// Shared parts of the bus tools: settings, a log of decoded bus frames,
/// and running a bridge command with errors shown to the user.
mixin BridgeToolState<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  String get toolId;
  Map<String, String> get defaults;

  late final settings = ref.read(toolSettingsProvider(toolId));
  late final fields = SettingsControllers(settings, defaults);
  final log = SessionLog();
  bool isBusy = false;

  BridgeConnection get bridge => ref.read(bridgeConnectionProvider);

  @override
  void dispose() {
    fields.dispose();
    log.dispose();
    super.dispose();
  }

  /// Runs [command] on the bridge; returns [bridgeFailed] after showing the
  /// error.
  Future<Object?> run(String command, {Duration? timeout}) async {
    setState(() => isBusy = true);
    try {
      await fields.remember();
      return await bridge.command(command, timeout: timeout);
    } on Object catch (error) {
      log.note('$command → $error');
      if (mounted) showError(context, error);
      return bridgeFailed;
    } finally {
      if (mounted) setState(() => isBusy = false);
    }
  }

  /// "Init" row for pins and speed, the first step of every bus.
  Widget initButton(String label, String Function() command) => OutlinedButton.icon(
    onPressed: isBusy
        ? null
        : () async {
            try {
              final text = command();
              final reply = await run(text);
              if (!identical(reply, bridgeFailed)) log.note('$text ok');
            } on FormatException catch (error) {
              if (mounted) showError(context, error);
            }
          },
    icon: const Icon(Icons.power_settings_new),
    label: Text(label),
  );

  Widget scaffold({required String title, required Widget configure, required Widget talk, PcapLink? pcapLink, String? feature}) {
    final connection = ref.watch(bridgeConnectionProvider);
    return ListenableBuilder(
      listenable: connection,
      builder: (context, _) {
        final isMissing = !connection.isConnected || (feature != null && !connection.features.contains(feature));
        return ToolScaffold(
          toolId: toolId,
          title: title,
          log: log,
          status: connection.description,
          pcapLink: pcapLink,
          configure: isMissing ? BridgeMissing(feature: connection.isConnected ? feature : null) : configure,
          talk: isMissing ? BridgeMissing(feature: connection.isConnected ? feature : null) : talk,
        );
      },
    );
  }
}

// ---- I2C -----------------------------------------------------------------

class I2cTool extends ConsumerStatefulWidget {
  const I2cTool({super.key});

  @override
  ConsumerState<I2cTool> createState() => _I2cToolState();
}

class _I2cToolState extends ConsumerState<I2cTool> with BridgeToolState<I2cTool> {
  @override
  String get toolId => 'i2c';

  @override
  Map<String, String> get defaults => {'sda': '8', 'scl': '9', 'hz': '100000', 'address': '0x76', 'write': 'd0', 'readLength': '1'};

  List<int> _found = const [];
  Uint8List? _lastRead;

  int _address() {
    final text = fields.text('address');
    final value = text.startsWith('0x') ? int.tryParse(text.substring(2), radix: 16) : int.tryParse(text);
    if (value == null || value < 0x08 || value > 0x77) throw const FormatException('Address: 7-bit, 0x08..0x77');
    return value;
  }

  Future<void> _scan() async {
    final reply = await run('i2c scan');
    if (reply is! List) return;
    setState(() => _found = [for (final address in reply) address as int]);
    log.note('scan: ${_found.isEmpty ? 'nothing answered' : _found.map(hex8).join(', ')}');
  }

  Future<void> _transfer() async {
    try {
      final address = _address();
      final written = parseHex(fields.text('write'));
      final readLength = fields.number('readLength', max: 255, label: 'Read length');
      final reply = await run('i2c xfer ${hex8(address)} ${written.isEmpty ? '-' : toHex(written, separator: '')} $readLength');
      if (reply is! Map) return;
      final read = parseHex('${reply['read'] ?? ''}');
      log.received(describeI2cTransaction(address: address, written: written, read: read));
      setState(() => _lastRead = read);
    } on FormatException catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => scaffold(
    title: 'I2C',
    feature: 'i2c',
    configure: FormColumn(children: [
      Row(children: [
        Expanded(child: LabeledField(controller: fields['sda'], label: 'SDA pin', isNumber: true)),
        const SizedBox(width: 8),
        Expanded(child: LabeledField(controller: fields['scl'], label: 'SCL pin', isNumber: true)),
        const SizedBox(width: 8),
        Expanded(child: LabeledField(controller: fields['hz'], label: 'Clock (Hz)', isNumber: true, helper: '100k std · 400k fast')),
      ]),
      initButton('Init I2C', () => 'i2c init ${fields.number('sda', max: 48)} ${fields.number('scl', max: 48)} ${fields.number('hz', min: 1000, max: 1000000)}'),
      const Text('Needs pull-up resistors (2.2k–10k) on SDA and SCL; many sensor boards have them.'),
    ]),
    talk: ListView(padding: const EdgeInsets.all(12), children: [
      FilledButton.icon(onPressed: isBusy ? null : _scan, icon: const Icon(Icons.radar), label: const Text('Scan bus')),
      for (final address in _found)
        ListTile(
          dense: true,
          title: Text(hex8(address), style: monospace),
          subtitle: Text(i2cKnownDevices[address] ?? 'unknown device'),
          onTap: () => setState(() => fields['address'].text = hex8(address)),
        ),
      const Divider(height: 24),
      Row(children: [
        Expanded(child: LabeledField(controller: fields['address'], label: 'Address', hint: '0x76')),
        const SizedBox(width: 8),
        Expanded(child: LabeledField(controller: fields['write'], label: 'Write (hex)', helper: 'register first')),
        const SizedBox(width: 8),
        Expanded(child: LabeledField(controller: fields['readLength'], label: 'Then read', isNumber: true)),
      ]),
      const SizedBox(height: 8),
      FilledButton(onPressed: isBusy ? null : _transfer, child: const Text('Transfer')),
      if (_lastRead != null) Padding(padding: const EdgeInsets.only(top: 12), child: SelectableText('read: ${toHex(_lastRead!)}', style: monospace)),
      const Text('Example: BME280 at 0x76, write d0, read 1 → 60 (its chip id).'),
    ]),
  );
}

// ---- SPI -----------------------------------------------------------------

class SpiTool extends ConsumerStatefulWidget {
  const SpiTool({super.key});

  @override
  ConsumerState<SpiTool> createState() => _SpiToolState();
}

class _SpiToolState extends ConsumerState<SpiTool> with BridgeToolState<SpiTool> {
  @override
  String get toolId => 'spi';

  @override
  Map<String, String> get defaults => {'sclk': '12', 'mosi': '11', 'miso': '13', 'cs': '10', 'hz': '1000000', 'mode': '0', 'data': '9f 00 00 00'};

  Future<void> _transfer() async {
    try {
      final written = parseHex(fields.text('data'));
      if (written.isEmpty) throw const FormatException('Data: at least one byte');
      final reply = await run('spi xfer ${toHex(written, separator: '')}');
      if (reply is! Map) return;
      final read = parseHex('${reply['read'] ?? ''}');
      final bytes = Uint8List.fromList([...written, ...read]);
      log.received(Frame(
        protocol: 'SPI',
        summary: 'MOSI ${toHex(written)} · MISO ${toHex(read)}',
        bytes: bytes,
        fields: [
          for (var index = 0; index < written.length; index++)
            Field('byte $index', index, 1, 'out ${hex8(written[index])} · in ${index < read.length ? hex8(read[index]) : '--'}',
                note: index == 0 ? 'one clock pulse moves one bit each way' : ''),
        ],
      ));
      setState(() {});
    } on FormatException catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => scaffold(
    title: 'SPI',
    feature: 'spi',
    configure: FormColumn(children: [
      Row(children: [
        Expanded(child: LabeledField(controller: fields['sclk'], label: 'SCLK', isNumber: true)),
        const SizedBox(width: 8),
        Expanded(child: LabeledField(controller: fields['mosi'], label: 'MOSI', isNumber: true)),
        const SizedBox(width: 8),
        Expanded(child: LabeledField(controller: fields['miso'], label: 'MISO', isNumber: true)),
        const SizedBox(width: 8),
        Expanded(child: LabeledField(controller: fields['cs'], label: 'CS', isNumber: true)),
      ]),
      Row(children: [
        Expanded(child: LabeledField(controller: fields['hz'], label: 'Clock (Hz)', isNumber: true)),
        const SizedBox(width: 8),
        Expanded(
          child: ChoiceField<String>(
            label: 'Mode (CPOL/CPHA)',
            value: fields.text('mode'),
            options: const {'0': '0: idle low, sample rising', '1': '1: idle low, sample falling', '2': '2: idle high, sample falling', '3': '3: idle high, sample rising'},
            onChanged: (value) => setState(() => fields['mode'].text = value),
          ),
        ),
      ]),
      initButton('Init SPI', () => 'spi init ${fields.number('sclk', max: 48)} ${fields.number('mosi', max: 48)} ${fields.number('miso', max: 48)} '
          '${fields.number('cs', max: 48)} ${fields.number('hz', min: 1000, max: 80000000)} ${fields.number('mode', max: 3)}'),
    ]),
    talk: ListView(padding: const EdgeInsets.all(12), children: [
      LabeledField(controller: fields['data'], label: 'Bytes out (MOSI, hex)', helper: '9f 00 00 00 = JEDEC id of a SPI flash'),
      const SizedBox(height: 8),
      FilledButton(onPressed: isBusy ? null : _transfer, child: const Text('Transfer (CS low → bytes → CS high)')),
      const SizedBox(height: 8),
      const Text('SPI always sends and receives at once: as many bytes come in as go out. Send 00 to clock in a reply.'),
    ]),
  );
}

// ---- CAN -----------------------------------------------------------------

class _CanIdStats {
  _CanIdStats(this.frame, this.time);
  CanFrame frame;
  DateTime time;
  int count = 1;
  Duration? period;
}

class CanTool extends ConsumerStatefulWidget {
  const CanTool({super.key});

  @override
  ConsumerState<CanTool> createState() => _CanToolState();
}

class _CanToolState extends ConsumerState<CanTool> with BridgeToolState<CanTool> {
  @override
  String get toolId => 'can';

  @override
  Map<String, String> get defaults => {'tx': '4', 'rx': '5', 'bitrate': '500000', 'id': '123', 'data': '01 02 03 04', 'extended': 'false', 'remote': 'false'};

  final _byId = <String, _CanIdStats>{};
  StreamSubscription<Map<String, Object?>>? _events;
  bool _isRunning = false;

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  void _listen() {
    unawaited(_events?.cancel());
    _events = bridge.events.where((event) => event['event'] == 'can').listen((event) {
      final frame = CanFrame.fromEvent(event);
      if (frame == null) return;
      log.received(describeCanFrame(frame));
      final key = '${frame.isExtended ? 'x' : 's'}${frame.id}';
      final now = DateTime.now();
      final stats = _byId[key];
      if (stats == null) {
        _byId[key] = _CanIdStats(frame, now);
      } else {
        stats
          ..period = now.difference(stats.time)
          ..time = now
          ..frame = frame
          ..count += 1;
      }
      if (mounted) setState(() {});
    });
  }

  Future<void> _start() async {
    final reply = await run('can init ${fields.number('tx', max: 48)} ${fields.number('rx', max: 48)} ${fields.number('bitrate', min: 10000, max: 1000000)}');
    if (identical(reply, bridgeFailed)) return;
    _listen();
    setState(() => _isRunning = true);
  }

  Future<void> _stop() async {
    await run('can stop');
    await _events?.cancel();
    setState(() => _isRunning = false);
  }

  Future<void> _send() async {
    try {
      final isExtended = fields.text('extended') == 'true';
      final isRemote = fields.text('remote') == 'true';
      final id = int.tryParse(fields.text('id'), radix: 16);
      if (id == null || id < 0 || id > (isExtended ? 0x1fffffff : 0x7ff)) {
        throw FormatException('Id: hex, max ${isExtended ? '1fffffff (29-bit)' : '7ff (11-bit)'}');
      }
      final data = parseHex(fields.text('data'));
      if (data.length > 8) throw const FormatException('Classic CAN carries 0..8 data bytes');
      final frame = CanFrame(id: id, data: data, isExtended: isExtended, isRemote: isRemote);
      final reply = await run('can send ${id.toRadixString(16)} ${data.isEmpty ? '-' : toHex(data, separator: '')}'
          '${isExtended ? ' ext' : ''}${isRemote ? ' rtr' : ''}');
      if (!identical(reply, bridgeFailed)) log.sent(describeCanFrame(frame));
    } on FormatException catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _byId.values.toList()..sort((left, right) => left.frame.id.compareTo(right.frame.id));
    return scaffold(
      title: 'CAN bus',
      feature: 'can',
      pcapLink: const PcapSocketCan(),
      configure: FormColumn(children: [
        Row(children: [
          Expanded(child: LabeledField(controller: fields['tx'], label: 'TX pin', isNumber: true)),
          const SizedBox(width: 8),
          Expanded(child: LabeledField(controller: fields['rx'], label: 'RX pin', isNumber: true)),
        ]),
        ChoiceField<String>(
          label: 'Bit rate',
          value: fields.text('bitrate'),
          options: const {'125000': '125 kbit/s', '250000': '250 kbit/s (J1939 trucks)', '500000': '500 kbit/s (cars, OBD-II)', '1000000': '1 Mbit/s'},
          onChanged: (value) => setState(() => fields['bitrate'].text = value),
        ),
        const Text('Needs a CAN transceiver (SN65HVD230, 3.3 V) and 120 Ω at both ends of the bus.'),
        FilledButton.icon(
          onPressed: isBusy ? null : (_isRunning ? _stop : _start),
          icon: Icon(_isRunning ? Icons.stop : Icons.play_arrow),
          label: Text(_isRunning ? 'Stop' : 'Start (normal mode)'),
        ),
      ]),
      talk: Column(children: [
        Expanded(
          child: ListView(children: [
            const ListTile(dense: true, title: Text('id · count · period · last data', style: TextStyle(fontWeight: FontWeight.bold))),
            for (final stats in rows)
              ListTile(
                dense: true,
                title: Text('${stats.frame.idText}  [${stats.frame.data.length}]  ${toHex(stats.frame.data)}', style: monospace),
                subtitle: Text('×${stats.count}${stats.period == null ? '' : ' · every ${stats.period!.inMilliseconds} ms'}'),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            SizedBox(width: 90, child: LabeledField(controller: fields['id'], label: 'Id (hex)')),
            const SizedBox(width: 8),
            Expanded(child: LabeledField(controller: fields['data'], label: 'Data (hex)')),
            Column(mainAxisSize: MainAxisSize.min, children: [
              FilterChip(label: const Text('ext'), selected: fields.text('extended') == 'true', onSelected: (value) => setState(() => fields['extended'].text = '$value')),
              FilterChip(label: const Text('rtr'), selected: fields.text('remote') == 'true', onSelected: (value) => setState(() => fields['remote'].text = '$value')),
            ]),
            IconButton.filled(onPressed: _isRunning && !isBusy ? _send : null, icon: const Icon(Icons.send)),
          ]),
        ),
      ]),
    );
  }
}

// ---- 1-Wire --------------------------------------------------------------

class OneWireTool extends ConsumerStatefulWidget {
  const OneWireTool({super.key});

  @override
  ConsumerState<OneWireTool> createState() => _OneWireToolState();
}

class _OneWireToolState extends ConsumerState<OneWireTool> with BridgeToolState<OneWireTool> {
  @override
  String get toolId => 'onewire';

  @override
  Map<String, String> get defaults => {'pin': '6'};

  List<Uint8List> _roms = const [];
  final _temperatures = <String, double?>{};

  Future<void> _search() async {
    final reply = await run('ow search', timeout: const Duration(seconds: 5));
    if (reply is! List) return;
    final roms = <Uint8List>[];
    for (final text in reply) {
      final rom = parseHex('$text');
      roms.add(rom);
      log.received(describeOneWireRom(rom));
    }
    setState(() => _roms = roms);
  }

  Future<void> _readTemperature(Uint8List rom) async {
    final key = toHex(rom, separator: '');
    // Conversion takes up to 750 ms at 12-bit, so allow longer than usual.
    final reply = await run('ow ds18b20 $key', timeout: const Duration(seconds: 3));
    if (reply is! Map) return;
    final result = describeDs18b20Scratchpad(parseHex('${reply['scratchpad'] ?? ''}'));
    log.received(result.frame);
    setState(() => _temperatures[key] = result.celsius);
  }

  @override
  Widget build(BuildContext context) => scaffold(
    title: '1-Wire',
    feature: 'onewire',
    configure: FormColumn(children: [
      LabeledField(controller: fields['pin'], label: 'Data pin', isNumber: true, helper: 'with a 4.7k pull-up to 3.3 V'),
      initButton('Init 1-Wire', () => 'ow init ${fields.number('pin', max: 48)}'),
    ]),
    talk: ListView(padding: const EdgeInsets.all(12), children: [
      FilledButton.icon(onPressed: isBusy ? null : _search, icon: const Icon(Icons.search), label: const Text('Search ROM codes')),
      for (final rom in _roms)
        ListTile(
          title: Text(toHex(rom, separator: ''), style: monospace),
          subtitle: Text('${oneWireFamilies[rom.first] ?? 'family ${hex8(rom.first)}'}'
              '${_temperatures.containsKey(toHex(rom, separator: '')) ? ' · ${_temperatures[toHex(rom, separator: '')] ?? 'CRC error'} °C' : ''}'),
          trailing: rom.first == 0x28 ? IconButton(icon: const Icon(Icons.thermostat), onPressed: isBusy ? null : () => _readTemperature(rom)) : null,
        ),
    ]),
  );
}
