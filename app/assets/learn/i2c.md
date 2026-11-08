# I2C

*Two wires, many devices, addresses*

```text
3.3V ─┬────┬─── pull-ups (2.2k–10k)
SDA ──┴─┬──┴─┬──── data (open drain)
SCL ────┼────┼──── clock (master drives)
     ESP32  BME280 0x76  OLED 0x3C
```

## One transaction (register read)

```text
S  [0x76<<1|W] A  [reg D0] A
Sr [0x76<<1|R] A  [data]   N  P
```

| Symbol | Meaning |
|---|---|
| S / Sr / P | start / repeated start / stop |
| A | ACK: the receiver pulls SDA low |
| N | NACK: "no more" (or nobody there) |

The 7-bit address is shifted left, plus the R/W bit:
`0x76` → write byte `EC`, read byte `ED`.

## Speeds

100 kHz standard · 400 kHz fast.

## Scan

Try every address with a zero-length write; whoever ACKs is there.

## Gotchas

- No pull-ups → nothing answers.
- Datasheets mix 7-bit (`0x76`) and 8-bit (`0xEC`) addresses.
- A stuck SDA (a device mid-byte after a reset) → clock 9 pulses to free
  it.
