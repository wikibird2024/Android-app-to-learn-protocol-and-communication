#ifndef BRIDGE_WIFI_H
#define BRIDGE_WIFI_H

/* Starts Wi-Fi as access point + station. The access point
   (CONFIG_BRIDGE_AP_SSID, 192.168.4.1) is always on, so the phone can reach
   the bridge before it knows any network; the station joins the network
   saved with "wifi set" (kept in NVS by the Wi-Fi driver). Also announces
   the bridge by mDNS as _protolab._tcp. Needs NVS and the default event
   loop first. */
void BridgeWifi_Start(void);

#endif
