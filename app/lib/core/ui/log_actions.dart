import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../log/log_export.dart';
import '../log/session_log.dart';

/// App-bar menu for a log: pause, clear, export as CSV or pcap (Wireshark).
class LogActions extends StatelessWidget {
  const LogActions({super.key, required this.log, required this.name, this.pcapLink});

  final SessionLog log;

  /// File name stem, for example `mqtt`.
  final String name;

  /// How to wrap entries for Wireshark; null hides the pcap export.
  final PcapLink? pcapLink;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      onSelected: (action) async {
        switch (action) {
          case 'pause':
            log.isPaused = !log.isPaused;
          case 'clear':
            log.clear();
          case 'csv':
            await _share(context, '$name.csv', 'text/csv', logToCsv(log.entries).codeUnits);
          case 'pcap':
            await _share(context, '$name.pcap', 'application/vnd.tcpdump.pcap', logToPcap(log.entries, pcapLink!));
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(value: 'pause', child: Text(log.isPaused ? 'Resume log' : 'Pause log')),
        const PopupMenuItem(value: 'clear', child: Text('Clear log')),
        const PopupMenuItem(value: 'csv', child: Text('Export CSV')),
        if (pcapLink != null) const PopupMenuItem(value: 'pcap', child: Text('Export pcap (Wireshark)')),
      ],
    );
  }

  Future<void> _share(BuildContext context, String fileName, String mimeType, List<int> bytes) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: mimeType)], subject: fileName));
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $error')));
    }
  }
}
