import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../bytes/hex.dart';
import '../settings/tool_settings.dart';
import 'form_parts.dart';

enum LineEnding {
  none(''),
  lf('\n'),
  crlf('\r\n'),
  cr('\r');

  const LineEnding(this.text);
  final String text;

  String get label => switch (this) {
    none => 'none',
    lf => r'\n',
    crlf => r'\r\n',
    cr => r'\r',
  };
}

/// Text or hex input with line ending, and saved macros (long-press a macro
/// to delete it). Text mode understands \r \n \t \xNN escapes.
class SendBar extends StatefulWidget {
  const SendBar({super.key, required this.settings, required this.onSend, this.isEnabled = true, this.defaultEnding = LineEnding.none});

  final ToolSettings settings;
  final Future<void> Function(Uint8List bytes) onSend;
  final bool isEnabled;
  final LineEnding defaultEnding;

  @override
  State<SendBar> createState() => _SendBarState();
}

class _SendBarState extends State<SendBar> {
  final _input = TextEditingController();
  late bool _isHex = widget.settings.value('send.hex', 'false') == 'true';
  late LineEnding _ending = LineEnding.values.asNameMap()[widget.settings.value('send.ending', widget.defaultEnding.name)] ?? widget.defaultEnding;
  late List<String> _macros = _loadMacros();

  List<String> _loadMacros() {
    try {
      return [for (final item in jsonDecode(widget.settings.value('send.macros', '[]')) as List<dynamic>) '$item'];
    } on Object {
      return [];
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() => widget.settings.saveLast({
    ...widget.settings.last,
    'send.hex': '$_isHex',
    'send.ending': _ending.name,
    'send.macros': jsonEncode(_macros),
  });

  Uint8List _bytes(String text) => _isHex
      ? parseHex(text)
      : Uint8List.fromList([...parseEscapedText(text), ...utf8.encode(_ending.text)]);

  Future<void> _send(String text) async {
    try {
      await widget.onSend(_bytes(text));
    } on Object catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_macros.isNotEmpty)
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final macro in _macros)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: GestureDetector(
                      onLongPress: () {
                        setState(() => _macros = [..._macros]..remove(macro));
                        _saveSettings();
                      },
                      child: ActionChip(label: Text(macro), onPressed: widget.isEnabled ? () => _send(macro) : null),
                    ),
                  ),
              ],
            ),
          ),
        Row(
          children: [
            SegmentedButton<bool>(
              segments: const [ButtonSegment(value: false, label: Text('Text')), ButtonSegment(value: true, label: Text('Hex'))],
              selected: {_isHex},
              showSelectedIcon: false,
              onSelectionChanged: (selection) {
                setState(() => _isHex = selection.first);
                _saveSettings();
              },
            ),
            const SizedBox(width: 8),
            if (!_isHex)
              DropdownButton<LineEnding>(
                value: _ending,
                items: [for (final ending in LineEnding.values) DropdownMenuItem(value: ending, child: Text(ending.label))],
                onChanged: (ending) {
                  setState(() => _ending = ending ?? LineEnding.none);
                  _saveSettings();
                },
              ),
            const Spacer(),
            IconButton(
              tooltip: 'Save as macro',
              icon: const Icon(Icons.bookmark_add_outlined),
              onPressed: () {
                final text = _input.text;
                if (text.isEmpty || _macros.contains(text)) return;
                setState(() => _macros = [..._macros, text]);
                _saveSettings();
              },
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                decoration: InputDecoration(
                  hintText: _isHex ? '01 03 00 00 00 01' : r'AT\r\n or text',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: widget.isEnabled ? _send : null,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: widget.isEnabled ? () => _send(_input.text) : null, child: const Text('Send')),
          ],
        ),
      ],
    );
  }
}
