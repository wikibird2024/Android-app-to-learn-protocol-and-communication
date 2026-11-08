/// Logic signals over time, drawn from the bytes of a frame: what a logic
/// analyzer would show on the wire. It is a drawing, not a measurement:
/// real edges have rise times, jitter and noise.
class WireTrace {
  const WireTrace({required this.lanes, required this.bitTimeNs, this.marks = const [], this.note = ''});

  /// One per signal, top to bottom: `SCL`, `SDA` or `TX`.
  final List<WireLane> lanes;

  /// Spans named above the lanes: `START`, `address 0x76`, `ACK`.
  final List<WireMark> marks;

  /// The nominal bit time, used to scale the drawing (10 µs at 100 kHz).
  final int bitTimeNs;

  /// What the drawing leaves out, for example "first 8 bytes only".
  final String note;

  int get durationNs => lanes.fold(0, (longest, lane) => lane.durationNs > longest ? lane.durationNs : longest);
}

class WireLane {
  const WireLane(this.name, this.segments);

  final String name;
  final List<WireSegment> segments;

  int get durationNs => segments.fold(0, (sum, segment) => sum + segment.durationNs);

  /// The level at [timeNs] (high = true), for tests.
  bool levelAt(int timeNs) {
    var start = 0;
    for (final segment in segments) {
      if (timeNs < start + segment.durationNs) return segment.isHigh;
      start += segment.durationNs;
    }
    return segments.isEmpty || segments.last.isHigh;
  }
}

class WireSegment {
  const WireSegment(this.isHigh, this.durationNs);

  final bool isHigh;
  final int durationNs;
}

enum WireMarkKind {
  /// A protocol part: START, address, DLC.
  field,

  /// Data bits or a data byte.
  data,

  /// The other side answered: ACK, presence pulse.
  ack,

  /// Nobody answered or "stop": NACK.
  nack,

  /// A bit added by the hardware, not by software: CAN stuff bits.
  stuff,
}

class WireMark {
  const WireMark(this.label, this.startNs, this.endNs, this.kind);

  final String label;
  final int startNs;
  final int endNs;
  final WireMarkKind kind;
}

/// Writes lanes in step: each [hold] sets some lanes and keeps the others
/// at their last level, so a two-wire bus (SCL + SDA) stays in sync.
class WireTraceBuilder {
  WireTraceBuilder(List<String> laneNames, {required this.bitTimeNs, Map<String, bool> idle = const {}})
    : _names = laneNames,
      _levels = {for (final name in laneNames) name: idle[name] ?? true},
      _segments = {for (final name in laneNames) name: <WireSegment>[]};

  final int bitTimeNs;
  final List<String> _names;
  final Map<String, bool> _levels;
  final Map<String, List<WireSegment>> _segments;
  final _marks = <WireMark>[];
  int timeNs = 0;

  void hold(Map<String, bool> levels, int durationNs) {
    _levels.addAll(levels);
    for (final name in _names) {
      final segments = _segments[name]!;
      final isHigh = _levels[name]!;
      if (segments.isNotEmpty && segments.last.isHigh == isHigh) {
        segments[segments.length - 1] = WireSegment(isHigh, segments.last.durationNs + durationNs);
      } else {
        segments.add(WireSegment(isHigh, durationNs));
      }
    }
    timeNs += durationNs;
  }

  /// Names the span from [startNs] to now.
  void mark(String label, int startNs, [WireMarkKind kind = WireMarkKind.field]) => _marks.add(WireMark(label, startNs, timeNs, kind));

  WireTrace build({String note = ''}) => WireTrace(
    lanes: [for (final name in _names) WireLane(name, List.unmodifiable(_segments[name]!))],
    marks: List.unmodifiable(_marks),
    bitTimeNs: bitTimeNs,
    note: note,
  );
}
