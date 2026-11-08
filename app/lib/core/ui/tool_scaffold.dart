import 'package:flutter/material.dart';

import '../log/log_export.dart';
import '../../app/theme.dart';
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
    this.isConnected,
    this.onConnect,
    this.isBusy = false,
  });

  final String toolId;
  final String title;
  final SessionLog log;
  final Widget configure;
  final Widget talk;
  final PcapLink? pcapLink;

  /// Short connection state under the title, for example `connected`.
  final String? status;

  /// Shows a green / grey dot before [status]; null for tools with no
  /// connection (HTTP, mDNS).
  final bool? isConnected;

  /// Connect / disconnect from the app bar, like a serial terminal's plug
  /// button. Gets a context inside the tabs, so it can switch to Talk.
  /// Null hides the button.
  final void Function(BuildContext tabContext)? onConnect;

  /// Connecting or closing: the button is disabled meanwhile.
  final bool isBusy;

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
              if (status != null)
                Row(
                  children: [
                    if (isConnected != null) ...[
                      Icon(Icons.circle, size: 9, color: isConnected! ? StatusColors.of(context).ok : Theme.of(context).colorScheme.outline),
                      const SizedBox(width: 6),
                    ],
                    Flexible(child: Text(status!, style: Theme.of(context).textTheme.bodySmall, overflow: TextOverflow.ellipsis)),
                  ],
                ),
            ],
          ),
          actions: [
            if (isConnected != null && onConnect != null)
              Builder(
                builder: (tabContext) => IconButton(
                  tooltip: isConnected! ? 'Disconnect' : 'Connect',
                  icon: Icon(isConnected! ? Icons.link_off : Icons.link),
                  onPressed: isBusy ? null : () => onConnect!(tabContext),
                ),
              ),
            LogActions(log: log, name: toolId, pcapLink: pcapLink),
          ],
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
            LogView(log: log, showTools: true, emptyText: 'Every frame sent and received shows up here.\nTap one to see its bytes.'),
            LearnView(toolId: toolId),
          ],
        ),
      ),
    );
  }
}
