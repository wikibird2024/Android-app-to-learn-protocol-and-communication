import 'dart:async';

import 'package:flutter/services.dart';

import 'link.dart';

/// A serial port the phone can open: a USB-UART adapter on the OTG port, or
/// a paired Bluetooth Classic SPP device (HC-05, ESP32 SPP).
class SerialDevice {
  const SerialDevice({
    required this.kind,
    required this.id,
    required this.name,
    this.detail = '',
  });

  factory SerialDevice.fromMap(Map<Object?, Object?> map) => SerialDevice(
    kind: map['kind'] == 'bluetooth'
        ? SerialKind.bluetooth
        : SerialKind.usb,
    id: '${map['id']}',
    name: '${map['name']}',
    detail: '${map['detail'] ?? ''}',
  );

  final SerialKind kind;

  /// USB device name (`/dev/bus/usb/001/002`) or Bluetooth MAC address.
  final String id;
  final String name;

  /// Driver and VID:PID for USB (`CH34x 1a86:7523`), empty for Bluetooth.
  final String detail;
}

enum SerialKind { usb, bluetooth }

enum Parity { none, odd, even, mark, space }

class SerialSettings {
  const SerialSettings({
    this.baudRate = 115200,
    this.dataBits = 8,
    this.stopBits = 1,
    this.parity = Parity.none,
  });

  final int baudRate;
  final int dataBits;
  final int stopBits;
  final Parity parity;

  /// `115200 8N1`, how embedded people write it.
  String get shortText =>
      '$baudRate $dataBits${parity.name[0].toUpperCase()}$stopBits';
}

/// Talks to MainActivity.kt (channel `protocol_lab/serial`), which wraps
/// the community library usb-serial-for-android for USB and Android's
/// BluetoothSocket for SPP.
class SerialPorts {
  SerialPorts._();

  static const _methods = MethodChannel('protocol_lab/serial');
  static const _events = EventChannel('protocol_lab/serial/events');

  /// One native event stream for all open ports; each event names its port.
  static final Stream<Map<Object?, Object?>> _allEvents = _events
      .receiveBroadcastStream()
      .map((event) => event as Map<Object?, Object?>)
      .asBroadcastStream();

  static Future<List<SerialDevice>> list() async {
    final devices = await _methods.invokeListMethod<Map<Object?, Object?>>(
      'list',
    );
    return [for (final map in devices ?? const []) SerialDevice.fromMap(map)];
  }

  /// Asks for USB permission if needed (Android shows a dialog). Throws
  /// [PlatformException] when the user says no or the port fails.
  static Future<SerialLink> open(
    SerialDevice device,
    SerialSettings settings,
  ) async {
    final handle = await _methods.invokeMethod<int>('open', {
      'kind': device.kind.name,
      'id': device.id,
      'baudRate': settings.baudRate,
      'dataBits': settings.dataBits,
      'stopBits': settings.stopBits,
      'parity': settings.parity.index,
    });
    if (handle == null) {
      throw PlatformException(code: 'open', message: 'no port handle');
    }
    return SerialLink._(handle, '${device.name} ${settings.shortText}');
  }
}

class SerialLink implements Link {
  SerialLink._(this._handle, this.description) {
    _subscription = SerialPorts._allEvents
        .where((event) => event['handle'] == _handle)
        .listen((event) {
          final bytes = event['bytes'];
          if (bytes is Uint8List) _incoming.add(bytes);
          if (event['closed'] == true) _incoming.close();
        });
  }

  final int _handle;
  late final StreamSubscription<Map<Object?, Object?>> _subscription;
  final _incoming = StreamController<Uint8List>.broadcast();

  @override
  final String description;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List bytes) => SerialPorts._methods.invokeMethod(
    'write',
    {'handle': _handle, 'bytes': bytes},
  );

  /// DTR/RTS: ESP32 and Arduino boards use them to reset into the
  /// bootloader, so a terminal must be able to set them.
  Future<void> setControlLines({required bool dtr, required bool rts}) =>
      SerialPorts._methods.invokeMethod('control', {
        'handle': _handle,
        'dtr': dtr,
        'rts': rts,
      });

  @override
  Future<void> close() async {
    await SerialPorts._methods.invokeMethod('close', {'handle': _handle});
    await _subscription.cancel();
    if (!_incoming.isClosed) await _incoming.close();
  }
}
