# Protocol Lab bridge (ESP32, ESP-IDF v5.5)

Gives the phone the ports it lacks: I2C, SPI, CAN (TWAI), 1-Wire, ESP-NOW,
and Zigbee on chips with an 802.15.4 radio. Author: Hao Tran.

```
phone ── Wi-Fi TCP :3333 ─┐            ┌─ i2c   (driver/i2c_master)
      ── USB serial (UART0)┴─ bridge_io ┼─ spi   (driver/spi_master)
         one line in,      command lock ├─ can   (driver/twai) ──▶ rx task → events
         one JSON line out              ├─ ow    (espressif/onewire_bus, RMT)
                                        ├─ wifi  (AP+STA, mDNS _protolab._tcp)
                                        └─ espnow (recv cb → events)
```

Protocol: `components/bridge_protocol/bridge_protocol.h` (plain C, host tested).

```bash
. $IDF_PATH/export.sh
idf.py set-target esp32s3 build flash monitor     # or esp32c6
cmake -S test/host -B build-host && cmake --build build-host && ctest --test-dir build-host
```

First start: join Wi-Fi `protolab-bridge` (password `protolab`, change it in
menuconfig), connect the app to 192.168.4.1:3333, then use the Wi-Fi setup
tool to join your network. Over USB, type `help` in any serial terminal
at 115200 8N1.

| Bus | Default pins in the app (change per board) |
|---|---|
| I2C | SDA 8, SCL 9 |
| SPI | SCLK 12, MOSI 11, MISO 13, CS 10 |
| CAN | TX 4, RX 5 + SN65HVD230 transceiver |
| 1-Wire | 6 + 4.7k pull-up |
