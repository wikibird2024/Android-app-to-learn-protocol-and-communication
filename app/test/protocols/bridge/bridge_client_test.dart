import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/log/session_log.dart';
import 'package:protocol_lab/core/transport/link.dart';
import 'package:protocol_lab/protocols/bridge/bridge_client.dart';

void main() {
  late FakeLink link;
  late BridgeClient client;

  setUp(() {
    link = FakeLink();
    client = BridgeClient(link: link, log: SessionLog(), timeout: const Duration(milliseconds: 200));
    // Answers like the firmware, split across chunks, with console noise.
    link.onSend = (bytes) {
      final words = utf8.decode(bytes).trim().split(' ');
      final id = words.first;
      final reply = switch (words[1]) {
        'i2c' => '{"id":$id,"ok":true,"data":[60,118]}',
        'fail' => '{"id":$id,"ok":false,"error":"bus busy"}',
        _ => '',
      };
      if (reply.isEmpty) return;
      scheduleMicrotask(() {
        link.deliver(utf8.encode('I (1234) boot: noise\n${reply.substring(0, 5)}'));
        link.deliver(utf8.encode('${reply.substring(5)}\n{"event":"can","id":"123","data":"01"}\n'));
      });
    };
  });

  test('reply data comes back, console text and events are separate', () async {
    final events = <Map<String, Object?>>[];
    client.events.listen(events.add);
    expect(await client.command('i2c scan'), [60, 118]);
    await pumpEventQueue();
    expect(events.single['id'], '123');
    expect(link.sentChunks.single, utf8.encode('1 i2c scan\n'));
  });

  test('error reply throws BridgeError, silence times out', () async {
    await expectLater(client.command('fail'), throwsA(isA<BridgeError>()));
    await expectLater(client.command('silent'), throwsA(isA<TimeoutException>()));
  });

  test('describe a sent line', () {
    final frame = describeBridgeLine(utf8.encode('7 i2c xfer 0x76 d0 1\n'), isSent: true);
    expect(frame.summary, 'i2c xfer 0x76 d0 1');
    expect(frame.fields.map((field) => field.name).take(3), ['request id', 'command', 'argument 1']);
  });
}
