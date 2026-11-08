import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../inspect/wire_trace.dart';

/// A logic-analyzer style drawing of a [WireTrace]: one row per signal,
/// named spans above (START, address, ACK), stuff bits shaded. Scrolls
/// sideways; +/- zoom.
class WireView extends StatefulWidget {
  const WireView({super.key, required this.trace});

  final WireTrace trace;

  @override
  State<WireView> createState() => _WireViewState();
}

class _WireViewState extends State<WireView> {
  double _pixelsPerBit = 18;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trace = widget.trace;
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final labelStyle = monospace.copyWith(fontSize: 10 * textScale);
    final layout = _layoutMarks(trace, _pixelsPerBit / trace.bitTimeNs, labelStyle);
    final laneHeight = 34.0 * math.max(1, textScale);
    final markRowHeight = 16.0 * math.max(1, textScale);
    final height = layout.rowCount * markRowHeight + trace.lanes.length * laneHeight + 8;
    final width = _labelWidth + trace.durationNs * _pixelsPerBit / trace.bitTimeNs + 16;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(trace.note, style: theme.textTheme.bodySmall)),
            IconButton(tooltip: 'Zoom out', visualDensity: VisualDensity.compact, icon: const Icon(Icons.zoom_out), onPressed: _pixelsPerBit > 3 ? () => setState(() => _pixelsPerBit /= 1.5) : null),
            IconButton(tooltip: 'Zoom in', visualDensity: VisualDensity.compact, icon: const Icon(Icons.zoom_in), onPressed: _pixelsPerBit < 80 ? () => setState(() => _pixelsPerBit *= 1.5) : null),
          ],
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: CustomPaint(
            size: Size(width, height),
            painter: _WirePainter(
              trace: trace,
              layout: layout,
              pixelsPerNs: _pixelsPerBit / trace.bitTimeNs,
              laneHeight: laneHeight,
              markRowHeight: markRowHeight,
              labelStyle: labelStyle,
              colors: theme.colorScheme,
              status: StatusColors.of(context),
            ),
          ),
        ),
      ],
    );
  }
}

const _labelWidth = 44.0;

class _MarkLayout {
  _MarkLayout(this.rows, this.rowCount);
  final List<int> rows;
  final int rowCount;
}

/// Puts each span label on the first row where it does not overlap the
/// one before, so short spans (a 1-bit RTR) stay readable.
_MarkLayout _layoutMarks(WireTrace trace, double pixelsPerNs, TextStyle style) {
  final rowEnds = <double>[];
  final rows = <int>[];
  for (final mark in trace.marks) {
    if (mark.kind == WireMarkKind.stuff) {
      rows.add(-1); // drawn as a shaded column, not a label row
      continue;
    }
    final start = mark.startNs * pixelsPerNs;
    final painter = TextPainter(text: TextSpan(text: mark.label, style: style), textDirection: TextDirection.ltr)..layout();
    final end = math.max(mark.endNs * pixelsPerNs, start + painter.width + 4);
    var row = rowEnds.indexWhere((rowEnd) => rowEnd <= start);
    if (row < 0) {
      row = rowEnds.length;
      rowEnds.add(end);
    } else {
      rowEnds[row] = end;
    }
    rows.add(row);
  }
  return _MarkLayout(rows, math.max(1, rowEnds.length));
}

class _WirePainter extends CustomPainter {
  _WirePainter({
    required this.trace,
    required this.layout,
    required this.pixelsPerNs,
    required this.laneHeight,
    required this.markRowHeight,
    required this.labelStyle,
    required this.colors,
    required this.status,
  });

  final WireTrace trace;
  final _MarkLayout layout;
  final double pixelsPerNs;
  final double laneHeight;
  final double markRowHeight;
  final TextStyle labelStyle;
  final ColorScheme colors;
  final StatusColors status;

  Color _markColor(WireMarkKind kind) => switch (kind) {
    WireMarkKind.field => colors.primary,
    WireMarkKind.data => colors.tertiary,
    WireMarkKind.ack => status.ok,
    WireMarkKind.nack => colors.error,
    WireMarkKind.stuff => status.warn,
  };

  void _text(Canvas canvas, String text, Offset at, Color color, {double? maxWidth}) {
    final painter = TextPainter(text: TextSpan(text: text, style: labelStyle.copyWith(color: color)), textDirection: TextDirection.ltr, maxLines: 1)
      ..layout(maxWidth: maxWidth ?? double.infinity);
    painter.paint(canvas, at);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final lanesTop = layout.rowCount * markRowHeight + 4;
    final lanesBottom = lanesTop + trace.lanes.length * laneHeight;
    double x(int ns) => _labelWidth + ns * pixelsPerNs;

    // Stuff bits: a shaded column across every lane.
    for (final mark in trace.marks.where((mark) => mark.kind == WireMarkKind.stuff)) {
      canvas.drawRect(Rect.fromLTRB(x(mark.startNs), lanesTop, x(mark.endNs), lanesBottom), Paint()..color = status.warn.withValues(alpha: 0.25));
    }

    // Span labels with a bracket line under each.
    for (final (index, mark) in trace.marks.indexed) {
      final row = layout.rows[index];
      if (row < 0) continue;
      final top = row * markRowHeight;
      final color = _markColor(mark.kind);
      final bracket = Paint()
        ..color = color.withValues(alpha: 0.6)
        ..strokeWidth = 1;
      final left = x(mark.startNs) + 1;
      final right = x(mark.endNs) - 1;
      canvas.drawLine(Offset(left, top + markRowHeight - 2), Offset(right, top + markRowHeight - 2), bracket);
      canvas.drawLine(Offset(left, top + markRowHeight - 5), Offset(left, top + markRowHeight - 2), bracket);
      canvas.drawLine(Offset(right, top + markRowHeight - 5), Offset(right, top + markRowHeight - 2), bracket);
      _text(canvas, mark.label, Offset(left + 1, top), color);
      // A faint guide down through the lanes at each span start.
      canvas.drawLine(Offset(left - 1, lanesTop), Offset(left - 1, lanesBottom), Paint()..color = colors.outlineVariant.withValues(alpha: 0.5));
    }

    final signal = Paint()
      ..color = colors.onSurface
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    for (final (index, lane) in trace.lanes.indexed) {
      final top = lanesTop + index * laneHeight;
      final high = top + 6;
      final low = top + laneHeight - 8;
      _text(canvas, lane.name, Offset(0, top + laneHeight / 2 - 7), colors.onSurfaceVariant, maxWidth: _labelWidth - 4);
      final path = Path();
      var time = 0;
      double? lastY;
      for (final segment in lane.segments) {
        final y = segment.isHigh ? high : low;
        if (lastY == null) {
          path.moveTo(x(time), y);
        } else if (lastY != y) {
          path.lineTo(x(time), y); // vertical edge
        }
        time += segment.durationNs;
        path.lineTo(x(time), y);
        lastY = y;
      }
      canvas.drawPath(path, signal);
      canvas.drawLine(Offset(_labelWidth, top + laneHeight - 1), Offset(size.width, top + laneHeight - 1), Paint()..color = colors.outlineVariant.withValues(alpha: 0.4));
    }
  }

  @override
  bool shouldRepaint(_WirePainter old) => old.trace != trace || old.pixelsPerNs != pixelsPerNs || old.colors != colors;
}
