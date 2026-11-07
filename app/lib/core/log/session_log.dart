import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../inspect/frame.dart';

enum Direction {
  /// Phone → device.
  sent,

  /// Device → phone.
  received,

  /// Something the app noticed: connected, timeout, error.
  note,
}

class LogEntry {
  LogEntry({
    required this.time,
    required this.direction,
    required this.frame,
  });

  final DateTime time;
  final Direction direction;
  final Frame frame;

  Uint8List get bytes => frame.bytes;
}

/// Everything a tool sent and received, newest last. One per tool screen.
/// Capped so a busy bus (CAN at 1000 frames/s) cannot fill the phone's
/// memory; the oldest entries go first.
class SessionLog extends ChangeNotifier {
  SessionLog({this.capacity = 5000, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final int capacity;
  final DateTime Function() _clock;
  final _entries = ListQueue<LogEntry>();
  bool _isPaused = false;
  int _droppedCount = 0;

  List<LogEntry> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;

  /// O(1); use this in list builders instead of copying [entries].
  LogEntry entryAt(int index) => _entries.elementAt(index);

  /// While paused, new entries are counted but not kept, so the user can
  /// read a busy log without it scrolling away.
  bool get isPaused => _isPaused;
  int get droppedCount => _droppedCount;

  set isPaused(bool value) {
    _isPaused = value;
    notifyListeners();
  }

  void sent(Frame frame) => add(Direction.sent, frame);
  void received(Frame frame) => add(Direction.received, frame);

  void note(String text) => add(
    Direction.note,
    Frame(protocol: 'note', summary: text, bytes: Uint8List(0)),
  );

  void add(Direction direction, Frame frame) {
    if (_isPaused) {
      _droppedCount++;
      notifyListeners();
      return;
    }
    _entries.addLast(LogEntry(time: _clock(), direction: direction, frame: frame));
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    _droppedCount = 0;
    notifyListeners();
  }
}
