import 'package:flutter/material.dart';

import 'ble/ble_tool.dart';
import 'bridge/bridge_tool.dart';
import 'bridge/bus_tools.dart';
import 'bridge/radio_tools.dart';
import 'coap/coap_tool.dart';
import 'http/http_tool.dart';
import 'learn_only_tool.dart';
import 'mdns/mdns_tool.dart';
import 'modbus/modbus_tool.dart';
import 'mqtt/mqtt_tool.dart';
import 'nfc/nfc_tool.dart';
import 'serial/serial_tool.dart';
import 'socket/socket_tool.dart';
import 'websocket/websocket_tool.dart';

enum ToolLayer {
  network('Network / IoT', 'Over Wi-Fi or mobile data, straight from the phone', Icons.public),
  wireless('Wireless', 'Radios: the phone\'s own, or the bridge\'s', Icons.wifi_tethering),
  wired('Wired buses', 'Through USB-OTG or the ESP32 bridge', Icons.settings_ethernet);

  const ToolLayer(this.title, this.subtitle, this.icon);
  final String title;
  final String subtitle;
  final IconData icon;
}

/// What a tool needs besides the phone.
enum ToolNeeds {
  phone('phone', Icons.smartphone),
  usbAdapter('USB-OTG adapter', Icons.usb),
  bridge('ESP32 bridge', Icons.developer_board),
  bridgeC6('bridge on ESP32-C6', Icons.developer_board),
  learnOnly('notes only', Icons.menu_book);

  const ToolNeeds(this.label, this.icon);
  final String label;
  final IconData icon;
}

class ToolInfo {
  const ToolInfo({
    required this.id,
    required this.name,
    required this.layer,
    required this.icon,
    required this.oneLine,
    required this.needs,
    required this.builder,
  });

  final String id;
  final String name;
  final ToolLayer layer;
  final IconData icon;
  final String oneLine;
  final ToolNeeds needs;
  final WidgetBuilder builder;
}

