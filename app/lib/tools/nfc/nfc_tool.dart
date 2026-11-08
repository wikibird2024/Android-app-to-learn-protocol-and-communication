import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';

import '../../app/theme.dart';
import '../../core/inspect/frame.dart';
import '../../core/log/session_log.dart';
import '../../core/settings/tool_settings.dart';
import '../../core/ui/form_parts.dart';
import '../../core/ui/tool_scaffold.dart';
import '../../protocols/nfc/ndef_build.dart';
import '../../protocols/nfc/ndef_view.dart';
import '../../protocols/nfc/tag_identify.dart';

/// What one tap of a tag does.
enum _TagJob {
  read('hold a tag to read...'),
  identify('hold a tag to identify...'),
  write('hold a tag to write...'),
  erase('hold the tag to erase...'),
  lock('hold the tag to LOCK (permanent)...');

  const _TagJob(this.prompt);
  final String prompt;
}

/// NFC through the community package nfc_manager: identify a tag, read,
/// write (URI, text, Wi-Fi, several records), erase, lock, and copy one
/// tag's message to another.
class NfcTool extends ConsumerStatefulWidget {
  const NfcTool({super.key});

  @override
  ConsumerState<NfcTool> createState() => _NfcToolState();
}

class _NfcToolState extends ConsumerState<NfcTool> {
  late final _settings = ref.read(toolSettingsProvider('nfc'));
  late final _fields = SettingsControllers(_settings, {
    'kind': 'uri',
    'text': 'https://example.com',
    'ssid': '',
    'password': '',
  });
  final _log = SessionLog();
  String _status = 'idle';
  bool _isSessionOpen = false;
  String _lastTag = '';

  /// Records added before the one in the form; the form's record goes last.
  final _addedRecords = <NdefRecord>[];

  /// The message from the last read, kept so it can be written to another tag.
  NdefMessage? _copiedMessage;

  @override
  void initState() {
    super.initState();
    for (final key in ['text', 'ssid', 'password']) {
      _fields[key].addListener(() => setState(() {})); // the size on the Write button follows the form
    }
  }

  @override
  void dispose() {
    if (_isSessionOpen) unawaited(NfcManager.instance.stopSession().catchError((Object _) {}));
    _fields.dispose();
    _log.dispose();
    super.dispose();
  }

  NdefRecord _recordFromForm() => switch (_fields.text('kind')) {
    'wifi' => NdefRecord(
      typeNameFormat: TypeNameFormat.media,
      type: ascii.encode(wifiMimeType),
      identifier: Uint8List(0),
      payload: wifiPayload(ssid: _fields.text('ssid'), password: _fields['password'].text),
    ),
    'text' => NdefRecord(
      typeNameFormat: TypeNameFormat.wellKnown,
      type: Uint8List.fromList([0x54]), // "T"
      identifier: Uint8List(0),
      payload: textPayload(_fields['text'].text),
    ),
    _ => NdefRecord(
      typeNameFormat: TypeNameFormat.wellKnown,
      type: Uint8List.fromList([0x55]), // "U"
      identifier: Uint8List(0),
      payload: uriPayload(_fields.text('text')),
    ),
  };

  NdefMessage get _messageToWrite => NdefMessage(records: [..._addedRecords, _recordFromForm()]);

  static final _emptyMessage = NdefMessage(records: [
    NdefRecord(typeNameFormat: TypeNameFormat.empty, type: Uint8List(0), identifier: Uint8List(0), payload: Uint8List(0)),
  ]);

