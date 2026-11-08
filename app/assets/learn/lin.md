# LIN

*The cheap single-wire bus in car bodies*

- One master (it runs the schedule), up to 16 slaves.
- One wire at 12 V, up to 20 kbit/s.

## Frame

A frame is a **header** (sent by the master) plus a **response** (sent by
the node that owns that id).

```text
break    ≥ 13 bits low
sync     0x55
PID      6-bit id + 2 parity bits
data     1–8 bytes
checksum classic: data only
         enhanced: data + PID (LIN 2.x)
```

Used for windows, mirrors and seats: places where CAN is too expensive.

A UART can do LIN: the break is a long low, sent by dropping the baud
rate for one byte.

## Not built yet

Needs a TJA1021 transceiver on the bridge UART. The commands would be:

```text
lin init <baud>
lin send <pid> <hex>
lin request <pid>
```
