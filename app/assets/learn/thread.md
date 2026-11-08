# Thread

*IPv6 mesh on 802.15.4 (the network under Matter)*

Same radio as Zigbee, a different stack:

```text
802.15.4 → 6LoWPAN → IPv6 → UDP
         → CoAP / Matter
```

Every device has an IPv6 address. A **border router** (Home Assistant,
Apple TV, Nest hub) connects the mesh to Wi-Fi / Ethernet.

## Roles

Leader, router, end device (can sleep).

## Dataset

Network name, PAN id, channel, network key and extended PAN id.
`dataset active` shows it.

## OpenThread CLI

OpenThread is the community stack ESP-IDF uses. Try these in order:

```text
dataset init new
dataset commit active
ifconfig up
thread start
state          → leader
ipaddr
```

Matter commissioning (adding a device to a phone ecosystem) needs Google
Play services on Android; it is not built here.

Needs an ESP32-C6 or H2.
