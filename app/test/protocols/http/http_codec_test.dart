import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:protocol_lab/protocols/http/http_codec.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  test('request text', () {
    final bytes = encodeHttpRequest(method: 'POST', uri: Uri.parse('http://192.168.1.5:8080/api?x=1'), body: _bytes('{}'));
    expect(
      utf8.decode(bytes),
      'POST /api?x=1 HTTP/1.1\r\nHost: 192.168.1.5:8080\r\nUser-Agent: ProtocolLab/0.1\r\nConnection: close\r\n'
      'Content-Length: 2\r\n\r\n{}',
    );
  });

  test('Content-Length response', () {
    final response = parseHttpResponse(_bytes('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nhi'));
    expect(response.statusCode, 200);
    expect(response.headers['content-type'], 'text/plain');
    expect(utf8.decode(response.body), 'hi');
  });

  test('chunked response', () {
    final response = parseHttpResponse(_bytes('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n'));
    expect(utf8.decode(response.body), 'Wikipedia');
  });

  test('broken responses throw FormatException', () {
    for (final text in ['HTTP/1.1 200 OK\r\n', 'nope\r\n\r\n', 'HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nhi']) {
      expect(() => parseHttpResponse(_bytes(text)), throwsFormatException, reason: text);
    }
  });

  test('describe lists every header line', () {
    final frame = describeHttpMessage(_bytes('HTTP/1.1 404 Not Found\r\nServer: esp\r\n\r\nx'), isRequest: false);
    expect(frame.fields.map((field) => field.name), ['status line', 'Server', 'end of headers', 'body']);
    expect(frame.fields[1].offset, 24);
  });
}
