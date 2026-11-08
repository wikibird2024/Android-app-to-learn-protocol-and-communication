# Wi-Fi setup

*Getting a device onto a network*

```text
first boot: no credentials
   ESP32 = access point "protolab-bridge"
   phone joins it → 192.168.4.1
   phone sends SSID + password
   ESP32 saves them (NVS) → station mode
   → joins home Wi-Fi, gets an IP by DHCP
```

| Mode | Role |
|---|---|
| Station (STA) | a client of a router |
| Access point (AP) | makes its own network |

## Other ways the industry does this

- **ESP-IDF wifi_provisioning:** over BLE or SoftAP, with encryption
  (Security 1 / 2).
- **SmartConfig / ESP-Touch:** the phone encodes the password in packet
  lengths.
- **Matter:** commissioning over BLE.

## What a scan shows

| Field | Values |
|---|---|
| RSSI | −50 dBm great · −70 ok · −85 poor |
| channel | 1–13 (2.4 GHz only on ESP32 / S3 / C6) |
| auth | open, WPA2, WPA3 |

## Gotchas

- The ESP32 cannot join 5 GHz networks.
- Captive portals (hotels) block devices.
- This bench tool sends the password in clear text over the bridge link.
