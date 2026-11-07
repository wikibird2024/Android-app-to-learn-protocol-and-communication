import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../tools/tool_catalog.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Protocol Lab')),
      body: ListView(
        children: [
          for (final layer in ToolLayer.values) ...[
            ListTile(
              title: Text(layer.title, style: Theme.of(context).textTheme.titleMedium),
              subtitle: Text(layer.subtitle),
            ),
            for (final tool in toolCatalog.where((tool) => tool.layer == layer))
              ListTile(
                key: ValueKey('tool-${tool.id}'),
                leading: Icon(tool.icon),
                title: Text(tool.name),
                subtitle: Text(tool.oneLine),
                trailing: tool.needs == ToolNeeds.phone
                    ? null
                    : Chip(label: Text(tool.needs.label), visualDensity: VisualDensity.compact),
                onTap: () => context.go('/tool/${tool.id}'),
              ),
          ],
        ],
      ),
    );
  }
}
