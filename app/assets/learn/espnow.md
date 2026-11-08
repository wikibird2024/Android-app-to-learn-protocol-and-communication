# ESP-NOW

*ESP32 to ESP32, no router*

```text
ESP32 A ── Wi-Fi action frame ──▶ ESP32 B
   no association · no IP · no DHCP
```

- Up to **250 bytes** per frame (v1).
- Addressed by MAC; `ff:ff:ff:ff:ff:ff` = everyone.
- Optional encryption per peer (PMK / LMK).
- Range like Wi-Fi, latency of a few ms.
- Both sides must be on the **same Wi-Fi channel**.

## Good for

Remote buttons and sensor nodes on batteries: wake, send, sleep in about
100 ms.

## Not for

Internet, large data, or phones. Phones cannot send ESP-NOW frames, which
is why this tool goes through the bridge.

## Gotchas

- If one side is also connected to a router, its channel follows the
  router.
- The send callback's "ok" means the peer's radio ACKed, not that the
  peer's app got the data.
