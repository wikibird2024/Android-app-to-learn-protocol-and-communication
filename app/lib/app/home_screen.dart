import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../tools/tool_catalog.dart';

/// Tools grouped by layer. Each group has a pinned header (like Android
/// Settings), so a long list never hides which group you are in, and a
/// header can't be mistaken for a tool.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _query = '';

  bool _matches(ToolInfo tool) {
    if (_query.isEmpty) return true;
    final text = '${tool.id} ${tool.name} ${tool.oneLine} ${tool.layer.title}'.toLowerCase();
    return text.contains(_query);
  }

  @override
  Widget build(BuildContext context) {
    final groups = [
      for (final layer in ToolLayer.values) (layer, toolCatalog.where((tool) => tool.layer == layer && _matches(tool)).toList()),
    ].where((group) => group.$2.isNotEmpty).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Protocol Lab')),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            sliver: SliverToBoxAdapter(
              child: SearchBar(
                hintText: 'Search ${toolCatalog.length} tools',
                leading: const Icon(Icons.search),
                elevation: const WidgetStatePropertyAll(0),
                onChanged: (text) => setState(() => _query = text.trim().toLowerCase()),
              ),
            ),
          ),
          if (groups.isEmpty)
            const SliverFillRemaining(hasScrollBody: false, child: Center(child: Text('No tool matches.'))),
          for (final (layer, tools) in groups)
            SliverMainAxisGroup(
              slivers: [
                PinnedHeaderSliver(child: _LayerHeader(layer: layer, count: tools.length)),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  sliver: SliverToBoxAdapter(
                    child: Card.outlined(
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (final (index, tool) in tools.indexed) ...[
                            if (index > 0) const Divider(height: 1, indent: 72),
                            _ToolTile(tool: tool),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _LayerHeader extends StatelessWidget {
  const _LayerHeader({required this.layer, required this.count});

  final ToolLayer layer;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ColoredBox(
      color: colors.surface, // opaque: tools scroll under it
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
        child: Row(
          children: [
            Icon(layer.icon, color: colors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(layer.title, style: theme.textTheme.titleLarge?.copyWith(color: colors.primary, fontWeight: FontWeight.w600)),
                  Text(layer.subtitle, style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                ],
              ),
            ),
            Text('$count', style: theme.textTheme.labelLarge?.copyWith(color: colors.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.tool});

  final ToolInfo tool;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hint = theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant);
    return ListTile(
      key: ValueKey('tool-${tool.id}'),
      leading: CircleAvatar(
        backgroundColor: colors.secondaryContainer,
        foregroundColor: colors.onSecondaryContainer,
        child: Icon(tool.icon, size: 22),
      ),
      title: Text(tool.name, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tool.oneLine),
          if (tool.needs != ToolNeeds.phone)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(children: [
                Icon(tool.needs.icon, size: 13, color: colors.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(tool.needs == ToolNeeds.learnOnly ? tool.needs.label : 'needs ${tool.needs.label}', style: hint),
              ]),
            ),
        ],
      ),
      trailing: Icon(Icons.chevron_right, color: colors.outline),
      onTap: () => context.go('/tool/${tool.id}'),
    );
  }
}
