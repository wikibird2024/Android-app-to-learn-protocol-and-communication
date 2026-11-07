#include "bridge_commands.h"

#include "esp_mac.h"
#include "sdkconfig.h"

#include <stdio.h>

#define BRIDGE_FIRMWARE_VERSION "0.1.0"
#define MAC_TEXT_LEN 18U

static const bridge_command_t s_commands[] = {
    {"ping", "ping", Cmd_Ping},
    {"help", "help", Cmd_Help},
    {"i2c", "i2c init <sda> <scl> <hz> | scan | xfer <addr> <hex|-> <len>",
     Cmd_I2c},
    {"spi", "spi init <sclk> <mosi> <miso> <cs> <hz> <mode> | xfer <hex>",
     Cmd_Spi},
    {"can",
     "can init <tx> <rx> <bitrate> | send <id> <hex|-> [ext] [rtr] | status | "
     "stop",
     Cmd_Can},
    {"ow", "ow init <pin> | search | ds18b20 <rom>", Cmd_OneWire},
    {"wifi", "wifi status | scan | set <ssid> <password|->", Cmd_Wifi},
    {"espnow", "espnow init | send <mac> <hex>", Cmd_EspNow},
#if CONFIG_BRIDGE_ZIGBEE
    {"zb",
     "zb form | permit <s> | devices | onoff <short> <ep> <on|off|toggle>",
     Cmd_Zigbee},
#endif
};

const bridge_command_t *BridgeCommands_Table(size_t *count) {
    *count = sizeof(s_commands) / sizeof(s_commands[0]);
    return s_commands;
}

bool BridgeArgs_Has(const bridge_request_t *request, uint8_t count,
                    const char *usage, const char **error) {
    if (request->arg_count < count) {
        *error = usage;
        return false;
    }
    return true;
}

bool BridgeArgs_Uint(const bridge_request_t *request, uint8_t index,
                     uint32_t max_value, uint32_t *value, const char **error) {
    if (index >= request->arg_count ||
        !BridgeProtocol_ParseUint(request->args[index], max_value, value)) {
        *error = "number missing or out of range";
        return false;
    }
    return true;
}

const char *Cmd_Ping(const bridge_request_t *request, json_writer_t *data) {
    (void)request;
    uint8_t mac[6];
    char mac_text[MAC_TEXT_LEN];
    (void)esp_read_mac(mac, ESP_MAC_WIFI_STA);
    (void)snprintf(mac_text, sizeof(mac_text), "%02x:%02x:%02x:%02x:%02x:%02x",
                   mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    JsonWriter_BeginObject(data, NULL);
    JsonWriter_AddText(data, "name", "protolab-bridge");
    JsonWriter_AddText(data, "version", BRIDGE_FIRMWARE_VERSION);
    JsonWriter_AddText(data, "target", CONFIG_IDF_TARGET);
    JsonWriter_AddText(data, "mac", mac_text);
    JsonWriter_BeginArray(data, "features");
    JsonWriter_AddText(data, NULL, "i2c");
    JsonWriter_AddText(data, NULL, "spi");
    JsonWriter_AddText(data, NULL, "can");
    JsonWriter_AddText(data, NULL, "onewire");
    JsonWriter_AddText(data, NULL, "espnow");
#if CONFIG_BRIDGE_ZIGBEE
    JsonWriter_AddText(data, NULL, "zigbee");
#endif
    JsonWriter_EndArray(data);
    JsonWriter_EndObject(data);
    return NULL;
}

const char *Cmd_Help(const bridge_request_t *request, json_writer_t *data) {
    (void)request;
    size_t count = 0U;
    const bridge_command_t *table = BridgeCommands_Table(&count);
    JsonWriter_BeginArray(data, NULL);
    for (size_t i = 0U; i < count; i++) {
        JsonWriter_BeginObject(data, NULL);
        JsonWriter_AddText(data, "name", table[i].name);
        JsonWriter_AddText(data, "usage", table[i].usage);
        JsonWriter_EndObject(data);
    }
    JsonWriter_EndArray(data);
    return NULL;
}
