import 'package:flutter/material.dart';

import '../log/log_export.dart';
import '../log/session_log.dart';
import 'learn_view.dart';
import 'log_actions.dart';
import 'log_view.dart';

/// Every tool has the same four tabs, so moving between protocols feels the
/// same: set it up, use it, look inside, read the mental model.
///
///   Configure │ Talk │ Inside │ Learn
class ToolScaffold extends StatelessWidget {
  const ToolScaffold({
    super.key,
    required this.toolId,
    required this.title,
    required this.log,
    required this.configure,
    required this.talk,
    this.pcapLink,
    this.status,
  });

  final String toolId;
  final String title;
  final SessionLog log;
  final Widget configure;
  final Widget talk;
  final PcapLink? pcapLink;

  /// Short connection state under the title, for example `connected`.
  final String? status;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title),
              if (status != null) Text(status!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          actions: [LogActions(log: log, name: toolId, pcapLink: pcapLink)],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Configure'),
              Tab(text: 'Talk'),
              Tab(text: 'Inside'),
              Tab(text: 'Learn'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            configure,
            talk,
            LogView(log: log, emptyText: 'Every frame sent and received shows up here.\nTap one to see its bytes.'),
            LearnView(toolId: toolId),
          ],
        ),
      ),
    );
  }
}
