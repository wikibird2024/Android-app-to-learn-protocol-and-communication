import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'link.dart';

class TcpLink implements Link {
  TcpLink._(this._socket, this.description)
    : incoming = _socket.asBroadcastStream();

  /// Throws [SocketException] when the host does not answer in [timeout].
  /// [useTls] wraps the socket in TLS (MQTT 8883, HTTPS 443); the server
  /// certificate is checked against the phone's trusted roots.
  static Future<TcpLink> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
    bool useTls = false,
  }) async {
    final socket = useTls
        ? await SecureSocket.connect(host, port, timeout: timeout)
        : await Socket.connect(host, port, timeout: timeout);
    // Small frames (MQTT PINGREQ, Modbus requests) go out at once instead
    // of waiting for Nagle's algorithm to batch them.
    socket.setOption(SocketOption.tcpNoDelay, true);
    return TcpLink._(socket, '${useTls ? 'tls' : 'tcp'} $host:$port');
  }

  final Socket _socket;

  @override
  final String description;

  @override
  final Stream<Uint8List> incoming;

  Future<void> _sendQueue = Future.value();

  /// Sends run one after another: dart:io throws "StreamSink is bound to a
  /// stream" if a second add() comes while a flush() is still running, and
  /// protocol clients often answer (PUBACK) while they are still sending.
  @override
  Future<void> send(Uint8List bytes) {
    final sent = _sendQueue.then((_) async {
      _socket.add(bytes);
      await _socket.flush();
    });
    _sendQueue = sent.catchError((Object _) {});
    return sent;
  }

  @override
  Future<void> close() async {
    await _socket.close();
    _socket.destroy();
  }
}
