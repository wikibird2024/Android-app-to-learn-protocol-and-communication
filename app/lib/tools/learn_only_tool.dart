import 'package:flutter/material.dart';

import '../core/ui/learn_view.dart';

/// For protocols that need hardware we do not have yet: the notes only.
class LearnOnlyTool extends StatelessWidget {
  const LearnOnlyTool({super.key, required this.toolId, required this.title});

  final String toolId;
  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: LearnView(toolId: toolId),
  );
}
