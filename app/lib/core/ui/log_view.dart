import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../bytes/hex.dart';
import '../log/session_log.dart';
import 'frame_view.dart';

/// How the time column reads. "Since previous" is Wireshark's delta time:
/// the way to see keepalive, poll and retry timing.
enum TimeMode {
  clock('clock time'),
  sinceStart('seconds since the first line'),
  sincePrevious('seconds since the line above');

  const TimeMode(this.label);
  final String label;
}

/// True when [entry] passes the Inside filter: its direction is shown and
/// [query] (lower case) is in its summary, protocol or hex bytes.
bool logEntryMatches(LogEntry entry, Set<Direction> directions, String query) {
  if (!directions.contains(entry.direction)) return false;
  if (query.isEmpty) return true;
  final frame = entry.frame;
  return frame.summary.toLowerCase().contains(query) || frame.protocol.toLowerCase().contains(query) || toHex(frame.bytes).contains(query);
}

String formatLogTime(LogEntry entry, TimeMode mode, {DateTime? reference}) {
  String two(int value) => value.toString().padLeft(2, '0');
  final time = entry.time;
  return switch (mode) {
    TimeMode.clock => '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.${time.millisecond.toString().padLeft(3, '0')}',
    _ => '${mode == TimeMode.sincePrevious ? 'Δ' : '+'}${(time.difference(reference ?? time).inMicroseconds / 1e6).toStringAsFixed(3)}',
  };
}

/// Newest-last list of everything sent and received. Tap a line to see its
/// bytes and fields, then swipe to the next frame. [showTools] adds the
/// Wireshark-like bar: search, direction filter, time mode.
class LogView extends StatefulWidget {
  const LogView({super.key, required this.log, this.emptyText = 'Nothing sent or received yet.', this.showTools = false});

  final SessionLog log;
  final String emptyText;
  final bool showTools;

  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  final _scroll = ScrollController();
  bool _isFollowing = true;
  String _query = '';
  Set<Direction> _directions = Direction.values.toSet();
  TimeMode _timeMode = TimeMode.clock;

  bool get _isFiltered => _query.isNotEmpty || _directions.length < Direction.values.length;

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

  void _openFrame(List<LogEntry> shown, LogEntry entry) {
    final frames = [for (final item in shown) if (item.direction != Direction.note) item];
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _FramePager(entries: frames, initialIndex: frames.indexOf(entry)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.log,
      builder: (context, _) {
        final log = widget.log;
        // shortcut: filtering copies up to `capacity` (5000) entries per
        // rebuild; fine at bench rates, index incrementally if it lags.
        final shown = _isFiltered
            ? [for (var index = 0; index < log.length; index++) if (logEntryMatches(log.entryAt(index), _directions, _query)) log.entryAt(index)]
            : null;
        final count = shown?.length ?? log.length;
        LogEntry entryAt(int index) => shown?[index] ?? log.entryAt(index);
        if (_isFollowing) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
          });
        }
        return Column(
          children: [
            if (widget.showTools) _toolbar(log, count),
            if (log.isPaused || log.droppedCount > 0)
              MaterialBanner(
                content: Text('Paused · ${log.droppedCount} not shown'),
                actions: [TextButton(onPressed: () => log.isPaused = false, child: const Text('Resume'))],
              ),
            Expanded(
              child: log.length == 0
                  ? Center(child: Text(widget.emptyText, textAlign: TextAlign.center))
                  : count == 0
                  ? const Center(child: Text('No line matches the filter.'))
                  : ListView.builder(
                      controller: _scroll,
                      itemCount: count,
                      itemBuilder: (context, index) {
                        final entry = entryAt(index);
                        final reference = switch (_timeMode) {
                          TimeMode.clock => null,
                          TimeMode.sinceStart => log.entryAt(0).time,
                          TimeMode.sincePrevious => index == 0 ? entry.time : entryAt(index - 1).time,
                        };
                        return _LogTile(
                          entry: entry,
                          time: formatLogTime(entry, _timeMode, reference: reference),
                          onTap: entry.direction == Direction.note ? null : () => _openFrame(shown ?? log.entries, entry),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _toolbar(SessionLog log, int count) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'Filter: text, protocol or hex (80 01)',
                  prefixIcon: const Icon(Icons.filter_list, size: 20),
                  suffixText: _isFiltered ? '$count / ${log.length}' : null,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (text) => setState(() => _query = text.trim().toLowerCase()),
              ),
            ),
            PopupMenuButton<Direction>(
              tooltip: 'Show sent / received / notes',
              icon: Icon(Icons.swap_vert, color: _directions.length < Direction.values.length ? colors.primary : null),
              onSelected: (direction) => setState(() {
                _directions = {..._directions};
                if (!_directions.remove(direction)) _directions.add(direction);
              }),
              itemBuilder: (context) => [
                for (final direction in Direction.values)
                  CheckedPopupMenuItem(value: direction, checked: _directions.contains(direction), child: Text(direction.name)),
              ],
            ),
            IconButton(
              tooltip: 'Time: ${_timeMode.label}',
              icon: Icon(switch (_timeMode) {
                TimeMode.clock => Icons.schedule,
                TimeMode.sinceStart => Icons.timer_outlined,
                TimeMode.sincePrevious => Icons.compare_arrows,
              }),
              onPressed: () => setState(() => _timeMode = TimeMode.values[(_timeMode.index + 1) % TimeMode.values.length]),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.entry, required this.time, required this.onTap});

  final LogEntry entry;
  final String time;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = StatusColors.of(context);
    final (arrow, color) = switch (entry.direction) {
      Direction.sent => ('→', status.sent),
      Direction.received => ('←', status.received),
      Direction.note => ('•', status.note),
    };
    final hasError = entry.frame.error != null;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        // 44 dp: close to the 48 dp touch target, still dense enough for a log.
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(time, style: monospace.copyWith(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(width: 8),
              Text(arrow, semanticsLabel: entry.direction.name, style: monospace.copyWith(color: color, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.frame.summary,
                  style: monospace.copyWith(color: hasError ? theme.colorScheme.error : entry.direction == Direction.note ? status.note : null),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One frame per page: swipe (or the arrows) to walk the log like
/// Wireshark's next / previous packet.
class _FramePager extends StatefulWidget {
  const _FramePager({required this.entries, required this.initialIndex});

  final List<LogEntry> entries;
  final int initialIndex;

  @override
  State<_FramePager> createState() => _FramePagerState();
}

class _FramePagerState extends State<_FramePager> {
  late final _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int index) => _pages.animateToPage(index, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);

  @override
  Widget build(BuildContext context) {
    final entry = widget.entries[_index];
    final arrow = entry.direction == Direction.sent ? '→' : '←';
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$arrow ${entry.frame.protocol.toUpperCase()}'),
            Text('${formatLogTime(entry, TimeMode.clock)} · ${_index + 1} / ${widget.entries.length}', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          IconButton(tooltip: 'Previous frame', icon: const Icon(Icons.keyboard_arrow_up), onPressed: _index > 0 ? () => _go(_index - 1) : null),
          IconButton(tooltip: 'Next frame', icon: const Icon(Icons.keyboard_arrow_down), onPressed: _index < widget.entries.length - 1 ? () => _go(_index + 1) : null),
        ],
      ),
      body: PageView.builder(
        controller: _pages,
        itemCount: widget.entries.length,
        onPageChanged: (index) => setState(() => _index = index),
        itemBuilder: (context, index) => FrameView(frame: widget.entries[index].frame),
      ),
    );
  }
}
