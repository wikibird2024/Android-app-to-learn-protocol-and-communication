import 'package:flutter/material.dart';

import 'dart:typed_data';

import '../../app/theme.dart';
import '../bytes/hex.dart';
import '../inspect/frame.dart';
import 'learn_view.dart';
import 'wire_view.dart';

/// The Inside view of one frame: the bytes as a hex grid, and the fields
/// that explain them. Like ImHex, every top-level field has its own color
/// in both the grid and the list; like Wireshark, tapping a field
/// highlights its bytes and tapping a byte selects its field.
class FrameView extends StatefulWidget {
  const FrameView({super.key, required this.frame, this.showActions = true});

  final Frame frame;

  /// The "What if…" and "Learn" buttons; off inside the editor itself.
  final bool showActions;

  @override
  State<FrameView> createState() => _FrameViewState();
}

/// Field colors: distinct hues that work behind text in light and dark.
const _fieldHues = [Colors.blue, Colors.orange, Colors.teal, Colors.purple, Colors.pink, Colors.lime];

Color fieldColor(int index, Brightness brightness) =>
    _fieldHues[index % _fieldHues.length].withValues(alpha: brightness == Brightness.dark ? 0.35 : 0.22);

/// The deepest field that covers byte [index], or null. Zero-length fields
/// (bits of a byte share its offset) never win over their parent byte.
Field? fieldAtByte(List<Field> fields, int index) {
  for (final field in fields) {
    if (field.length > 0 && index >= field.offset && index < field.end) {
      return fieldAtByte(field.children, index) ?? field;
    }
  }
  return null;
}

class _FrameViewState extends State<FrameView> {
  Field? _selected;
  final _tileKeys = Map<Field, GlobalKey>.identity();

  void _selectByte(int index) {
    final field = fieldAtByte(widget.frame.fields, index);
    setState(() => _selected = identical(field, _selected) ? null : field);
    final key = field == null ? null : _tileKeys[field];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tileContext = key?.currentContext;
      if (tileContext != null && tileContext.mounted) {
        Scrollable.ensureVisible(tileContext, duration: const Duration(milliseconds: 200), alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final frame = widget.frame;
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final byteColors = List<Color?>.filled(frame.bytes.length, null);
    for (final (index, field) in frame.fields.indexed) {
      for (var byte = field.offset; byte < field.end && byte < byteColors.length; byte++) {
        byteColors[byte] ??= fieldColor(index, brightness);
      }
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(frame.summary, style: theme.textTheme.titleMedium),
        Text('${frame.protocol} · ${frame.bytes.length} bytes', style: theme.textTheme.bodySmall),
        if (frame.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('⚠ ${frame.error}', style: TextStyle(color: theme.colorScheme.error)),
          ),
        if (widget.showActions) _actions(frame),
        const SizedBox(height: 12),
        if (frame.bytes.isNotEmpty)
          Card.outlined(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: _HexGrid(bytes: frame.bytes, byteColors: byteColors, selected: _selected, onTapByte: _selectByte),
            ),
          ),
        if (frame.wire != null) ...[
          const SizedBox(height: 12),
          Card.outlined(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('On the wire', style: theme.textTheme.titleSmall),
                  Text('drawn from these bytes, not measured', style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
                  WireView(trace: frame.wire!),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        for (final (index, field) in frame.fields.indexed) _fieldTile(field, 0, fieldColor(index, brightness).withValues(alpha: 1)),
        if (frame.fields.isEmpty && frame.bytes.isNotEmpty) SelectableText(hexDump(frame.bytes), style: monospace),
      ],
    );
  }

  Widget _actions(Frame frame) {
    final learnId = learnToolFor(frame.protocol);
    final redecode = frame.redecode;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(spacing: 8, children: [
        if (redecode != null)
          OutlinedButton.icon(
            icon: const Icon(Icons.science_outlined, size: 18),
            label: const Text('What if…'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FrameEditor(frame: frame, redecode: redecode))),
          ),
        if (learnId != null)
          OutlinedButton.icon(
            icon: const Icon(Icons.menu_book_outlined, size: 18),
            label: const Text('Learn'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => Scaffold(appBar: AppBar(title: Text('Learn · ${frame.protocol}')), body: LearnView(toolId: learnId)),
            )),
          ),
      ]),
    );
  }

