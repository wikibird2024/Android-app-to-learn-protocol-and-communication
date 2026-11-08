import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../app/theme.dart';

/// The Learn tab: a short mental-model page (diagram, frame layout, knobs,
/// gotchas) from `assets/learn/<toolId>.md`. Prose in the normal font;
/// diagrams and byte layouts in tinted mono code boxes that scroll sideways.
class LearnView extends StatelessWidget {
  const LearnView({super.key, required this.toolId});

  final String toolId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: rootBundle.loadString('assets/learn/$toolId.md'),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Center(child: Text('No notes for this tool yet.'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        return Markdown(data: snapshot.data!, selectable: true, styleSheet: learnStyle(Theme.of(context)), padding: const EdgeInsets.fromLTRB(16, 12, 16, 32));
      },
    );
  }
}

MarkdownStyleSheet learnStyle(ThemeData theme) {
  final colors = theme.colorScheme;
  final text = theme.textTheme;
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    h1: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600, color: colors.primary),
    h2: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    h2Padding: const EdgeInsets.only(top: 16),
    em: text.titleSmall?.copyWith(color: colors.onSurfaceVariant, fontStyle: FontStyle.normal),
    p: text.bodyMedium?.copyWith(height: 1.45),
    // No backgroundColor: the code style is also used inside code boxes,
    // where a per-line background would stripe the diagram.
    code: monospace.copyWith(fontSize: 12, color: colors.onSurface),
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: colors.outlineVariant),
    ),
    tableHead: text.labelLarge,
    tableBody: text.bodyMedium,
    tableBorder: TableBorder.all(color: colors.outlineVariant, width: 0.5),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
  );
}
