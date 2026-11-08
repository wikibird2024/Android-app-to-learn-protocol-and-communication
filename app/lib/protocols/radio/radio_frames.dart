import 'dart:convert';
import 'dart:typed_data';

import '../../core/bytes/hex.dart';
import '../../core/inspect/frame.dart';

/// Frames the bridge's radio stack builds for us, rebuilt from the layouts
/// in the vendor docs so the Inside view shows what goes on the air. The
/// bridge only reports the payload, so values it chooses (random bytes,
/// sequence numbers) are shown as 00 and say so.

/// ESP-NOW (ESP-IDF "ESP-NOW frame format"): a Wi-Fi vendor-specific action
/// frame. The 24-byte MAC header and the 4-byte FCS around it are left out.
Frame describeEspNow(List<int> body, {required String peer, required bool isSent, String detail = ''}) {
  final out = BytesBuilder()
    ..addByte(127) // category: vendor specific
    ..add(const [0x18, 0xfe, 0x34]) // Espressif OUI
    ..add(const [0, 0, 0, 0]) // random values (chosen by the stack)
    ..addByte(0xdd) // element id: vendor specific
    ..addByte(5 + body.length)
    ..add(const [0x18, 0xfe, 0x34])
    ..addByte(4) // type: ESP-NOW
    ..addByte(1) // version
    ..add(body);
  final bytes = out.toBytes();
  return Frame(
    protocol: 'ESP-NOW',
    summary: '${isSent ? 'to' : 'from'} $peer$detail: ${textOrHex(Uint8List.fromList(body))}',
    bytes: bytes,
    fields: [
      Field('MAC header (not shown)', 0, 0, '${isSent ? 'destination' : 'source'} $peer', note: '24 bytes: frame control "action", addresses; FCS (4 bytes) closes the frame'),
      const Field('category', 0, 1, '127 vendor specific', note: 'an action frame: no association with an access point needed'),
      const Field('OUI', 1, 3, '18 fe 34 Espressif'),
      const Field('random values', 4, 4, '(chosen by the stack)', note: 'shown as 00: the bridge does not report them'),
      const Field('element id', 8, 1, '0xdd vendor specific'),
      Field('length', 9, 1, '${5 + body.length}', note: 'OUI + type + version + body'),
      const Field('OUI', 10, 3, '18 fe 34'),
      const Field('type', 13, 1, '4 ESP-NOW'),
      const Field('version', 14, 1, '1'),
      Field('body', 15, body.length, textOrHex(Uint8List.fromList(body)), note: 'up to 250 bytes (v1)'),
    ],
  );
}

/// A ZCL On/Off command (Zigbee Cluster Library 3.8) as the coordinator
/// sends it inside an APS frame to cluster 0x0006 of one endpoint.
Frame describeZclOnOff({required String shortAddress, required int endpoint, required String action}) {
  final command = switch (action) {
    'off' => 0x00,
    'on' => 0x01,
    _ => 0x02,
  };
  final bytes = Uint8List.fromList([0x01, 0x00, command]);
  return Frame(
    protocol: 'Zigbee ZCL',
    summary: 'On/Off $action → 0x$shortAddress endpoint $endpoint',
    bytes: bytes,
    fields: [
      Field('APS (not shown)', 0, 0, 'to 0x$shortAddress, endpoint $endpoint, cluster 0x0006, profile 0x0104',
          note: 'the APS header picks the device, endpoint, cluster and profile (Home Automation)'),
      const Field('frame control', 0, 1, '0x01', children: [
        Field('frame type', 0, 1, '1 cluster-specific', note: '0 = global (read attributes…), 1 = this cluster\'s own commands', bitShift: 0, bitWidth: 2),
        Field('manufacturer specific', 0, 1, 'no', bitShift: 2, bitWidth: 1),
        Field('direction', 0, 1, 'client → server', note: 'the switch (client) tells the light (server)', bitShift: 3, bitWidth: 1),
        Field('disable default response', 0, 1, 'no', note: 'no: the light answers with a Default Response', bitShift: 4, bitWidth: 1),
      ]),
      const Field('sequence number', 1, 1, '(chosen by the stack)', note: 'shown as 00; the reply repeats it'),
      Field('command', 2, 1, '${hex8(command)} ${action == 'toggle' ? 'Toggle' : action == 'on' ? 'On' : 'Off'}', note: '0x00 off · 0x01 on · 0x02 toggle'),
    ],
  );
}

/// A Zigbee event from the bridge (device joined, attribute report), shown
/// as its JSON fields.
Frame describeZigbeeEvent(Map<String, Object?> event) {
  final text = jsonEncode(event);
  return Frame(
    protocol: 'Zigbee',
    summary: '${event['type']} ${event['short'] ?? ''}'.trim(),
    bytes: Uint8List.fromList(utf8.encode(text)),
    fields: [
      for (final entry in event.entries)
        if (text.indexOf('"${entry.key}":') case final offset when offset >= 0)
          Field(entry.key, offset, '"${entry.key}":'.length + jsonEncode(entry.value).length, jsonEncode(entry.value)),
    ],
  );
}
