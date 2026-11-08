# CLAUDE.md

Protocol Lab: a Flutter Android app (`app/`) plus an ESP32 bridge
(`firmware/bridge/`, ESP-IDF v5.5, C) for using and learning embedded
connection protocols. Goal: a real bench tool where every tool also shows
the bytes and the mental model. Author: Hao Tran.

## Commands

```bash
# App (Flutter 3.47.7). On this machine /mnt/storage may be unmounted:
export PUB_CACHE=$HOME/sdk/pub-cache PATH=$HOME/sdk/flutter/bin:$PATH
cd app && flutter analyze && flutter test
python3 tool/fake_bridge.py --port 13333 --modbus-port 11502 --ws-port 18081 & mosquitto -p 18830 -d
MQTT_TEST_PORT=18830 FAKE_BRIDGE_PORT=13333 FAKE_MODBUS_PORT=11502 FAKE_WS_PORT=18081 flutter test --tags integration

# Bridge plain-C tests (no ESP-IDF needed)
cmake -S firmware/bridge/test/host -B build-host && cmake --build build-host && ctest --test-dir build-host

# Firmware: CI builds esp32s3 + esp32c6 (local IDF here is v5.1, too old for i2c_master)
cd firmware/bridge && idf.py set-target esp32s3 build

# Formatting (CI checks with clang-format 23.1.1; Unity is excluded)
clang-format -i firmware/bridge/main/*.[ch] firmware/bridge/components/*/*.[ch]
```

APK and firmware are built only in GitHub CI (disk on this machine is tight);
CI turns APK build errors into a readable annotation.

## Architecture rules

- **Codec = pure, Link = I/O, Tool = glue.** `lib/protocols/<p>/` has no
  Flutter UI and no sockets; it works on bytes and a `Link`
  (`lib/core/transport/link.dart`), so tests use `FakeLink`. Tools in
  `lib/tools/<t>/` never parse bytes themselves.
- **Every frame goes through `SessionLog`** as a decoded `Frame` (fields with
  byte offsets) → Inside tab, CSV, pcap. Decoders never throw on bad bytes:
  they return a frame with `error`. A decoder also fills, where it can:
  `Field.bitShift/bitWidth` (bit map), `Frame.exchange/endsExchange`
  (request ↔ reply pairing in the Flow view), `Frame.wire` (signals drawn
  from the bytes, `protocols/bus/wire_signals.dart`) and `Frame.redecode`
  (the "What if…" editor).
- **Byte formats are hand-written; native drivers come from community
  packages** (universal_ble, nfc_manager, share_plus, crypto for SHA-1) or
  community native libraries (usb-serial-for-android via the Kotlin channel
  in `MainActivity.kt`). Check a package's license and build files before
  adding it (flutter_blue_plus: commercial license; usb_serial: jcenter).
  mDNS (DNS) and WebSocket are hand-written on raw sockets on purpose:
  packages hide the bytes.
- **Bridge protocol** is text lines, one JSON reply per request
  (`firmware/bridge/components/bridge_protocol/bridge_protocol.h`). Firmware,
  `app/lib/protocols/bridge/` and `app/tool/fake_bridge.py` must agree; the
  integration test runs the app's clients against the fake.
- **Firmware:** every command runs under one lock in `bridge_io.c`, so bus
  state in `cmd_*.c` has a single user. Events (CAN rx, ESP-NOW, Zigbee
  joins) go out with `BridgeIo_SendEvent`. Zigbee is built only when the
  chip has 802.15.4 (`CONFIG_BRIDGE_ZIGBEE`, C6/H2).
- Each tool has a Learn note `app/assets/learn/<tool id>.md`
  (Markdown, rendered by flutter_markdown_plus); a test fails
  when one is missing.

## Known gaps

- Nothing has run on a phone or a board yet: BLE, NFC, USB-OTG, Bluetooth
  SPP, and all firmware need a bench check.
- Thread: the app tool exists, the firmware has no `ot` command yet.
- LoRa and LIN are notes only (no SX1262 / TJA1021).
- Console UART carries both logs and replies; logs drop to WARN after boot
  (`main.c` shortcut).
