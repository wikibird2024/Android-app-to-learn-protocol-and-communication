# mDNS + DNS-SD

*Find devices by name, no server*

```text
phone: "who has _http._tcp.local?"
   │  UDP 224.0.0.251:5353 (multicast)
   ▼
every device answers for itself:
  PTR  _http._tcp → Kitchen._http._tcp
  SRV  Kitchen…   → esp32-kitchen.local:80
  TXT  Kitchen…   → path=/api version=2
  A    esp32-kitchen.local → 192.168.1.42
```

## Service types

Written `_name._tcp` or `_name._udp`.

| Type | Who |
|---|---|
| `_http._tcp` | web servers |
| `_mqtt._tcp` | brokers |
| `_protolab._tcp` | this app's ESP32 bridge |

## ESP-IDF

With the `espressif/mdns` component:

```c
mdns_init();
mdns_hostname_set("bridge");
mdns_service_add(NULL, "_protolab", "_tcp",
                 3333, NULL, 0);
```

## Gotchas

- Only works on the same LAN segment (224.0.0.251 is not routed).
- Android needs a multicast lock; guest Wi-Fi often blocks multicast.
- Not every Android version resolves `name.local` in a URL: use the IP
  that was found.
