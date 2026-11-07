import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../log/session_log.dart';
import 'frame_view.dart';

/// Newest-last list of everything sent and received. Tap a line to see its
/// bytes and fields.
class LogView extends StatefulWidget {
  const LogView({super.key, required this.log, this.emptyText = 'Nothing sent or received yet.'});

  final SessionLog log;
  final String emptyText;

  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  final _scroll = ScrollController();
  bool _isFollowing = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      // Follow new lines only while the user is at the bottom.
      _isFollowing = _scroll.position.pixels >= _scroll.position.maxScrollExtent - 40;
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.log,
      builder: (context, _) {
        final log = widget.log;
        if (log.length == 0) {
          return Center(child: Text(widget.emptyText, textAlign: TextAlign.center));
        }
        if (_isFollowing) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
          });
        }
        return Column(
          children: [
            if (log.isPaused || log.droppedCount > 0)
              MaterialBanner(
                content: Text('Paused · ${log.droppedCount} not shown'),
                actions: [TextButton(onPressed: () => log.isPaused = false, child: const Text('Resume'))],
              ),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                itemCount: log.length,
                itemBuilder: (context, index) => _LogTile(entry: log.entryAt(index)),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (arrow, color) = switch (entry.direction) {
      Direction.sent => ('→', colors.primary),
      Direction.received => ('←', colors.tertiary),
      Direction.note => ('•', colors.outline),
    };
    final time = entry.time;
    final stamp = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}.${time.millisecond.toString().padLeft(3, '0')}';
    final hasError = entry.frame.error != null;
    return InkWell(
      onTap: entry.direction == Direction.note
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: Text('${entry.direction.name} ${entry.frame.protocol}')),
                  body: FrameView(frame: entry.frame),
                ),
              )),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(stamp, style: monospace.copyWith(fontSize: 11, color: Theme.of(context).hintColor)),
            const SizedBox(width: 6),
            Text(arrow, style: monospace.copyWith(color: color, fontWeight: FontWeight.bold)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                entry.frame.summary,
                style: monospace.copyWith(color: hasError ? colors.error : null),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
