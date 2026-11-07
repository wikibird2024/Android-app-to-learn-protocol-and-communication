#include "bridge_commands.h"

#include "bridge_io.h"

#include "esp_now.h"

#include <stdio.h>
#include <string.h>

#define MAC_BYTES 6U
#define MAC_TEXT_LEN 18U
#define ESPNOW_EVENT_MAX_LEN 600U

/* Written by the command task only. */
static bool s_is_started;

static void on_receive(const esp_now_recv_info_t *info, const uint8_t *data,
                       int len) {
    /* Runs in the Wi-Fi task: format and hand over, nothing slow here. */
    static char line[ESPNOW_EVENT_MAX_LEN];
    char mac_text[MAC_TEXT_LEN];
    const uint8_t *mac = info->src_addr;
    (void)snprintf(mac_text, sizeof(mac_text), "%02x:%02x:%02x:%02x:%02x:%02x",
                   mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    json_writer_t writer;
    JsonWriter_Init(&writer, line, sizeof(line));
    JsonWriter_BeginObject(&writer, NULL);
    JsonWriter_AddText(&writer, "event", "espnow");
    JsonWriter_AddText(&writer, "mac", mac_text);
    JsonWriter_AddInt(&writer, "rssi", info->rx_ctrl->rssi);
    JsonWriter_AddHex(&writer, "data", data, (len > 0) ? (size_t)len : 0U);
    JsonWriter_EndObject(&writer);
    if (!writer.is_overflow) {
        BridgeIo_SendEvent(line);
    }
}

static bool parse_mac(const char *text, uint8_t *mac) {
    unsigned int parts[MAC_BYTES];
    if (sscanf(text, "%2x:%2x:%2x:%2x:%2x:%2x", &parts[0], &parts[1], &parts[2],
               &parts[3], &parts[4], &parts[5]) != (int)MAC_BYTES) {
        return false;
    }
    for (uint8_t i = 0U; i < MAC_BYTES; i++) {
        mac[i] = (uint8_t)parts[i];
    }
    return true;
}

static const char *send_frame(const bridge_request_t *request) {
    const char *error = NULL;
    if (!BridgeArgs_Has(request, 4U, "usage: espnow send <mac> <hex>",
                        &error)) {
        return error;
    }
    uint8_t mac[MAC_BYTES];
    if (!parse_mac(request->args[2], mac)) {
        return "mac like 24:6f:28:aa:bb:cc";
    }
    static uint8_t payload[ESP_NOW_MAX_DATA_LEN];
    int32_t len =
        BridgeProtocol_ParseHex(request->args[3], payload, sizeof(payload));
    if (len <= 0) {
        return "data: hex, 1..250 bytes";
    }
    if (!esp_now_is_peer_exist(mac)) {
        /* Channel 0 = the channel the radio is on now. */
        esp_now_peer_info_t peer = {0};
        memcpy(peer.peer_addr, mac, sizeof(mac));
        peer.ifidx = WIFI_IF_STA;
        if (esp_now_add_peer(&peer) != ESP_OK) {
            return "cannot add peer (peer list full?)";
        }
    }
    return (esp_now_send(mac, payload, (size_t)len) == ESP_OK) ? NULL
                                                               : "send failed";
}

const char *Cmd_EspNow(const bridge_request_t *request, json_writer_t *data) {
    (void)data;
    if (request->arg_count < 2U) {
        return "usage: espnow init | send";
    }
    if (strcmp(request->args[1], "init") == 0) {
        if (s_is_started) {
            return NULL;
        }
        if (esp_now_init() != ESP_OK ||
            esp_now_register_recv_cb(on_receive) != ESP_OK) {
            return "esp-now init failed";
        }
        s_is_started = true;
        return NULL;
    }
    if (!s_is_started) {
        return "esp-now not started: espnow init";
    }
    if (strcmp(request->args[1], "send") == 0) {
        return send_frame(request);
    }
    return "unknown espnow action";
}
