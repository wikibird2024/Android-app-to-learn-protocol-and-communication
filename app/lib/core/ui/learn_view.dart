import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';

/// The Learn tab: a short mental-model note (diagram, frame layout, knobs,
/// gotchas) from `assets/learn/<toolId>.txt`.
class LearnView extends StatelessWidget {
  const LearnView({super.key, required this.toolId});

  final String toolId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: rootBundle.loadString('assets/learn/$toolId.txt'),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Center(child: Text('No notes for this tool yet.'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(snapshot.data!, style: monospace),
          ),
        );
      },
    );
  }
}
