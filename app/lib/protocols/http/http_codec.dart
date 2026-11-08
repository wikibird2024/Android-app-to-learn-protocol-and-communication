import 'dart:convert';
import 'dart:typed_data';

import '../../core/bytes/hex.dart';
import '../../core/inspect/frame.dart';

/// HTTP/1.1 (RFC 9112) by hand: it is plain text lines.
///
/// ```text
///   GET /api/status HTTP/1.1\r\n        ← request line
///   Host: 192.168.1.50\r\n              ← headers, one per line
///   \r\n                                ← empty line ends the headers
///   <body>                              ← Content-Length bytes, or chunked
/// ```
Uint8List encodeHttpRequest({
  required String method,
  required Uri uri,
  Map<String, String> headers = const {},
  Uint8List? body,
}) {
  final target = uri.hasQuery ? '${uri.path.isEmpty ? '/' : uri.path}?${uri.query}' : (uri.path.isEmpty ? '/' : uri.path);
  final isDefaultPort = (uri.scheme == 'http' && uri.port == 80) || (uri.scheme == 'https' && uri.port == 443);
  final lines = <String>[
    '$method $target HTTP/1.1',
    'Host: ${uri.host}${isDefaultPort ? '' : ':${uri.port}'}',
    'User-Agent: ProtocolLab/0.1',
    // One request per connection keeps the reply's end easy to find.
    'Connection: close',
    for (final entry in headers.entries) '${entry.key}: ${entry.value}',
    if (body != null && body.isNotEmpty) 'Content-Length: ${body.length}',
  ];
  return Uint8List.fromList([...utf8.encode('${lines.join('\r\n')}\r\n\r\n'), ...?body]);
}

class HttpResponse {
  const HttpResponse({required this.statusCode, required this.reason, required this.headers, required this.body});

  final int statusCode;
  final String reason;

  /// Lowercase names; a repeated header keeps the last value.
  final Map<String, String> headers;
  final Uint8List body;
}

/// Parses a complete response (we sent Connection: close, so the response
/// ends when the server closes). Throws [FormatException].
HttpResponse parseHttpResponse(Uint8List bytes) {
  final headerEnd = _indexOfBlankLine(bytes);
  if (headerEnd < 0) throw const FormatException('no blank line after the headers');
  final lines = latin1.decode(bytes.sublist(0, headerEnd)).split('\r\n');
  final status = RegExp(r'^HTTP/1\.[01] (\d{3}) ?(.*)$').firstMatch(lines.first);
  if (status == null) throw FormatException('bad status line "${lines.first}"');
  final headers = <String, String>{};
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon <= 0) throw FormatException('bad header line "$line"');
    headers[line.substring(0, colon).trim().toLowerCase()] = line.substring(colon + 1).trim();
  }
  var body = Uint8List.sublistView(bytes, headerEnd + 4);
  if (headers['transfer-encoding']?.toLowerCase().contains('chunked') ?? false) {
    body = decodeChunked(body);
  } else if (headers['content-length'] case final length?) {
    final count = int.tryParse(length);
    if (count == null || count > body.length) throw FormatException('Content-Length $length but ${body.length} bytes came');
    body = Uint8List.sublistView(body, 0, count);
  }
  return HttpResponse(statusCode: int.parse(status.group(1)!), reason: status.group(2)!, headers: headers, body: body);
}

/// `<size hex>\r\n<data>\r\n ... 0\r\n\r\n` → data.
Uint8List decodeChunked(Uint8List bytes) {
  final out = BytesBuilder();
  var offset = 0;
  while (true) {
    final lineEnd = _indexOf(bytes, const [13, 10], offset);
    if (lineEnd < 0) throw const FormatException('chunk size line cut off');
    final sizeText = latin1.decode(bytes.sublist(offset, lineEnd)).split(';').first.trim();
    final size = int.tryParse(sizeText, radix: 16);
    if (size == null) throw FormatException('bad chunk size "$sizeText"');
    offset = lineEnd + 2;
    if (size == 0) return out.toBytes();
    if (offset + size > bytes.length) throw const FormatException('chunk cut off');
    out.add(bytes.sublist(offset, offset + size));
    offset += size + 2;
  }
}

/// Inside view: start line, each header, blank line, body.
Frame describeHttpMessage(Uint8List bytes, {required bool isRequest}) {
  final fields = <Field>[];
  final headerEnd = _indexOfBlankLine(bytes);
  final headerBytes = headerEnd < 0 ? bytes.length : headerEnd;
  var offset = 0;
  var lineNumber = 0;
  final text = latin1.decode(bytes.sublist(0, headerBytes));
  for (final line in text.split('\r\n')) {
    final colon = line.indexOf(':');
    fields.add(Field(
      lineNumber == 0 ? (isRequest ? 'request line' : 'status line') : (colon > 0 ? line.substring(0, colon) : 'line'),
      offset,
      line.length + 2,
      lineNumber == 0 || colon <= 0 ? line : line.substring(colon + 1).trim(),
      note: lineNumber == 0 ? (isRequest ? 'method, target, version' : 'version, status code, reason') : '',
    ));
    offset += line.length + 2;
    lineNumber++;
  }
  String? error;
  if (headerEnd >= 0) {
    fields.add(Field('end of headers', headerEnd + 2, 2, r'\r\n', note: 'empty line'));
    final bodyLength = bytes.length - headerEnd - 4;
    if (bodyLength > 0) {
      final body = Uint8List.sublistView(bytes, headerEnd + 4);
      fields.add(Field('body', headerEnd + 4, bodyLength, bodyLength > 400 ? '$bodyLength bytes' : textOrHex(body)));
    }
  } else {
    error = 'headers not finished';
  }
  // One request, one response per connection here (Connection: close).
  return Frame(protocol: 'HTTP', summary: text.split('\r\n').first, bytes: bytes, fields: fields, error: error,
      exchange: 'HTTP', endsExchange: !isRequest, redecode: (changed) => describeHttpMessage(changed, isRequest: isRequest));
}

int _indexOfBlankLine(Uint8List bytes) => _indexOf(bytes, const [13, 10, 13, 10], 0);

int _indexOf(Uint8List bytes, List<int> pattern, int start) {
  for (var index = start; index + pattern.length <= bytes.length; index++) {
    var isMatch = true;
    for (var offset = 0; offset < pattern.length; offset++) {
      if (bytes[index + offset] != pattern[offset]) {
        isMatch = false;
        break;
      }
    }
    if (isMatch) return index;
  }
  return -1;
}
