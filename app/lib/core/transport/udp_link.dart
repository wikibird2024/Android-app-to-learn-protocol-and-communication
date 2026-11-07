import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'link.dart';

/// UDP to one peer. Datagrams from other senders are dropped, so the
/// stream only carries the device's answers.
class UdpLink implements Link {
  UdpLink._(this._socket, this._peer, this._peerPort)
    : description =
          'udp ${_peer.address}:$_peerPort (local ${_socket.port})' {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket.receive();
      if (datagram == null) return;
      if (datagram.address == _peer && datagram.port == _peerPort) {
        _incoming.add(datagram.data);
      }
    }, onDone: _incoming.close);
  }

  /// Resolves [host] and binds a local port ([localPort] 0 = any).
  static Future<UdpLink> open(String host, int port, {int localPort = 0}) async {
    final addresses = await InternetAddress.lookup(host);
    final peer = addresses.firstWhere(
      (address) => address.type == InternetAddressType.IPv4,
      orElse: () => addresses.first,
    );
    final socket = await RawDatagramSocket.bind(
      peer.type == InternetAddressType.IPv4
          ? InternetAddress.anyIPv4
          : InternetAddress.anyIPv6,
      localPort,
    );
    return UdpLink._(socket, peer, port);
  }

  final RawDatagramSocket _socket;
  final InternetAddress _peer;
  final int _peerPort;
  final _incoming = StreamController<Uint8List>.broadcast();

  @override
  final String description;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List bytes) async {
    final sentCount = _socket.send(bytes, _peer, _peerPort);
    if (sentCount != bytes.length) {
      throw const SocketException('UDP send buffer full');
    }
  }

  @override
  Future<void> close() async => _socket.close();
}
