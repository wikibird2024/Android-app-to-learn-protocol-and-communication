# LoRa / LoRaWAN

*Kilometres at a few hundred bit/s*

| Name | What it is |
|---|---|
| LoRa | the radio: chirp spread spectrum, Semtech SX127x / SX126x |
| LoRaWAN | the network on top: devices → gateways → network server (TTN, ChirpStack) |

## Radio knobs (trade range for speed)

| Knob | Values | Effect |
|---|---|---|
| SF | 7..12 | +1 SF ≈ 2× time on air, more range |
| BW | 125 / 250 / 500 kHz | wider = faster, less range |
| CR | 4/5..4/8 | more = more error correction |

Bands: EU868, AS923 (Vietnam), US915. Each has duty-cycle limits (EU: 1 %).

## LoRaWAN classes

| Class | Receives |
|---|---|
| A | only in 2 short windows after it talks |
| B | in scheduled windows |
| C | always listening |

## Join

OTAA (DevEUI, JoinEUI, AppKey) → session keys. Frames are encrypted
(AES-128) and counted.

## Not built yet

Needs an SX1262 module on the bridge (SPI). The commands would be:

```text
lora init <freq> <sf> <bw>
lora send <hex>
event: lora rx
```
