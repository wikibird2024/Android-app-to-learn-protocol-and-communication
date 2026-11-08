# Protocol Lab

A phone app (Flutter, Android) plus an ESP32 bridge for **using and learning**
the common embedded connection protocols. Every tool has the same four tabs:

```
Setup │ Talk │ Inside (fields, bit maps, Flow of request ↔ reply, wire
               signals for buses, "What if…" byte editor) │ Learn (mental model)
```

Author: Hao Tran

## Architecture

```
 tool screen (lib/tools)  ──▶  protocol codec/client (lib/protocols, pure Dart, tested)
                                      │
                               Link (lib/core/transport): TCP · UDP · USB serial · BT SPP
                                      │
            ┌─────────── phone radios: Wi-Fi, BLE, NFC ───────────┐
            └── ESP32 bridge (firmware/bridge, C, ESP-IDF) ── I2C · SPI · CAN · 1-Wire
                                                              ESP-NOW · Zigbee/Thread (C6)
```

Rules: codecs never do I/O; every frame sent or received goes through the
session log (Inside tab, CSV and pcap export for Wireshark); native drivers
come from community packages, byte formats are written by hand and checked
against community tools (Mosquitto, Wireshark, spec examples).

## Tools

| Layer | Tools |
|---|---|
| Network / IoT | TCP, UDP, MQTT, HTTP, WebSocket, CoAP, mDNS |
| Wireless | BLE scanner + GATT, NFC, Wi-Fi setup, ESP-NOW, Zigbee, Thread, LoRa (notes) |
| Wired | Serial (USB-OTG / BT SPP), Modbus RTU/TCP, I2C, SPI, CAN, 1-Wire, LIN (notes) |

## Build and test

CI (`.github/workflows/ci.yml`) runs everything and keeps the APK and the
firmware binaries as artifacts. Locally: see `app/README.md` and
`firmware/bridge/README.md`.
