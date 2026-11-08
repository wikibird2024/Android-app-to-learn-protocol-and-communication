import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// The mDNS group 224.0.0.251:5353. Every device on the LAN listens here
/// and answers for its own names. Set up the way the Flutter team's
/// multicast_dns package does it (port 5353 shared, joined on every IPv4
/// interface), but the bytes come to us, so the Inside view can show them.
class MdnsSocket {
  MdnsSocket._(this._socket) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket.receive();
      if (datagram != null) _datagrams.add((bytes: datagram.data, from: datagram.address));
    }, onDone: _datagrams.close);
  }

  static final group = InternetAddress('224.0.0.251');
  static const port = 5353;

  /// Android also needs a Wi-Fi multicast lock held (MainActivity
  /// `multicastLock`), or the radio drops multicast packets.
  static Future<MdnsSocket> open() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true, reusePort: true, ttl: 255);
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    for (final interface in interfaces) {
      try {
        socket.joinMulticast(group, interface);
      } on SocketException {
        // Some interfaces (cellular) refuse multicast; the Wi-Fi one is what matters.
      }
    }
    return MdnsSocket._(socket);
  }

  final RawDatagramSocket _socket;
  final _datagrams = StreamController<({Uint8List bytes, InternetAddress from})>.broadcast();

  Stream<({Uint8List bytes, InternetAddress from})> get datagrams => _datagrams.stream;

  void send(Uint8List bytes) => _socket.send(bytes, group, port);

  void close() => _socket.close();
}
