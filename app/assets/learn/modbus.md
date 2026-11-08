# Modbus

*Registers and coils: the master asks, a slave answers*

## Data model

Addresses are 0-based on the wire.

| Table | Access | Datasheet | Functions |
|---|---|---|---|
| coils | R/W bit | 0xxxx | 1 read · 5/15 write |
| discrete inputs | R bit | 1xxxx | 2 |
| input registers | R 16-bit | 3xxxx | 4 |
| holding registers | R/W 16-bit | 4xxxx | 3 read · 6/16 write |

"40001" in a datasheet = holding register **0**.

## Frames

The core is the PDU: `[function][data]`.

**RTU** (RS-485, serial):

```text
[unit][PDU][CRC16 lo][CRC16 hi]
example: 11 03 00 6B 00 03 | 76 87
```

A frame ends after 3.5 character times of silence. The CRC is
CRC-16/MODBUS (poly 0xA001, init FFFF).

**TCP** (port 502):

```text
[transaction][protocol 0][length]
[unit][PDU]
```

No CRC: TCP already checks.

## Exceptions

The reply's function is `0x80 + function`, followed by a code:

| Code | Meaning |
|---|---|
| 1 | illegal function |
| 2 | illegal address |
| 3 | illegal value |
| 4 | device failure |

## RS-485 wiring

A/B twisted pair, 120 Ω at both ends, common ground, one master, up to 247
slaves. Half-duplex: only one side talks, so one request at a time.

## Gotchas

- Off-by-one address (40001 vs 0).
- 32-bit values use 2 registers, and the word order differs by vendor:
  try both.
- Wrong baud or parity = silence, not errors (common defaults: 9600 8E1
  or 19200 8E1).
