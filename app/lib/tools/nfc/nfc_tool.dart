import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';

import '../../app/theme.dart';
import '../../core/bytes/hex.dart';
import '../../core/inspect/frame.dart';
import '../../core/log/session_log.dart';
import '../../core/settings/tool_settings.dart';
import '../../core/ui/form_parts.dart';
import '../../core/ui/tool_scaffold.dart';
import '../../protocols/nfc/ndef_view.dart';

/// NFC through the community package nfc_manager: tag id, technologies,
/// and the NDEF message (read or write).
class NfcTool extends ConsumerStatefulWidget {
  const NfcTool({super.key});

  @override
  ConsumerState<NfcTool> createState() => _NfcToolState();
}

class _NfcToolState extends ConsumerState<NfcTool> {
  late final _settings = ref.read(toolSettingsProvider('nfc'));
  late final _fields = SettingsControllers(_settings, {'kind': 'uri', 'text': 'https://example.com'});
  final _log = SessionLog();
  String _status = 'idle';
  bool _isSessionOpen = false;
  String _lastTag = '';

  @override
  void dispose() {
    if (_isSessionOpen) unawaited(NfcManager.instance.stopSession().catchError((Object _) {}));
    _fields.dispose();
    _log.dispose();
    super.dispose();
  }

  NdefMessage _messageToWrite() {
    final text = _fields['text'].text;
    if (_fields.text('kind') == 'uri') {
      return NdefMessage(records: [
        NdefRecord(
          typeNameFormat: TypeNameFormat.wellKnown,
          type: Uint8List.fromList([0x55]), // "U"
          identifier: Uint8List(0),
          payload: Uint8List.fromList([0x00, ...utf8.encode(text)]), // prefix 0: full URI
        ),
      ]);
    }
    return NdefMessage(records: [
      NdefRecord(
        typeNameFormat: TypeNameFormat.wellKnown,
        type: Uint8List.fromList([0x54]), // "T"
        identifier: Uint8List(0),
        payload: Uint8List.fromList([0x02, ...ascii.encode('en'), ...utf8.encode(text)]),
      ),
    ]);
  }

  Future<void> _start({required bool isWrite, required BuildContext tabContext}) async {
    try {
      final availability = await NfcManager.instance.checkAvailability();
      if (availability != NfcAvailability.enabled) throw StateError('NFC is ${availability.name}');
      await _fields.remember();
      final message = isWrite ? _messageToWrite() : null;
      setState(() {
        _isSessionOpen = true;
        _status = isWrite ? 'hold a tag to write...' : 'hold a tag to the phone...';
      });
      if (tabContext.mounted) DefaultTabController.of(tabContext).animateTo(1);
      await NfcManager.instance.startSession(
        pollingOptions: {NfcPollingOption.iso14443, NfcPollingOption.iso15693},
        onDiscovered: (tag) async {
          final tagInfo = NfcTagAndroid.from(tag);
          final ndef = NdefAndroid.from(tag);
          final id = tagInfo == null ? '?' : toHex(tagInfo.id, separator: ':');
          final technologies = tagInfo?.techList.map((tech) => tech.split('.').last).join(', ') ?? '';
          _log.received(Frame(
            protocol: 'NFC tag',
            summary: 'tag $id · $technologies',
            bytes: tagInfo?.id ?? Uint8List(0),
            fields: [Field('UID', 0, tagInfo?.id.length ?? 0, id, note: '4, 7 or 10 bytes; not secret, easy to copy'), Field('technologies', 0, 0, technologies)],
          ));
          try {
            if (ndef == null) {
              _log.note('tag has no NDEF (not formatted, or a bank card)');
            } else if (message != null) {
              await ndef.writeNdefMessage(message);
              _log.sent(describeNdef(message.encode()));
              _log.note('written ${message.byteLength} bytes of ${ndef.maxSize}');
            } else {
              final read = await ndef.getNdefMessage();
              if (read == null) {
                _log.note('NDEF tag, empty');
              } else {
                _log.received(describeNdef(read.encode()));
              }
            }
          } on Object catch (error) {
            _log.note('failed: $error');
          }
          await NfcManager.instance.stopSession();
          if (mounted) {
            setState(() {
              _isSessionOpen = false;
              _status = 'done';
              _lastTag = '$id\n$technologies';
            });
          }
        },
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() => _isSessionOpen = false);
        showError(context, error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ToolScaffold(
      toolId: 'nfc',
      title: 'NFC tags',
      log: _log,
      status: _status,
      configure: Builder(
        builder: (tabContext) => FormColumn(
          children: [
            FilledButton.icon(
              onPressed: _isSessionOpen ? null : () => _start(isWrite: false, tabContext: tabContext),
              icon: const Icon(Icons.nfc),
              label: const Text('Read a tag'),
            ),
            const Divider(),
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'uri', label: Text('URI')), ButtonSegment(value: 'text', label: Text('Text'))],
              selected: {_fields.text('kind')},
              onSelectionChanged: (selection) => setState(() => _fields['kind'].text = selection.first),
            ),
            LabeledField(controller: _fields['text'], label: _fields.text('kind') == 'uri' ? 'URI' : 'Text'),
            OutlinedButton.icon(
              onPressed: _isSessionOpen ? null : () => _start(isWrite: true, tabContext: tabContext),
              icon: const Icon(Icons.edit),
              label: const Text('Write to a tag'),
            ),
          ],
        ),
      ),
      talk: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.nfc, size: 64, color: _isSessionOpen ? Theme.of(context).colorScheme.primary : null),
          Text(_status),
          if (_lastTag.isNotEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(_lastTag, style: monospace, textAlign: TextAlign.center)),
          const Text('Tap the Inside tab to see the NDEF bytes.'),
        ]),
      ),
    );
  }
}
