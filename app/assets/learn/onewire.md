# 1-Wire

*One data wire (plus ground), slow, cheap*

```text
3.3V ─ 4.7k ─┬── DQ ── DS18B20 ── …
ESP32 GPIO ──┘
```

Devices can even be powered from DQ ("parasite power").

## Time slots

| Slot | Master does |
|---|---|
| reset | pulls low 480 µs; devices answer with a presence pulse |
| write 1 | short low |
| write 0 | long low |
| read | short low, then samples |

## ROM

Every device has a unique 64-bit ROM:

```text
[family 1][serial 6][CRC-8 1]
0x28 = DS18B20 temperature sensor
```

**ROM search** finds all devices bit by bit (a binary tree walk).

## DS18B20

1. Convert T (`0x44`) → wait 750 ms (12-bit).
2. Read scratchpad (`0xBE`) → 9 bytes: temp LSB, MSB (1/16 °C, signed),
   TH, TL, config, 3 reserved, CRC-8.

Example: `0x0191` = 401 / 16 = **25.0625 °C**.

## Gotchas

- CRC fails → long wire or a weak pull-up.
- 85.0 °C is the power-on value: the conversion did not run.
