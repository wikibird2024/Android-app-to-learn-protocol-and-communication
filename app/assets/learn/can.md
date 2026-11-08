# CAN

*A shared bus with priorities*

```text
node ── CANH ═══════════════ CANH ── node
node ── CANL ═══════════════ CANL ── node
      120 Ω                 120 Ω
      (a terminator at both ends)
```

## Classic frame (what software sees)

- id: **11-bit** (standard) or **29-bit** (extended)
- RTR flag and DLC
- 0 to 8 data bytes

The controller adds SOF, CRC-15, the ACK slot, EOF and bit stuffing
(after 5 equal bits, one opposite bit).

## Arbitration

All nodes start together; a 0 (dominant) beats a 1, so the **lower id
wins**, with no collision and no loss. The id is the priority, not an
address.

## ACK

Any node that received the frame correctly pulls the ACK slot dominant. A
lone node never gets ACKs → its error counters climb → **bus-off**.

## Bit rates

125k, 250k (J1939), 500k (cars), 1M. Every node must match.

The ESP32's **TWAI** is a CAN 2.0 controller; it needs a transceiver
(SN65HVD230 at 3.3 V).

## Gotchas

- One node alone: sends fail (no ACK).
- Missing terminators: errors at speed.
- OBD-II: request on `7DF`, replies on `7E8`..`7EF`.

Export pcap → Wireshark decodes it as SocketCAN.
