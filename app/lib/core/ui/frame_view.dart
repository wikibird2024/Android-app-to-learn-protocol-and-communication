import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../bytes/hex.dart';
import '../inspect/frame.dart';

/// The Inside view of one frame: the bytes as a hex grid, and the fields
/// that explain them. Tapping a field highlights its bytes, so the user
/// sees exactly which bytes carry which meaning.
class FrameView extends StatefulWidget {
  const FrameView({super.key, required this.frame});

  final Frame frame;

  @override
  State<FrameView> createState() => _FrameViewState();
}

class _FrameViewState extends State<FrameView> {
  Field? _selected;

  @override
  Widget build(BuildContext context) {
    final frame = widget.frame;
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(frame.summary, style: Theme.of(context).textTheme.titleMedium),
        Text('${frame.protocol} · ${frame.bytes.length} bytes', style: Theme.of(context).textTheme.bodySmall),
        if (frame.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('⚠ ${frame.error}', style: TextStyle(color: colors.error)),
          ),
        const SizedBox(height: 12),
        _HexGrid(bytes: frame.bytes, selected: _selected),
        const SizedBox(height: 12),
        for (final field in frame.fields) _fieldTile(field, 0),
        if (frame.fields.isEmpty && frame.bytes.isNotEmpty)
          SelectableText(hexDump(frame.bytes), style: monospace),
      ],
    );
  }

  Widget _fieldTile(Field field, int depth) {
    final isSelected = identical(field, _selected);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: isSelected ? Theme.of(context).colorScheme.primaryContainer : Colors.transparent,
          child: InkWell(
            onTap: () => setState(() => _selected = isSelected ? null : field),
            child: Padding(
              padding: EdgeInsets.fromLTRB(8.0 + depth * 16, 6, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(field.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Text(
                        field.length == 0 ? '@${field.offset}' : '@${field.offset}+${field.length}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  SelectableText(field.value, style: monospace),
                  if (field.note.isNotEmpty)
                    Text(field.note, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ),
        ),
        for (final child in field.children) _fieldTile(child, depth + 1),
      ],
    );
  }
}

class _HexGrid extends StatelessWidget {
  const _HexGrid({required this.bytes, required this.selected});

  final List<int> bytes;
  final Field? selected;

  @override
  Widget build(BuildContext context) {
    final highlight = Theme.of(context).colorScheme.primaryContainer;
    const bytesPerRow = 8;
    final rows = <Widget>[];
    for (var start = 0; start < bytes.length; start += bytesPerRow) {
      final end = (start + bytesPerRow).clamp(0, bytes.length);
      rows.add(Row(
        children: [
          SizedBox(width: 44, child: Text(start.toRadixString(16).padLeft(4, '0'), style: monospace.copyWith(color: Theme.of(context).hintColor))),
          for (var index = start; index < end; index++)
            Container(
              width: 26,
              alignment: Alignment.center,
              color: selected != null && index >= selected!.offset && index < selected!.end ? highlight : null,
              child: Text(toHex([bytes[index]]), style: monospace),
            ),
          const SizedBox(width: 8),
          Text(toPrintable(bytes.sublist(start, end)), style: monospace.copyWith(color: Theme.of(context).hintColor)),
        ],
      ));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }
}
