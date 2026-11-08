# Bluetooth Low Energy

*Adverts first, then GATT*

## 1. Advertising (no connection)

The device shouts every 20 ms to 10 s on channels 37, 38 and 39: up to
31 bytes of **AD structures**, each `[len][type][data]`.

| Type | Meaning |
|---|---|
| `01` | flags |
| `09` | complete name |
| `03` | 16-bit service UUIDs |
| `ff` | manufacturer data (company id first) |

## 2. Connection → GATT (attribute table)

```text
Service 180f  Battery
 └ Characteristic 2a19  Battery Level
     properties: read, notify
     value: 0x5a  (90 %)
     └ Descriptor 2902  CCCD (notify on)
```

## Operations

| Operation | What happens |
|---|---|
| read | phone asks, device answers |
| write | with response (acked) or without |
| notify | device pushes when the value changes (after the phone wrote `01 00` to the CCCD) |
| indicate | notify + an ack from the phone |

## Sizes

ATT MTU defaults to 23 → **20 bytes per value**. This app asks for 247
after connecting.

## UUIDs

- **16-bit** = Bluetooth SIG standard, short for
  `0000xxxx-0000-1000-8000-00805f9b34fb`
- **128-bit** = vendor, for example Nordic UART `6e400001-…`

## Gotchas

- Android 12+ needs the `BLUETOOTH_SCAN` / `CONNECT` permissions; older
  Android needs location turned ON.
- Phones hide the raw advert bytes; this app rebuilds them from the parsed
  fields.
- The ESP32 NimBLE example `bleprph` makes a good test peripheral.
