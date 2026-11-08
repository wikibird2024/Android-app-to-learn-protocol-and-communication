import 'session_log.dart';

/// Where one log line sits in its request/reply exchange, for the Flow
/// view (like Wireshark's flow graph).
class ExchangeStep {
  const ExchangeStep({required this.number, required this.isFirst, required this.isLast, required this.isRetry, this.sinceStart});

  /// 1, 2, 3… in the order exchanges started.
  final int number;
  final bool isFirst;

  /// The frame that finished the exchange (the reply).
  final bool isLast;

  /// Same direction as the first frame, before any answer: a resend
  /// (CoAP CON retransmit, MQTT DUP).
  final bool isRetry;

  /// Time from the exchange's first frame; null on the first frame.
  final Duration? sinceStart;
}

class _Open {
  _Open(this.number, this.start);
  final int number;
  final LogEntry start;
  bool isAnswered = false;
}

/// Pairs log entries by [Frame.exchange]: frames with the same key belong
/// together until one with `endsExchange` closes it; the next frame with
/// that key starts a new exchange. Entries with no key map to null.
List<ExchangeStep?> pairExchanges(List<LogEntry> entries) {
  final open = <String, _Open>{};
  var count = 0;
  return [
    for (final entry in entries)
      () {
        final key = entry.frame.exchange;
        if (key == null || entry.direction == Direction.note) return null;
        final current = open[key];
        if (current == null) {
          final started = _Open(++count, entry);
          if (entry.frame.endsExchange) {
            return ExchangeStep(number: started.number, isFirst: true, isLast: true, isRetry: false);
          }
          open[key] = started;
          return ExchangeStep(number: started.number, isFirst: true, isLast: false, isRetry: false);
        }
        final isRetry = !current.isAnswered && entry.direction == current.start.direction;
        if (entry.direction != current.start.direction) current.isAnswered = true;
        if (entry.frame.endsExchange) open.remove(key);
        return ExchangeStep(
          number: current.number,
          isFirst: false,
          isLast: entry.frame.endsExchange,
          isRetry: isRetry,
          sinceStart: entry.time.difference(current.start.time),
        );
      }(),
  ];
}
