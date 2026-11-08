# SPI

*Fast, full duplex, one chip select each*

```text
ESP32            device
SCLK ────────▶ SCK      clock (master)
MOSI ────────▶ SDI/DI   master out
MISO ◀──────── SDO/DO   master in
CS   ────────▶ CS       low = selected
```

Every clock moves one bit **each way**: you always receive as many bytes
as you send. To read, send dummy `0x00` bytes.

## Modes (CPOL, CPHA)

| Mode | Clock idle | Sample on |
|---|---|---|
| 0 | low | rising edge (most devices) |
| 1 | low | falling edge |
| 2 | high | falling edge |
| 3 | high | rising edge |

## Example: SPI flash JEDEC id

```text
out  9F 00 00 00
in   xx EF 40 18   (Winbond, 128 Mbit)
```

## Gotchas

- Wrong mode = shifted or garbage bits.
- Long wires + a high clock = ringing: start at 1 MHz.
- No addresses: one CS line per device.
