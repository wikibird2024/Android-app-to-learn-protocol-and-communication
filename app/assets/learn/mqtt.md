# MQTT 3.1.1

*Publish / subscribe through a broker*

```text
sensor ─PUB t/1─▶ ┌────────┐ ─▶ phone
                  │ broker │    (sub t/#)
phone ─SUB t/#──▶ └────────┘ ─▶ server
                                (sub t/1)
```

Nobody talks to anyone directly: everyone connects **out** to the broker,
so it works behind NAT.

## Packet layout

```text
byte 0   type (4 bits) | flags (4 bits)
1..4     remaining length, 7 bits/byte,
         high bit = "more" (128 → 80 01)
then     variable header + payload
```

## Session

| Packet | Carries |
|---|---|
| CONNECT | client id, keep alive, clean session, will (topic + message), user / password |
| CONNACK | return code (0 = accepted) |

## QoS: who keeps a copy until it is safe

```text
0  PUBLISH                at most once
1  PUBLISH → PUBACK       at least once
2  PUBLISH → PUBREC       exactly once
   → PUBREL → PUBCOMP
```

QoS is per hop: publisher → broker and broker → subscriber are separate.

## Topics

| Filter | Matches |
|---|---|
| `sensors/kitchen/temp` | exactly that topic |
| `sensors/+/temp` | `+` = one level |
| `sensors/#` | `#` = everything below |

**Retained:** the broker keeps the last message and gives it to every new
subscriber.

## Keep alive

After `keepAlive` seconds of silence the client sends PINGREQ. The broker
drops a client that is silent for 1.5 × keepAlive and publishes its
**will**.

## Gotchas

- The same client id twice: the broker kicks the older connection
  (reconnect loops!).
- `test.mosquitto.org` is public: anyone can read your topics.
- The password is plain text without TLS (port 8883).

## Try

Set a will topic, connect, then turn off Wi-Fi: a second client sees the
will message.
