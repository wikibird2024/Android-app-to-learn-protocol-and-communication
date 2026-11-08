# CoAP (RFC 7252)

*REST for tiny devices, over UDP*

```text
4-byte header + token + options + payload
┌───┬───┬─────┬────────┬────────────┐
│Ver│ T │ TKL │  Code  │ Message ID │
│ 2b│ 2b│  4b │   8b   │    16b     │
└───┴───┴─────┴────────┴────────────┘
```

Codes are written `c.dd`:

| Code | Meaning |
|---|---|
| 0.01 / 0.02 / 0.03 / 0.04 | GET / POST / PUT / DELETE |
| 2.05 | Content |
| 4.04 | Not Found |
| 5.00 | Server error |

## Message types

| Type | Meaning |
|---|---|
| CON | confirmable: wants an ACK, resent if lost |
| NON | fire and forget |
| ACK | "got it" (may carry the response) |
| RST | "I don't know this message" |

## Reliability (done by the client, not UDP)

```text
CON → no ACK in 2–3 s → resend,
      wait doubles: 4, 8, 16 s
    → give up after 4 resends
```

## Two ways to answer

- **Piggybacked:** the ACK carries 2.05 + payload.
- **Separate:** an empty ACK now, a CON response later (which we ACK).

## Options

Options are **delta-encoded**: each one stores "number − previous
number", so they must be sorted. Uri-Path (11) repeats per segment:
`/sensors/temp` → `"sensors"`, `"temp"`.

**Observe** (option 6): the server pushes every change of a resource with
the same token.

## Try

1. On `coap.me`, GET `/.well-known/core` to list resources (link format).
2. GET `/test` with CON off, then on, and compare the log.
