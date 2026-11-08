# UDP

*Datagrams, no connection*

```text
phone ── datagram ──▶ device
phone ◀── datagram ── device
each send = one packet; it may be
lost, doubled or arrive out of order

[IP 20][UDP 8][payload ≤ ~1472 on Wi-Fi]
UDP header: src port · dst port ·
            length · checksum
```

## Why use it

- No handshake: the first packet is already data.
- Message borders are kept: one send = one receive.
- Broadcast and multicast are possible (mDNS).

## What you must add yourself

- Reliability: ack + resend (like CoAP CON).
- Ordering: sequence numbers.
- Fragmentation: keep payloads small.

## Knobs

| Knob | Meaning |
|---|---|
| host:port | where to send |
| local port | 0 = any; fix it when the device answers to a known port |

## Gotchas

- Android drops multicast unless an app holds a multicast lock (this app
  does, for mDNS).
- NAT routers forget UDP "connections" after about 30 s of silence.

## Try

Open the CoAP tool → `coap.me`, then look at the UDP datagrams in Inside:
one request, one reply.
