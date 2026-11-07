import 'dart:async';
import 'dart:typed_data';

import '../../core/inspect/frame.dart';
import '../../core/log/session_log.dart';
import '../../core/transport/link.dart';
import 'modbus_codec.dart';

enum ModbusMode { rtu, tcp }

/// Thrown when the device answers with an exception code.
class ModbusException implements Exception {
  const ModbusException(this.code);
  final int code;

  @override
  String toString() => 'Modbus exception $code: ${modbusExceptionCodes[code] ?? 'unknown'}';
}

/// A Modbus master (client): one request on the wire at a time, as RS-485
/// requires (a half-duplex bus has one talker). TCP could pipeline with
/// transaction ids, but one at a time keeps the log easy to read.
class ModbusMaster {
  ModbusMaster({
    required this.link,
    required this.log,
    required this.mode,
    this.timeout = const Duration(seconds: 1),
  }) {
    _subscription = link.incoming.listen(_onBytes);
  }

  final Link link;
  final SessionLog log;
  final ModbusMode mode;
  final Duration timeout;

  late final StreamSubscription<Uint8List> _subscription;
  var _buffer = Uint8List(0);
  var _nextTransactionId = 1;
  Completer<Uint8List>? _waiting;
  int? _waitingTransactionId;
  Future<void> _queue = Future.value();

  /// Sends [request] and returns the answer. Throws [ModbusException] for
  /// an exception reply, [TimeoutException] when the device is silent and
  /// [FormatException] for a bad CRC or a mixed-up reply.
  Future<ModbusResponse> send(ModbusRequest request) {
    final result = _queue.then((_) => _sendNow(request));
    _queue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<ModbusResponse> _sendNow(ModbusRequest request) async {
    final transactionId = _nextTransactionId;
    _nextTransactionId = (_nextTransactionId + 1) & 0xffff;
    final bytes = mode == ModbusMode.rtu ? encodeModbusRtu(request) : encodeModbusTcp(request, transactionId);
    log.sent(_decode(bytes, isRequest: true).frame);
    _buffer = Uint8List(0);

    // RTU broadcast (unit 0): every slave obeys, none answers.
    if (mode == ModbusMode.rtu && request.unitId == 0) {
      await link.send(bytes);
      return ModbusResponse(unitId: 0, functionCode: request.function.code);
    }

    final waiting = _waiting = Completer<Uint8List>();
    _waitingTransactionId = transactionId;
    try {
      await link.send(bytes);
      final reply = await waiting.future.timeout(timeout);
      final decoded = _decode(reply, isRequest: false);
      log.received(decoded.frame);
      final response = decoded.response;
      if (response == null) throw FormatException(decoded.frame.error ?? 'bad reply');
      if (response.unitId != request.unitId || response.functionCode != request.function.code) {
        throw FormatException('reply is for unit ${response.unitId} function ${response.functionCode}');
      }
      if (response.exceptionCode != null) throw ModbusException(response.exceptionCode!);
      return response;
    } on TimeoutException {
      log.note('no reply in ${timeout.inMilliseconds} ms'
          '${_buffer.isEmpty ? '' : ' (${_buffer.length} bytes of a partial frame)'}');
      rethrow;
    } finally {
      _waiting = null;
      _waitingTransactionId = null;
    }
  }

  ModbusDecoded _decode(Uint8List bytes, {required bool isRequest}) => mode == ModbusMode.rtu
      ? decodeModbusRtu(bytes, isRequest: isRequest)
      : decodeModbusTcp(bytes, isRequest: isRequest);

  void _onBytes(Uint8List chunk) {
    _buffer = Uint8List.fromList([..._buffer, ...chunk]);
    while (true) {
      final length = mode == ModbusMode.rtu ? rtuResponseLength(_buffer) : tcpFrameLength(_buffer);
      if (length == null || _buffer.length < length) return;
      final frame = Uint8List.sublistView(_buffer, 0, length);
      _buffer = Uint8List.fromList(_buffer.sublist(length));
      final waiting = _waiting;
      final isOurs = waiting != null &&
          !waiting.isCompleted &&
          (mode == ModbusMode.rtu || (frame[0] << 8 | frame[1]) == _waitingTransactionId);
      if (isOurs) {
        waiting.complete(Uint8List.fromList(frame));
      } else {
        log.received(Frame.raw('Modbus', Uint8List.fromList(frame), summary: 'reply nobody waits for (late or noise)'));
      }
    }
  }

  Future<void> close() async {
    await _subscription.cancel();
    await link.close();
  }
}
