import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/core/log/session_log.dart';
import 'package:protocol_lab/core/transport/link.dart';
import 'package:protocol_lab/protocols/coap/coap_client.dart';
import 'package:protocol_lab/protocols/coap/coap_codec.dart';

void main() {
  test('piggybacked response after one lost request', () {
    fakeAsync((async) {
      final link = FakeLink();
      var requestCount = 0;
      link.onSend = (bytes) {
        final request = decodeCoap(bytes).message!;
        if (request.type != CoapType.confirmable) return;
        requestCount++;
        if (requestCount == 1) return; // first one "lost"
        scheduleMicrotask(() => link.deliver(encodeCoap(CoapMessage(
          type: CoapType.acknowledgement,
          code: 0x45,
          messageId: request.messageId,
          token: request.token,
          payload: Uint8List.fromList(utf8.encode('21.5')),
        ))));
      };
      final client = CoapClient(link: link, log: SessionLog(), random: Random(1));
      CoapMessage? response;
      client.request(method: 1, path: '/temp').listen((message) => response = message);
      async.elapse(const Duration(seconds: 4));
      expect(requestCount, 2);
      expect(utf8.decode(response!.payload), '21.5');
    });
  });

  test('separate response gets an ACK from us', () async {
    final link = FakeLink();
    final acks = <int>[];
    link.onSend = (bytes) {
      final message = decodeCoap(bytes).message!;
      if (message.type == CoapType.acknowledgement) {
        acks.add(message.messageId);
        return;
      }
      scheduleMicrotask(() {
        link.deliver(encodeCoap(CoapMessage(type: CoapType.acknowledgement, code: 0, messageId: message.messageId, token: Uint8List(0))));
        link.deliver(encodeCoap(CoapMessage(type: CoapType.confirmable, code: 0x45, messageId: 777, token: message.token)));
      });
    };
    final client = CoapClient(link: link, log: SessionLog());
    final response = await client.request(method: 1, path: 'slow').first;
    expect(response.code, 0x45);
    expect(acks, [777]);
  });

  test('silent server: gives up after 4 resends', () {
    fakeAsync((async) {
      final link = FakeLink();
      var sends = 0;
      link.onSend = (_) => sends++;
      final client = CoapClient(link: link, log: SessionLog(), random: Random(2));
      Object? error;
      client.request(method: 1, path: 'x').listen(null, onError: (Object caught) => error = caught);
      async.elapse(const Duration(seconds: 100));
      expect(sends, 5);
      expect(error, isA<TimeoutException>());
    });
  });
}