final toolCatalog = <ToolInfo>[
  ToolInfo(id: 'tcp', name: 'TCP socket', layer: ToolLayer.network, icon: Icons.cable, oneLine: 'Raw bytes to any host:port', needs: ToolNeeds.phone, builder: (_) => const SocketTool(isUdp: false)),
  ToolInfo(id: 'udp', name: 'UDP socket', layer: ToolLayer.network, icon: Icons.send, oneLine: 'Datagrams, no connection', needs: ToolNeeds.phone, builder: (_) => const SocketTool(isUdp: true)),
  ToolInfo(id: 'mqtt', name: 'MQTT', layer: ToolLayer.network, icon: Icons.hub, oneLine: 'Publish / subscribe through a broker', needs: ToolNeeds.phone, builder: (_) => const MqttTool()),
  ToolInfo(id: 'http', name: 'HTTP', layer: ToolLayer.network, icon: Icons.http, oneLine: 'Raw HTTP/1.1 requests (REST APIs)', needs: ToolNeeds.phone, builder: (_) => const HttpTool()),
  ToolInfo(id: 'websocket', name: 'WebSocket', layer: ToolLayer.network, icon: Icons.swap_horiz, oneLine: 'Two-way messages over HTTP', needs: ToolNeeds.phone, builder: (_) => const WebSocketTool()),
  ToolInfo(id: 'coap', name: 'CoAP', layer: ToolLayer.network, icon: Icons.memory, oneLine: 'REST for tiny devices, over UDP', needs: ToolNeeds.phone, builder: (_) => const CoapTool()),
  ToolInfo(id: 'mdns', name: 'mDNS finder', layer: ToolLayer.network, icon: Icons.travel_explore, oneLine: 'Find devices by name on the LAN', needs: ToolNeeds.phone, builder: (_) => const MdnsTool()),
  ToolInfo(id: 'modbus', name: 'Modbus master', layer: ToolLayer.wired, icon: Icons.factory, oneLine: 'RTU (RS-485) or TCP registers and coils', needs: ToolNeeds.phone, builder: (_) => const ModbusTool()),
  ToolInfo(id: 'serial', name: 'Serial terminal', layer: ToolLayer.wired, icon: Icons.terminal, oneLine: 'UART over USB-OTG or Bluetooth SPP', needs: ToolNeeds.usbAdapter, builder: (_) => const SerialTool()),
  ToolInfo(id: 'ble', name: 'BLE scanner + GATT', layer: ToolLayer.wireless, icon: Icons.bluetooth_searching, oneLine: 'Adverts, services, read / write / notify', needs: ToolNeeds.phone, builder: (_) => const BleTool()),
  ToolInfo(id: 'nfc', name: 'NFC tags', layer: ToolLayer.wireless, icon: Icons.nfc, oneLine: 'Read and write NDEF records', needs: ToolNeeds.phone, builder: (_) => const NfcTool()),
  ToolInfo(id: 'bridge', name: 'ESP32 bridge', layer: ToolLayer.wired, icon: Icons.developer_board, oneLine: 'Connect the bridge; raw command console', needs: ToolNeeds.bridge, builder: (_) => const BridgeTool()),
  ToolInfo(id: 'i2c', name: 'I2C', layer: ToolLayer.wired, icon: Icons.linear_scale, oneLine: 'Scan, read and write registers', needs: ToolNeeds.bridge, builder: (_) => const I2cTool()),
  ToolInfo(id: 'spi', name: 'SPI', layer: ToolLayer.wired, icon: Icons.compare_arrows, oneLine: 'Full-duplex byte transfers', needs: ToolNeeds.bridge, builder: (_) => const SpiTool()),
  ToolInfo(id: 'can', name: 'CAN bus', layer: ToolLayer.wired, icon: Icons.directions_car, oneLine: 'Monitor and send frames (TWAI)', needs: ToolNeeds.bridge, builder: (_) => const CanTool()),
  ToolInfo(id: 'onewire', name: '1-Wire', layer: ToolLayer.wired, icon: Icons.thermostat, oneLine: 'ROM search, DS18B20 temperature', needs: ToolNeeds.bridge, builder: (_) => const OneWireTool()),
  ToolInfo(id: 'wifi', name: 'Wi-Fi setup', layer: ToolLayer.wireless, icon: Icons.wifi, oneLine: 'Join the bridge to a network', needs: ToolNeeds.bridge, builder: (_) => const WifiTool()),
  ToolInfo(id: 'espnow', name: 'ESP-NOW', layer: ToolLayer.wireless, icon: Icons.podcasts, oneLine: 'ESP32 to ESP32, no router', needs: ToolNeeds.bridge, builder: (_) => const EspNowTool()),
  ToolInfo(id: 'zigbee', name: 'Zigbee', layer: ToolLayer.wireless, icon: Icons.lightbulb_outline, oneLine: 'Form a network, pair, switch on/off', needs: ToolNeeds.bridgeC6, builder: (_) => const ZigbeeTool()),
  ToolInfo(id: 'thread', name: 'Thread', layer: ToolLayer.wireless, icon: Icons.device_hub, oneLine: 'OpenThread CLI on the bridge', needs: ToolNeeds.bridgeC6, builder: (_) => const ThreadTool()),
  ToolInfo(id: 'lora', name: 'LoRa / LoRaWAN', layer: ToolLayer.wireless, icon: Icons.settings_input_antenna, oneLine: 'Long range, low rate (needs SX1262)', needs: ToolNeeds.learnOnly, builder: (_) => const LearnOnlyTool(toolId: 'lora', title: 'LoRa / LoRaWAN')),
  ToolInfo(id: 'lin', name: 'LIN bus', layer: ToolLayer.wired, icon: Icons.linear_scale, oneLine: 'Car body bus (needs TJA1021)', needs: ToolNeeds.learnOnly, builder: (_) => const LearnOnlyTool(toolId: 'lin', title: 'LIN bus')),
];

ToolInfo? toolById(String id) {
  for (final tool in toolCatalog) {
    if (tool.id == id) return tool;
  }
  return null;
}
