import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/inspect/frame.dart';
import '../../core/log/session_log.dart';
import '../../core/transport/link.dart';

/// The ESP32 bridge's text protocol (firmware/bridge/components/
/// bridge_protocol/bridge_protocol.h has the same description):
///
/// ```text
///   request : "<id> <command> <args...>\n"
///   reply   : {"id":7,"ok":true,"data":...}\n  or  {"id":7,"ok":false,"error":"..."}\n
///   event   : {"event":"can",...}\n  (no request; CAN frames, Zigbee joins)
/// ```
///
/// Text, so the same commands work typed by hand in a serial terminal.
class BridgeError implements Exception {
  const BridgeError(this.message);
  final String message;

  @override
  String toString() => 'bridge: $message';
}

class BridgeClient {
  BridgeClient({
    required this.link,
    required this.log,
    this.timeout = const Duration(seconds: 3),
  }) {
    _subscription = link.incoming.listen(
      _onBytes,
      onDone: _failAll,
    );
  }

  final Link link;
  final SessionLog log;
  final Duration timeout;

  late final StreamSubscription<Uint8List> _subscription;
  final _lineBuffer = BytesBuilder();
  final _pending = <int, Completer<Object?>>{};
  final _events = StreamController<Map<String, Object?>>.broadcast();
  var _nextId = 1;

  /// Events the bridge sends on its own, for example
  /// `{"event":"can","id":"123","ext":false,"rtr":false,"data":"0102"}`.
  Stream<Map<String, Object?>> get events => _events.stream;

  /// Sends one command, for example `i2c scan`, and returns the reply's
  /// `data`. Throws [BridgeError] for an error reply and
  /// [TimeoutException] when the bridge is silent.
  Future<Object?> command(String text, {Duration? timeout}) async {
    final id = _nextId;
    _nextId = _nextId >= 999999 ? 1 : _nextId + 1;
    final bytes = Uint8List.fromList(utf8.encode('$id ${text.trim()}\n'));
    final completer = _pending[id] = Completer<Object?>();
    log.sent(describeBridgeLine(bytes, isSent: true));
    try {
      await link.send(bytes);
      return await completer.future.timeout(timeout ?? this.timeout);
    } on TimeoutException {
      log.note('bridge: no reply to #$id "$text"');
      rethrow;
    } finally {
      _pending.remove(id);
    }
  }

  void _onBytes(Uint8List chunk) {
    for (final byte in chunk) {
      if (byte != 0x0a) {
        _lineBuffer.addByte(byte);
        continue;
      }
      final line = _lineBuffer.takeBytes();
      if (line.isNotEmpty) _onLine(line);
    }
  }

  void _onLine(Uint8List line) {
    log.received(describeBridgeLine(line, isSent: false));
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(line, allowMalformed: true));
    } on FormatException {
      return; // boot log or console text from the ESP32: logged, not a reply
    }
    if (json is! Map<String, Object?>) return;
    if (json['event'] is String) {
      _events.add(json);
      return;
    }
    final id = json['id'];
    final completer = id is int ? _pending[id] : null;
    if (completer == null || completer.isCompleted) return;
    if (json['ok'] == true) {
      completer.complete(json['data']);
    } else {
      completer.completeError(BridgeError('${json['error'] ?? 'failed'}'));
    }
  }

  void _failAll() {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(const BridgeError('link closed'));
    }
    _pending.clear();
  }

  Future<void> close() async {
    _failAll();
    unawaited(_subscription.cancel());
    await link.close();
  }
}

/// Inside view of one bridge line: the words of a request, or the JSON keys
/// of a reply/event.
Frame describeBridgeLine(Uint8List line, {required bool isSent}) {
  final text = utf8.decode(line, allowMalformed: true).trimRight();
  final fields = <Field>[];
  if (isSent) {
    var offset = 0;
    final words = text.split(' ');
    for (final (index, word) in words.indexed) {
      fields.add(Field(index == 0 ? 'request id' : index == 1 ? 'command' : 'argument ${index - 1}', offset, word.length, word));
      offset += word.length + 1;
    }
    fields.add(Field('end of line', line.length - 1, 1, r'\n', note: 'the bridge acts on newline'));
    return Frame(protocol: 'bridge', summary: words.skip(1).join(' '), bytes: line, fields: fields, exchange: 'bridge #${words.first}');
  }
  try {
    final json = jsonDecode(text);
    if (json is Map<String, Object?>) {
      for (final entry in json.entries) {
        final key = '"${entry.key}":';
        final offset = text.indexOf(key);
        fields.add(Field(entry.key, offset < 0 ? 0 : offset, key.length, jsonEncode(entry.value)));
      }
      final summary = json.containsKey('event')
          ? 'event ${json['event']}'
          : json['ok'] == true
          ? '#${json['id']} ok ${_short(jsonEncode(json['data']))}'
          : '#${json['id']} error ${json['error']}';
      return Frame(protocol: 'bridge', summary: summary, bytes: line, fields: fields,
          exchange: json['id'] == null ? null : 'bridge #${json['id']}', endsExchange: json['id'] != null);
    }
  } on FormatException {
    // Not JSON: fall through.
  }
  return Frame(protocol: 'console', summary: _short(text), bytes: line, fields: [Field('text', 0, line.length, text)]);
}

String _short(String text) => text.length <= 80 ? text : '${text.substring(0, 77)}...';
