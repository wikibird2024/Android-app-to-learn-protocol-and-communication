import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/inspect/frame.dart';
import '../core/log/session_log.dart';
import '../core/transport/link.dart';

/// A raw byte link plus its log, for tools with no protocol codec (TCP,
/// UDP, serial terminal): every chunk sent and received becomes a log line.
class LinkSession extends ChangeNotifier {
  LinkSession({required this.protocol});

  final String protocol;
  final log = SessionLog();
  Link? _link;
  StreamSubscription<Uint8List>? _subscription;
  bool isBusy = false;

  Link? get link => _link;
  bool get isOpen => _link != null;

  Future<void> open(Future<Link> Function() opener) async {
    await close();
    isBusy = true;
    notifyListeners();
    try {
      final link = await opener();
      _link = link;
      _subscription = link.incoming.listen(
        (bytes) => log.received(Frame.raw(protocol, bytes)),
        onDone: () {
          log.note('closed by the other side');
          _drop();
        },
        onError: (Object error) => log.note('error: $error'),
      );
      log.note('opened ${link.description}');
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<void> send(Uint8List bytes) async {
    final link = _link;
    if (link == null) throw StateError('not connected');
    await link.send(bytes);
    log.sent(Frame.raw(protocol, bytes));
  }

  void _drop() {
    _subscription = null;
    _link = null;
    notifyListeners();
  }

  Future<void> close() async {
    final link = _link;
    if (link == null) return;
    await _subscription?.cancel();
    _drop();
    await link.close();
    log.note('closed');
  }

  @override
  void dispose() {
    unawaited(close());
    log.dispose();
    super.dispose();
  }
}
