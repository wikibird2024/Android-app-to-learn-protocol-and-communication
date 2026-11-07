import 'dart:async';
import 'dart:typed_data';

/// A byte pipe to a device: TCP socket, UDP peer, USB serial port,
/// Bluetooth SPP. Codecs and tools only see this, so a tool works the same
/// over any link, and tests use [FakeLink].
abstract interface class Link {
  /// Short text for the log, for example `tcp 192.168.1.5:1883`.
  String get description;

  /// Bytes as they arrive. Chunks do not follow frame borders: a codec
  /// must join and split them. Closes when the link closes.
  Stream<Uint8List> get incoming;

  Future<void> send(Uint8List bytes);

  Future<void> close();
}

/// In-memory link for tests: [sentChunks] records what was sent,
/// [deliver] plays bytes as if the device sent them.
class FakeLink implements Link {
  FakeLink({this.description = 'fake'});

  @override
  final String description;

  final sentChunks = <Uint8List>[];
  final _incoming = StreamController<Uint8List>.broadcast();
  bool isClosed = false;

  /// Called after each send, so a test can answer like a device would.
  void Function(Uint8List bytes)? onSend;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  void deliver(List<int> bytes) => _incoming.add(Uint8List.fromList(bytes));

  @override
  Future<void> send(Uint8List bytes) async {
    if (isClosed) throw StateError('link closed');
    sentChunks.add(bytes);
    onSend?.call(bytes);
  }

  @override
  Future<void> close() async {
    isClosed = true;
    await _incoming.close();
  }
}
