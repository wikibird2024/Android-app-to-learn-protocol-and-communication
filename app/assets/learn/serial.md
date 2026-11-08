# UART

*Two wires, no clock*

```text
idle ─┐start┌─┬─┬─┬─┬─┬─┬─┬─┐ stop ┌─ idle
      └─────┘ d0 … d7       └──────┘
              LSB first  (parity bit
                         goes before stop)
```

**115200 8N1** = 115200 bit/s, 8 data bits, no parity, 1 stop bit → 10
bits per byte → 11.5 kB/s.

```text
TX  ──▶ RX     both sides MUST agree on
RX  ◀── TX     baud and format beforehand
GND ─── GND    (always connect ground)
```

## Levels

| Level | Where |
|---|---|
| 3.3 V TTL | ESP32, STM32, USB-UART adapters |
| RS-232 ±12 V | needs a MAX3232; never wire it straight to a microcontroller |

## Control lines

ESP32 dev boards use **DTR / RTS** to reset into the bootloader (that is
how flashing works). Toggle them here to reset the board.

## Phone side

- **USB-OTG** + a CH340 / CP2102 / FTDI adapter, with drivers from the
  community library usb-serial-for-android (mik3y).
- **Bluetooth SPP** (HC-05, ESP32 Classic BT) looks the same: a byte
  stream.

## Gotchas

- Garbage text = wrong baud.
- Nothing at all = TX/RX swapped.
- Line endings: `\n` (Linux), `\r\n` (AT commands, Windows), `\r` (old
  modems).
