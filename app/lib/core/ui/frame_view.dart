import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../bytes/hex.dart';
import '../inspect/frame.dart';

/// The Inside view of one frame: the bytes as a hex grid, and the fields
/// that explain them. Like ImHex, every top-level field has its own color
/// in both the grid and the list; like Wireshark, tapping a field
/// highlights its bytes and tapping a byte selects its field.
class FrameView extends StatefulWidget {
  const FrameView({super.key, required this.frame});

  final Frame frame;

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
        const SizedBox(height: 12),
        if (frame.bytes.isNotEmpty)
          Card.outlined(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: _HexGrid(bytes: frame.bytes, byteColors: byteColors, selected: _selected, onTapByte: _selectByte),
            ),
          ),
        const SizedBox(height: 12),
        for (final (index, field) in frame.fields.indexed) _fieldTile(field, 0, fieldColor(index, brightness).withValues(alpha: 1)),
        if (frame.fields.isEmpty && frame.bytes.isNotEmpty) SelectableText(hexDump(frame.bytes), style: monospace),
      ],
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
    // A bit field (length 0) still lights up the byte it lives in.
    bool isSelected(int index) => selected != null && index >= selected.offset && index < (selected.length == 0 ? selected.offset + 1 : selected.end);
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