  Widget _fieldTile(Field field, int depth, Color color) {
    final theme = Theme.of(context);
    final isSelected = identical(field, _selected);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          key: _tileKeys.putIfAbsent(field, GlobalKey.new),
          color: isSelected ? theme.colorScheme.primaryContainer : Colors.transparent,
          child: InkWell(
            onTap: () => setState(() => _selected = isSelected ? null : field),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: depth * 16.0),
                  Container(width: 4, color: color),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(field.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                              Text(
                                field.length == 0 ? '@${field.offset}' : '@${field.offset}+${field.length}',
                                style: monospace.copyWith(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                          SelectableText(field.value, style: monospace),
                          if (field.note.isNotEmpty) Text(field.note, style: theme.textTheme.bodySmall),
                          for (final offset in {for (final child in field.children) if (child.isBits) child.offset})
                            if (offset < widget.frame.bytes.length)
                              _BitMap(
                                value: widget.frame.bytes[offset],
                                bits: [for (final child in field.children) if (child.isBits && child.offset == offset) child],
                                selected: _selected,
                              ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        for (final child in field.children) _fieldTile(child, depth + 1, color),
      ],
    );
  }
}

class _HexGrid extends StatelessWidget {
  const _HexGrid({required this.bytes, required this.byteColors, required this.selected, required this.onTapByte});

  final List<int> bytes;
  final List<Color?> byteColors;
  final Field? selected;
  final ValueChanged<int> onTapByte;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Cell size follows the font and the phone's text size, so "0a" always
    // fits (a fixed width broke at large text sizes).
    final charWidth = (TextPainter(
      text: const TextSpan(text: '0', style: monospace),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: TextDirection.ltr,
    )..layout()).width;
    final cellWidth = charWidth * 2 + 10;
    final selected = this.selected;
    // A bit field lights up the byte it lives in; other zero-length fields
    // (values only known on the wire, like the CAN CRC) light up nothing.
    bool isSelected(int index) => selected != null && index >= selected.offset && index < (selected.isBits ? selected.offset + 1 : selected.end);
    const bytesPerRow = 8;
    final faint = monospace.copyWith(color: colors.onSurfaceVariant);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var start = 0; start < bytes.length; start += bytesPerRow)
            Row(
              children: [
                SizedBox(width: charWidth * 4 + 12, child: Text(start.toRadixString(16).padLeft(4, '0'), style: faint)),
                for (var index = start; index < start + bytesPerRow; index++)
                  if (index < bytes.length)
                    GestureDetector(
                      onTap: () => onTapByte(index),
                      child: Container(
                        width: cellWidth,
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isSelected(index) ? colors.primary : byteColors[index],
                        ),
                        child: Text(
                          toHex([bytes[index]]),
                          style: isSelected(index)
                              ? monospace.copyWith(color: colors.onPrimary, fontWeight: FontWeight.bold)
                              : monospace,
                        ),
                      ),
                    )
                  else
                    SizedBox(width: cellWidth),
                const SizedBox(width: 10),
                Text(toPrintable(bytes.sublist(start, (start + bytesPerRow).clamp(0, bytes.length))), style: faint),
              ],
            ),
        ],
      ),
    );
  }
}

/// One byte as 8 boxes, bit 7 on the left like a datasheet register table,
/// each bit field shaded over the bits it owns.
class _BitMap extends StatelessWidget {
  const _BitMap({required this.value, required this.bits, required this.selected});

  final int value;
  final List<Field> bits;
  final Field? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    Field? ownerOf(int bit) {
      for (final field in bits) {
        if (bit >= field.bitShift! && bit < field.bitShift! + field.bitWidth) return field;
      }
      return null;
    }

    final cellWidth = 30.0 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (var bit = 7; bit >= 0; bit--)
                () {
                  final owner = ownerOf(bit);
                  final ownerIndex = owner == null ? -1 : bits.indexOf(owner);
                  final isSelected = owner != null && identical(owner, selected);
                  return Container(
                    width: cellWidth,
                    margin: const EdgeInsets.only(right: 2),
                    decoration: BoxDecoration(
                      color: isSelected ? colors.primary : owner == null ? null : fieldColor(ownerIndex, theme.brightness),
                      border: Border.all(color: colors.outlineVariant),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Column(children: [
                      Text('$bit', style: monospace.copyWith(fontSize: 9, color: isSelected ? colors.onPrimary : colors.onSurfaceVariant)),
                      Text('${(value >> bit) & 1}', style: monospace.copyWith(fontWeight: FontWeight.bold, color: isSelected ? colors.onPrimary : null)),
                    ]),
                  );
                }(),
            ]),
          ),
          const SizedBox(height: 4),
          for (final (index, field) in bits.indexed)
            Row(children: [
              Container(width: 10, height: 10, margin: const EdgeInsets.only(right: 6), color: fieldColor(index, theme.brightness).withValues(alpha: 1)),
              Flexible(
                child: Text(
                  '${field.bitWidth == 1 ? 'bit ${field.bitShift}' : 'bits ${field.bitShift! + field.bitWidth - 1}–${field.bitShift}'}  ${field.name} = ${field.value}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ]),
        ],
      ),
    );
  }
}

/// "What if": edit the bytes and watch the same decoder explain them. Break
/// a CRC, change a length, flip a flag bit, and see what the receiver would
/// make of it.
class FrameEditor extends StatefulWidget {
  const FrameEditor({super.key, required this.frame, required this.redecode});

  final Frame frame;
  final Frame Function(Uint8List bytes) redecode;

  @override
  State<FrameEditor> createState() => _FrameEditorState();
}

class _FrameEditorState extends State<FrameEditor> {
  late final _input = TextEditingController(text: toHex(widget.frame.bytes));
  late Frame _decoded = widget.frame;
  String? _inputError;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _changed(String text) {
    try {
      final bytes = parseHex(text);
      setState(() {
        _decoded = widget.redecode(bytes);
        _inputError = null;
      });
    } on FormatException catch (error) {
      setState(() => _inputError = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('What if · ${widget.frame.protocol}'),
        actions: [
          IconButton(tooltip: 'Back to the original bytes', icon: const Icon(Icons.restart_alt), onPressed: () {
            _input.text = toHex(widget.frame.bytes);
            _changed(_input.text);
          }),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: TextField(
              controller: _input,
              style: monospace,
              minLines: 2,
              maxLines: 5,
              onChanged: _changed,
              decoration: InputDecoration(
                labelText: 'Bytes (hex)',
                helperText: 'Change a byte: break the CRC, flip a flag, cut the frame short.',
                helperMaxLines: 2,
                errorText: _inputError,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(child: FrameView(frame: _decoded, showActions: false)),
        ],
      ),
    );
  }
}
