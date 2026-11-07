#include "bridge_wifi.h"

#include "bridge_commands.h"

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "mdns.h"

#include <stdio.h>
#include <string.h>

#define AP_CHANNEL 1U
#define AP_MAX_CLIENTS 2U
#define SCAN_MAX_RESULTS 16U
#define IP_TEXT_LEN 16U
#define RECONNECT_DELAY_NOTE "station lost the network, retrying"

static const char *TAG = "bridge_wifi";

static esp_netif_t *s_station_netif;

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id,
                          void *event_data) {
    (void)arg;
    (void)base;
    (void)event_data;
    if (id == WIFI_EVENT_STA_START) {
        (void)esp_wifi_connect();
    } else if (id == WIFI_EVENT_STA_DISCONNECTED) {
        /* Keep trying: the router may come back. The access point stays
           up meanwhile, so the bridge is never unreachable. */
        ESP_LOGW(TAG, RECONNECT_DELAY_NOTE);
        (void)esp_wifi_connect();
    }
}

static void on_ip_event(void *arg, esp_event_base_t base, int32_t id,
                        void *event_data) {
    (void)arg;
    (void)base;
    (void)id;
    const ip_event_got_ip_t *event = event_data;
    ESP_LOGI(TAG, "station IP " IPSTR, IP2STR(&event->ip_info.ip));
}

static void start_mdns(void) {
    if (mdns_init() != ESP_OK) {
        ESP_LOGW(TAG, "mDNS not started");
        return;
    }
    (void)mdns_hostname_set("protolab-bridge");
    (void)mdns_instance_name_set("Protocol Lab bridge");
    (void)mdns_service_add(NULL, "_protolab", "_tcp", CONFIG_BRIDGE_TCP_PORT,
                           NULL, 0);
}

void BridgeWifi_Start(void) {
    ESP_ERROR_CHECK(esp_netif_init());
    s_station_netif = esp_netif_create_default_wifi_sta();
    (void)esp_netif_create_default_wifi_ap();
    wifi_init_config_t init_config = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init_config));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                               on_wifi_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                               on_ip_event, NULL));

    wifi_config_t ap_config = {
        .ap =
            {
                .channel = AP_CHANNEL,
                .max_connection = AP_MAX_CLIENTS,
                .authmode = WIFI_AUTH_WPA2_PSK,
            },
    };
    (void)strncpy((char *)ap_config.ap.ssid, CONFIG_BRIDGE_AP_SSID,
                  sizeof(ap_config.ap.ssid));
    ap_config.ap.ssid_len = (uint8_t)strlen(CONFIG_BRIDGE_AP_SSID);
    (void)strncpy((char *)ap_config.ap.password, CONFIG_BRIDGE_AP_PASSWORD,
                  sizeof(ap_config.ap.password));
    if (strlen(CONFIG_BRIDGE_AP_PASSWORD) == 0U) {
        ap_config.ap.authmode = WIFI_AUTH_OPEN;
    }
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_APSTA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &ap_config));
    ESP_ERROR_CHECK(esp_wifi_start());
    start_mdns();
}

static const char *auth_name(wifi_auth_mode_t mode) {
    switch (mode) {
    case WIFI_AUTH_OPEN:
        return "open";
    case WIFI_AUTH_WEP:
        return "WEP";
    case WIFI_AUTH_WPA_PSK:
        return "WPA";
    case WIFI_AUTH_WPA2_PSK:
    case WIFI_AUTH_WPA_WPA2_PSK:
        return "WPA2";
    case WIFI_AUTH_WPA3_PSK:
    case WIFI_AUTH_WPA2_WPA3_PSK:
        return "WPA3";
    default:
        return "other";
    }
}

static const char *status(json_writer_t *data) {
    wifi_config_t config;
    (void)esp_wifi_get_config(WIFI_IF_STA, &config);
    wifi_ap_record_t ap_info;
    bool is_joined = (esp_wifi_sta_get_ap_info(&ap_info) == ESP_OK);
    esp_netif_ip_info_t ip_info = {0};
    (void)esp_netif_get_ip_info(s_station_netif, &ip_info);
    char ip_text[IP_TEXT_LEN];
    (void)snprintf(ip_text, sizeof(ip_text), IPSTR, IP2STR(&ip_info.ip));

    JsonWriter_BeginObject(data, NULL);
    JsonWriter_AddText(data, "ssid", (const char *)config.sta.ssid);
    JsonWriter_AddBool(data, "joined", is_joined);
    JsonWriter_AddText(data, "ip", ip_text);
    if (is_joined) {
        JsonWriter_AddInt(data, "rssi", ap_info.rssi);
        JsonWriter_AddInt(data, "channel", ap_info.primary);
    }
    JsonWriter_AddText(data, "setup_ap", CONFIG_BRIDGE_AP_SSID);
    JsonWriter_EndObject(data);
    return NULL;
}

static const char *scan(json_writer_t *data) {
    if (esp_wifi_scan_start(NULL, true) != ESP_OK) {
        return "scan failed";
    }
    static wifi_ap_record_t records[SCAN_MAX_RESULTS];
    uint16_t count = SCAN_MAX_RESULTS;
    if (esp_wifi_scan_get_ap_records(&count, records) != ESP_OK) {
        return "scan failed";
    }
    JsonWriter_BeginArray(data, NULL);
    for (uint16_t i = 0U; i < count; i++) {
        JsonWriter_BeginObject(data, NULL);
        JsonWriter_AddText(data, "ssid", (const char *)records[i].ssid);
        JsonWriter_AddInt(data, "rssi", records[i].rssi);
        JsonWriter_AddInt(data, "channel", records[i].primary);
        JsonWriter_AddText(data, "auth", auth_name(records[i].authmode));
        JsonWriter_EndObject(data);
    }
    JsonWriter_EndArray(data);
    return NULL;
}

static const char *join(const bridge_request_t *request) {
    const char *error = NULL;
    if (!BridgeArgs_Has(request, 4U, "usage: wifi set <ssid> <password|->",
                        &error)) {
        return error;
    }
    const char *ssid = request->args[2];
    const char *password =
        (strcmp(request->args[3], "-") == 0) ? "" : request->args[3];
    wifi_config_t config = {0};
    if (strlen(ssid) >= sizeof(config.sta.ssid) ||
        strlen(password) >= sizeof(config.sta.password)) {
        return "ssid max 31, password max 63 characters";
    }
    (void)strncpy((char *)config.sta.ssid, ssid, sizeof(config.sta.ssid));
    (void)strncpy((char *)config.sta.password, password,
                  sizeof(config.sta.password));
    (void)esp_wifi_disconnect();
    if (esp_wifi_set_config(WIFI_IF_STA, &config) != ESP_OK) {
        return "could not save the network";
    }
    (void)esp_wifi_connect();
    return NULL;
}

const char *Cmd_Wifi(const bridge_request_t *request, json_writer_t *data) {
    if (request->arg_count < 2U) {
        return "usage: wifi status | scan | set";
    }
    if (strcmp(request->args[1], "status") == 0) {
        return status(data);
    }
    if (strcmp(request->args[1], "scan") == 0) {
        return scan(data);
    }
    if (strcmp(request->args[1], "set") == 0) {
        return join(request);
    }
    return "unknown wifi action";
}
