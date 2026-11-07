# Protocol Lab app

Flutter (Android). Author: Hao Tran. See `../README.md` for the big picture.

```bash
flutter analyze && flutter test                       # unit + widget tests
python3 tool/fake_bridge.py --port 13333 --modbus-port 11502 &
mosquitto -p 18830 -d
MQTT_TEST_PORT=18830 FAKE_BRIDGE_PORT=13333 FAKE_MODBUS_PORT=11502 \
  flutter test --tags integration                     # against real/fake servers
```

Layout: `lib/core/` (bytes, frames, log + export, links, settings, shared
UI), `lib/protocols/<p>/` (pure Dart codecs and clients, no Flutter UI),
`lib/tools/<t>/` (one screen per tool), `assets/learn/<tool>.txt` (Learn tab).
