# TCP

*A reliable byte stream*

```text
phone                   device
  │ ── SYN ────────────▶ │  3-way
  │ ◀──────── SYN+ACK ── │  handshake
  │ ── ACK ────────────▶ │  (by the OS)
  │ ══ bytes, in order ═ │
  │ ── FIN ────────────▶ │  close
```

## What TCP gives you

- **Order:** bytes arrive in the order they were sent.
- **No loss:** lost segments are re-sent.
- **No message borders:** send `"AB"` + `"CD"` and the other side may
  read `"A"`, `"BCD"`.

So every protocol on TCP must mark its own frames:

| Protocol | Frame border |
|---|---|
| MQTT | remaining-length field |
| Modbus TCP | MBAP length field |
| HTTP | blank line + Content-Length |
| console | newline |

## Knobs

| Knob | Meaning |
|---|---|
| host:port | who to talk to |
| TLS | encrypt + check the server certificate |
| NoDelay | send small frames now (this app turns Nagle's batching off) |

## Gotchas

- Connect timeout ≠ device down: check that the phone and device are on
  the same network.
- "Connection refused" = the host is up, the port is closed.
- A silent dead peer is only noticed when you send, so protocols add
  keep-alives.

## Try

Connect to the ESP32 bridge (port 3333), send `ping\n`, and watch the
reply arrive in chunks in Inside.
