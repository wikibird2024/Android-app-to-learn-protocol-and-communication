# Zigbee

*Low-power mesh for lights and sensors*

## Layers

```text
┌ ZCL clusters: On/Off 0x0006,
│   Level 0x0008, Temperature 0x0402 …
├ APS: endpoints (1..240), bindings
├ NWK: mesh routing, 16-bit short address
└ IEEE 802.15.4: 2.4 GHz, 250 kbit/s,
                 64-bit IEEE address
```

## Roles

| Role | Who |
|---|---|
| coordinator | forms the network (only one) |
| router | mains powered, relays (bulbs) |
| end device | sleeps on a battery (sensors) |

## Joining

1. The coordinator opens **permit join** for N seconds.
2. The device resets into pairing and gets the network key.
3. It announces itself (short address + IEEE address).

## On / Off

A ZCL frame to endpoint 1, cluster `0x0006`, command `00` off, `01` on,
`02` toggle.

Needs an 802.15.4 radio: **ESP32-C6 or H2** (not the S3). The bridge
builds Zigbee only for those chips; on an S3 this tool says so.

**Community:** Zigbee2MQTT maps every device to MQTT topics, a good
design to read.
