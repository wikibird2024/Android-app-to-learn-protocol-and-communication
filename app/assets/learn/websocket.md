# WebSocket

*Two-way messages over one TCP link*

## 1. HTTP upgrade (once)

```text
GET /ws HTTP/1.1
Upgrade: websocket
Sec-WebSocket-Key: <random base64>

→ HTTP/1.1 101 Switching Protocols
  Sec-WebSocket-Accept: SHA1(key + GUID)
```

## 2. Then frames, both ways, any time

```text
byte 0   FIN | opcode
         1 text · 2 binary · 8 close
         9 ping · 10 pong
byte 1   MASK | length
         126 → +2 bytes, 127 → +8 bytes
mask key 4 bytes, client → server only
payload  XOR with the mask
```

**Why:** HTTP is request / response; WebSocket lets the device push
(sensor values, logs) without polling.

## Knobs

| Knob | Meaning |
|---|---|
| URL | `ws://` plain, `wss://` TLS |
| subprotocol | agreed meaning of the messages (mqtt, graphql-ws …) |
| ping | keeps NAT and proxies from closing an idle link (20 s here) |

## Gotchas

- Clients MUST mask; servers must not.
- A close frame carries a code: 1000 normal, 1001 going away, 1006 =
  dropped (no close frame).

This tool uses `dart:io`, which hides the frame bytes, so the log shows
whole messages.