  Future<void> _start(_TagJob job, BuildContext tabContext, {NdefMessage? message}) async {
    try {
      final availability = await NfcManager.instance.checkAvailability();
      if (availability != NfcAvailability.enabled) throw StateError('NFC is ${availability.name}');
      await _fields.remember();
      setState(() {
        _isSessionOpen = true;
        _status = job.prompt;
      });
      if (tabContext.mounted) DefaultTabController.of(tabContext).animateTo(1);
      await NfcManager.instance.startSession(
        pollingOptions: {NfcPollingOption.iso14443, NfcPollingOption.iso15693},
        onDiscovered: (tag) async {
          final tagInfo = NfcTagAndroid.from(tag);
          final nfcA = NfcAAndroid.from(tag);
          final technologies = tagInfo?.techList.map((tech) => tech.split('.').last).join(', ') ?? '';
          final info = describeTagInfo(tagInfo?.id ?? Uint8List(0), technologies, atqa: nfcA?.atqa, sak: nfcA?.sak);
          _log.received(info);
          try {
            await _runJob(job, tag, message);
          } on StateError catch (error) {
            _log.note(error.message);
          } on Object catch (error) {
            _log.note('failed: ${friendlyError(error)}');
          }
          await NfcManager.instance.stopSession();
          if (mounted) {
            setState(() {
              _isSessionOpen = false;
              _status = 'done';
              _lastTag = info.summary;
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

  Future<void> _runJob(_TagJob job, NfcTag tag, NdefMessage? message) async {
    switch (job) {
      case _TagJob.read:
        final ndef = NdefAndroid.from(tag);
        if (ndef == null) throw StateError('tag has no NDEF (blank, MIFARE Classic the phone cannot read, or a bank card)');
        final read = await ndef.getNdefMessage();
        if (read == null) {
          _log.note('NDEF tag, empty');
          return;
        }
        _log.received(describeNdef(read.encode()));
        if (mounted) setState(() => _copiedMessage = read);
      case _TagJob.identify:
        await _identify(tag);
      case _TagJob.write:
        await _write(tag, message!);
      case _TagJob.erase:
        await _write(tag, _emptyMessage);
      case _TagJob.lock:
        final ndef = NdefAndroid.from(tag);
        if (ndef == null) throw StateError('not an NDEF tag: nothing to lock');
        if (!ndef.canMakeReadOnly) throw StateError('the phone cannot lock this tag type');
        await ndef.makeReadOnly();
        _log.note('locked: the tag is read-only for good');
    }
  }

  Future<void> _identify(NfcTag tag) async {
    final ndef = NdefAndroid.from(tag);
    if (ndef != null) {
      _log.note('NDEF ${ndef.type.split('.').last}: ${ndef.maxSize} bytes max, '
          '${ndef.isWritable ? 'writable' : 'read-only'}${ndef.canMakeReadOnly ? ', can be locked' : ''}');
    } else if (NdefFormatableAndroid.from(tag) != null) {
      _log.note('blank tag: Write formats it for NDEF');
    }
    final nfcA = NfcAAndroid.from(tag);
    // GET_VERSION is a Type 2 command; other families answer different commands.
    if (nfcA == null || nfcA.sak != 0x00) return;
    _log.sent(Frame.raw('NTAG', ntagGetVersion, summary: 'GET_VERSION'));
    try {
      _log.received(describeNtagVersion(await nfcA.transceive(ntagGetVersion)));
    } on Object {
      _log.note('no reply to GET_VERSION: an original MIFARE Ultralight or Ultralight C');
    }
  }

  Future<void> _write(NfcTag tag, NdefMessage message) async {
    final ndef = NdefAndroid.from(tag);
    if (ndef == null) {
      final formatable = NdefFormatableAndroid.from(tag);
      if (formatable == null) throw StateError('this tag cannot hold NDEF (bank card, or a tag type the phone cannot format)');
      await formatable.format(message);
      _log.sent(describeNdef(message.encode()));
      _log.note('formatted the blank tag and wrote ${message.byteLength} bytes');
      return;
    }
    if (!ndef.isWritable) throw StateError('tag is read-only (locked)');
    if (message.byteLength > ndef.maxSize) throw StateError('message is ${message.byteLength} bytes, this tag holds ${ndef.maxSize}');
    await ndef.writeNdefMessage(message);
    _log.sent(describeNdef(message.encode()));
    _log.note('written ${message.byteLength} bytes of ${ndef.maxSize}');
  }

  /// Asks before a write that cannot be undone. With [typedWord], the user
  /// must type it: a plain tap is too easy for a permanent change.
  Future<bool> _confirm(BuildContext context, {required String title, required String body, required String action, String? typedWord}) async {
    final typed = TextEditingController();
    final isConfirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(body),
            if (typedWord != null)
              TextField(
                controller: typed,
                autofocus: true,
                decoration: InputDecoration(labelText: 'Type $typedWord'),
                onChanged: (_) => setDialogState(() {}),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
              onPressed: typedWord == null || typed.text.trim() == typedWord ? () => Navigator.pop(context, true) : null,
              child: Text(action),
            ),
          ],
        ),
      ),
    );
    typed.dispose();
    return isConfirmed ?? false;
  }

  String _messageSize() {
    try {
      final message = _messageToWrite;
      final count = message.records.length;
      return '$count record${count == 1 ? '' : 's'}, ${message.byteLength} bytes';
    } on Object {
      return 'record too long';
    }
  }

  @override
  Widget build(BuildContext context) {
    final kind = _fields.text('kind');
    final heading = Theme.of(context).textTheme.titleSmall;
    final copied = _copiedMessage;
    return ToolScaffold(
      toolId: 'nfc',
      title: 'NFC tags',
      log: _log,
      status: _status,
      configure: Builder(
        builder: (tabContext) => FormColumn(
          children: [
            Text('Read', style: heading),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                onPressed: _isSessionOpen ? null : () => _start(_TagJob.read, tabContext),
                icon: const Icon(Icons.nfc),
                label: const Text('Read a tag'),
              ),
              OutlinedButton.icon(
                onPressed: _isSessionOpen ? null : () => _start(_TagJob.identify, tabContext),
                icon: const Icon(Icons.search),
                label: const Text('Identify'),
              ),
            ]),
            if (copied != null)
              OutlinedButton.icon(
                onPressed: _isSessionOpen ? null : () => _start(_TagJob.write, tabContext, message: copied),
                icon: const Icon(Icons.copy),
                label: Text('Copy last read to a tag (${copied.byteLength} bytes)'),
              ),
            const Divider(),
            Text('Write', style: heading),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'uri', label: Text('URI')),
                ButtonSegment(value: 'text', label: Text('Text')),
                ButtonSegment(value: 'wifi', label: Text('Wi-Fi')),
              ],
              selected: {kind},
              onSelectionChanged: (selection) => setState(() => _fields['kind'].text = selection.first),
            ),
            if (kind == 'wifi') ...[
              LabeledField(controller: _fields['ssid'], label: 'Network name (SSID)'),
              LabeledField(controller: _fields['password'], label: 'Password', helper: 'empty = open network; WPA2 otherwise', isSecret: true),
            ] else
              LabeledField(controller: _fields['text'], label: kind == 'uri' ? 'URI' : 'Text'),
            for (final (index, record) in _addedRecords.indexed)
              InputChip(
                label: Text(describeNdef(NdefMessage(records: [record]).encode()).summary, overflow: TextOverflow.ellipsis),
                onDeleted: () => setState(() => _addedRecords.removeAt(index)),
              ),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                onPressed: _isSessionOpen ? null : () => _start(_TagJob.write, tabContext, message: _messageToWrite),
                icon: const Icon(Icons.edit),
                label: Text('Write (${_messageSize()})'),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _addedRecords.add(_recordFromForm())),
                icon: const Icon(Icons.add),
                label: const Text('Add another record'),
              ),
            ]),
            const Divider(),
            Text('Erase and lock', style: heading),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                onPressed: _isSessionOpen
                    ? null
                    : () async {
                        final isSure = await _confirm(context, title: 'Erase the tag?', body: 'Writes one empty record over the whole message.', action: 'Erase');
                        if (isSure && tabContext.mounted) await _start(_TagJob.erase, tabContext);
                      },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Erase'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                onPressed: _isSessionOpen
                    ? null
                    : () async {
                        final isSure = await _confirm(
                          context,
                          title: 'Lock the tag for good?',
                          body: 'The tag becomes read-only. This cannot be undone: no app, phone or reader can write it again.',
                          action: 'Lock',
                          typedWord: 'LOCK',
                        );
                        if (isSure && tabContext.mounted) await _start(_TagJob.lock, tabContext);
                      },
                icon: const Icon(Icons.lock_outline),
                label: const Text('Lock (permanent)'),
              ),
            ]),
          ],
        ),
      ),
      talk: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.nfc, size: 64, color: _isSessionOpen ? Theme.of(context).colorScheme.primary : null),
          Text(_status),
          if (_lastTag.isNotEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(_lastTag, style: monospace, textAlign: TextAlign.center)),
          const Text('Tap the Inside tab to see the bytes.'),
        ]),
      ),
    );
  }
}
