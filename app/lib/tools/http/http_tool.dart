import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/bytes/hex.dart';
import '../../core/log/log_export.dart';
import '../../core/log/session_log.dart';
import '../../core/settings/tool_settings.dart';
import '../../core/transport/tcp_link.dart';
import '../../core/ui/form_parts.dart';
import '../../core/ui/tool_scaffold.dart';
import '../../protocols/http/http_codec.dart';

/// HTTP over our own TCP link, not a library client, so the exact request
/// and response bytes are in the log.
class HttpTool extends ConsumerStatefulWidget {
  const HttpTool({super.key});

  @override
  ConsumerState<HttpTool> createState() => _HttpToolState();
}

class _HttpToolState extends ConsumerState<HttpTool> {
  late final _settings = ref.read(toolSettingsProvider('http'));
  late final _fields = SettingsControllers(_settings, {
    'method': 'GET',
    'url': 'http://httpbin.org/get',
    'headers': 'Accept: application/json',
    'body': '',
  });
  final _log = SessionLog();
  HttpResponse? _response;
  Duration? _elapsed;
  bool _isBusy = false;

  @override
  void dispose() {
    _fields.dispose();
    _log.dispose();
    super.dispose();
  }

  Future<void> _send(BuildContext tabContext) async {
    setState(() => _isBusy = true);
    try {
      final uri = Uri.parse(_fields.text('url'));
      if (uri.scheme != 'http' && uri.scheme != 'https') throw const FormatException('URL must start with http:// or https://');
      await _fields.remember();
      final headers = <String, String>{
        for (final line in const LineSplitter().convert(_fields['headers'].text))
          if (line.contains(':')) line.substring(0, line.indexOf(':')).trim(): line.substring(line.indexOf(':') + 1).trim(),
      };
      final body = _fields['body'].text;
      final request = encodeHttpRequest(
        method: _fields.text('method'),
        uri: uri,
        headers: headers,
        body: body.isEmpty ? null : Uint8List.fromList(utf8.encode(body)),
      );
      final watch = Stopwatch()..start();
      final link = await TcpLink.connect(uri.host, uri.port, useTls: uri.scheme == 'https', timeout: const Duration(seconds: 10));
      _log.note('connected ${link.description}');
      final received = BytesBuilder();
      final done = Completer<void>();
      final subscription = link.incoming.listen(received.add, onDone: done.complete, onError: done.completeError);
      await link.send(request);
      _log.sent(describeHttpMessage(request, isRequest: true));
      await done.future.timeout(const Duration(seconds: 20), onTimeout: () => _log.note('no close after 20 s, using what came'));
      await subscription.cancel();
      await link.close();
      final bytes = received.takeBytes();
      _log.received(describeHttpMessage(bytes, isRequest: false));
      final response = parseHttpResponse(bytes);
      setState(() {
        _response = response;
        _elapsed = watch.elapsed;
      });
      if (tabContext.mounted) DefaultTabController.of(tabContext).animateTo(1);
    } on Object catch (error) {
      _log.note('failed: $error');
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final response = _response;
    return ToolScaffold(
      toolId: 'http',
      title: 'HTTP',
      log: _log,
      status: response == null ? null : '${response.statusCode} ${response.reason} · ${_elapsed?.inMilliseconds} ms',
      pcapLink: PcapTcp(Uri.tryParse(_fields.text('url'))?.port ?? 80),
      configure: Builder(
        builder: (tabContext) => FormColumn(
          children: [
            ProfileBar(controllers: _fields, onLoaded: () => setState(() {})),
            Row(children: [
              SizedBox(
                width: 110,
                child: ChoiceField<String>(
                  label: 'Method',
                  value: _fields.text('method'),
                  options: const {'GET': 'GET', 'POST': 'POST', 'PUT': 'PUT', 'PATCH': 'PATCH', 'DELETE': 'DELETE', 'HEAD': 'HEAD'},
                  onChanged: (value) => setState(() => _fields['method'].text = value),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: LabeledField(controller: _fields['url'], label: 'URL')),
            ]),
            LabeledField(controller: _fields['headers'], label: 'Headers (one "Name: value" per line)', maxLines: 4),
            LabeledField(controller: _fields['body'], label: 'Body', maxLines: 6),
            FilledButton.icon(onPressed: _isBusy ? null : () => _send(tabContext), icon: const Icon(Icons.send), label: const Text('Send')),
          ],
        ),
      ),
      talk: response == null
          ? const Center(child: Text('Send a request from Setup.'))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Text('${response.statusCode} ${response.reason}', style: Theme.of(context).textTheme.headlineSmall),
                Text(_statusMeaning(response.statusCode)),
                const Divider(),
                for (final entry in response.headers.entries) Text('${entry.key}: ${entry.value}', style: monospace),
                const Divider(),
                SelectableText(_prettyBody(response.body), style: monospace),
              ],
            ),
    );
  }

  static String _statusMeaning(int code) => switch (code ~/ 100) {
    1 => 'informational',
    2 => 'success',
    3 => 'redirect: see the Location header',
    4 => 'client error: the request is wrong',
    5 => 'server error: the device failed',
    _ => '',
  };

  static String _prettyBody(Uint8List body) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(utf8.decode(body)));
    } on Object {
      return body.length > 20000 ? '${body.length} bytes' : textOrHex(body);
    }
  }
}
