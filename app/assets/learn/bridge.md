# The ESP32 bridge

*The phone's missing ports*

```text
phone ── Wi-Fi TCP :3333 ──┐
      ── USB serial ───────┤   ESP32
                           ▼
   text line protocol → command table
     i2c · spi · can (TWAI) · ow (1-Wire)
     wifi · espnow · zb (C6) · ot (C6)
```

## Protocol (same over TCP and serial)

| Line | Shape |
|---|---|
| request | `<id> <command> <args>\n` |
| reply | `{"id":7,"ok":true,"data":...}` |
| error | `{"id":7,"ok":false,"error":"..."}` |
| event | `{"event":"can","id":"123",...}` |

Text on purpose: you can type the same commands in any serial terminal,
and boot logs show up as console lines instead of being mistaken for
replies.

## First start

1. With no Wi-Fi saved, the bridge opens the access point
   **protolab-bridge** at `192.168.4.1`.
2. Use the **Wi-Fi setup** tool to join your network.
3. From then on it is found by mDNS as `_protolab._tcp`.

Commands: type `help` in the Talk tab.
