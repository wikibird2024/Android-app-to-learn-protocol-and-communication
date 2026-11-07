#include "bridge_commands.h"

#include "bridge_io.h"

#include "esp_log.h"
#include "esp_zigbee.h"
#include "ezbee/zha.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include <stdio.h>
#include <string.h>

/* Zigbee coordinator on the C6/H2 802.15.4 radio, built on Espressif's
   esp-zigbee-lib (same calls as its on_off_switch and zigbee_gateway
   examples). The stack runs in its own task; every call into it from the
   command task holds esp_zigbee_lock, which also guards s_devices. */

#define ZIGBEE_ENDPOINT 1U
#define ZIGBEE_MAX_CHILDREN 10U
#define ZIGBEE_MAX_DEVICES 16U
#define ZIGBEE_TASK_STACK_BYTES 6144U
#define ZIGBEE_TASK_PRIORITY 5U
#define ZIGBEE_LOCK_TIMEOUT_MS 1000U
#define ZIGBEE_PERMIT_MAX_S 254U
#define ZIGBEE_EVENT_MAX_LEN 160U
#define IEEE_TEXT_LEN 17U
#define SHORT_TEXT_LEN 5U
#define EUI64_BYTES 8U
#define ENDPOINT_MAX 240U
#define SHORT_ADDRESS_MAX 0xFFF7U

static const char *TAG = "bridge_zigbee";

typedef struct {
    uint16_t short_address;
    uint64_t ieee_address;
} zigbee_device_t;

static zigbee_device_t s_devices[ZIGBEE_MAX_DEVICES];
static uint8_t s_device_count;
static bool s_is_started;     /* command task only */
static volatile bool s_is_up; /* written by the Zigbee task */

static void ieee_text(uint64_t address, char *text) {
    (void)snprintf(text, IEEE_TEXT_LEN, "%016llx", (unsigned long long)address);
}

static void send_event(const char *type, uint16_t short_address,
                       uint64_t ieee_address) {
    char line[ZIGBEE_EVENT_MAX_LEN];
    char short_text[SHORT_TEXT_LEN];
    char ieee[IEEE_TEXT_LEN];
    (void)snprintf(short_text, sizeof(short_text), "%04x", short_address);
    ieee_text(ieee_address, ieee);
    json_writer_t writer;
    JsonWriter_Init(&writer, line, sizeof(line));
    JsonWriter_BeginObject(&writer, NULL);
    JsonWriter_AddText(&writer, "event", "zigbee");
    JsonWriter_AddText(&writer, "type", type);
    JsonWriter_AddText(&writer, "short", short_text);
    JsonWriter_AddText(&writer, "ieee", ieee);
    JsonWriter_EndObject(&writer);
    if (!writer.is_overflow) {
        BridgeIo_SendEvent(line);
    }
}

/* Runs in the Zigbee task (stack lock held). */
static void remember_device(uint16_t short_address, uint64_t ieee_address) {
    for (uint8_t i = 0U; i < s_device_count; i++) {
        if (s_devices[i].ieee_address == ieee_address) {
            s_devices[i].short_address = short_address; /* rejoin */
            return;
        }
    }
    if (s_device_count < ZIGBEE_MAX_DEVICES) {
        s_devices[s_device_count].short_address = short_address;
        s_devices[s_device_count].ieee_address = ieee_address;
        s_device_count++;
    }
}

static bool on_signal(const ezb_app_signal_t *signal) {
    ezb_app_signal_type_t type = ezb_app_signal_get_type(signal);
    switch (type) {
    case EZB_ZDO_SIGNAL_SKIP_STARTUP:
        (void)ezb_bdb_start_top_level_commissioning(
            EZB_BDB_MODE_INITIALIZATION);
        break;
    case EZB_BDB_SIGNAL_DEVICE_FIRST_START:
    case EZB_BDB_SIGNAL_DEVICE_REBOOT: {
        ezb_bdb_comm_status_t status =
            *(const ezb_bdb_comm_status_t *)ezb_app_signal_get_params(signal);
        if (status != EZB_BDB_STATUS_SUCCESS) {
            ESP_LOGW(TAG, "start failed (0x%02x)", status);
        } else if (ezb_bdb_is_factory_new()) {
            (void)ezb_bdb_start_top_level_commissioning(
                EZB_BDB_MODE_NETWORK_FORMATION);
        } else {
            s_is_up = true; /* network kept from before the reboot */
        }
        break;
    }
    case EZB_BDB_SIGNAL_FORMATION: {
        ezb_bdb_comm_status_t status =
            *(const ezb_bdb_comm_status_t *)ezb_app_signal_get_params(signal);
        s_is_up = (status == EZB_BDB_STATUS_SUCCESS);
        ESP_LOGI(TAG, "formation %s, PAN 0x%04x channel %d",
                 s_is_up ? "ok" : "failed", ezb_nwk_get_panid(),
                 ezb_nwk_get_current_channel());
        break;
    }
    case EZB_ZDO_SIGNAL_DEVICE_ANNCE: {
        const ezb_zdo_signal_device_annce_params_t *params =
            ezb_app_signal_get_params(signal);
        remember_device(params->short_addr, params->device_addr.u64);
        send_event("joined", params->short_addr, params->device_addr.u64);
        break;
    }
    default:
        break;
    }
    return true;
}

static void zigbee_task(void *arg) {
    (void)arg;
    esp_zigbee_config_t config = {
        .device_config =
            {
                .device_type = EZB_NWK_DEVICE_TYPE_COORDINATOR,
                .install_code_policy = false,
                .zczr_config = {.max_children = ZIGBEE_MAX_CHILDREN},
            },
        .platform_config =
            {
                .storage_partition_name = "nvs",
                .radio_config = {.radio_mode = ESP_ZIGBEE_RADIO_MODE_NATIVE},
            },
    };
    ESP_ERROR_CHECK(esp_zigbee_init(&config));
    ESP_ERROR_CHECK(ezb_app_signal_add_handler(on_signal));
    /* Our endpoint is an on/off switch: it owns the On/Off client
       cluster that sends on, off and toggle to the lights. */
    ezb_af_device_desc_t device = ezb_af_create_device_desc();
    ezb_zha_on_off_switch_config_t switch_config =
        EZB_ZHA_ON_OFF_SWITCH_CONFIG();
    ezb_af_ep_desc_t endpoint =
        ezb_zha_create_on_off_switch(ZIGBEE_ENDPOINT, &switch_config);
    ESP_ERROR_CHECK(ezb_af_device_add_endpoint_desc(device, endpoint));
    ESP_ERROR_CHECK(ezb_af_device_desc_register(device));
    ESP_ERROR_CHECK(esp_zigbee_start(false));
    (void)esp_zigbee_launch_mainloop();
    (void)esp_zigbee_deinit();
    vTaskDelete(NULL);
}

static bool lock_stack(void) {
    return esp_zigbee_lock_acquire(pdMS_TO_TICKS(ZIGBEE_LOCK_TIMEOUT_MS));
}

static const char *list_devices(json_writer_t *data) {
    if (!lock_stack()) {
        return "zigbee stack busy";
    }
    JsonWriter_BeginArray(data, NULL);
    for (uint8_t i = 0U; i < s_device_count; i++) {
        char short_text[SHORT_TEXT_LEN];
        char ieee[IEEE_TEXT_LEN];
        (void)snprintf(short_text, sizeof(short_text), "%04x",
                       s_devices[i].short_address);
        ieee_text(s_devices[i].ieee_address, ieee);
        JsonWriter_BeginObject(data, NULL);
        JsonWriter_AddText(data, "short", short_text);
        JsonWriter_AddText(data, "ieee", ieee);
        JsonWriter_EndObject(data);
    }
    JsonWriter_EndArray(data);
    esp_zigbee_lock_release();
    return NULL;
}

static const char *permit_join(const bridge_request_t *request) {
    const char *error = NULL;
    uint32_t seconds = 0U;
    if (!BridgeArgs_Uint(request, 2U, ZIGBEE_PERMIT_MAX_S, &seconds, &error)) {
        return "usage: zb permit <seconds 0..254>";
    }
    if (!lock_stack()) {
        return "zigbee stack busy";
    }
    ezb_err_t result = ezb_bdb_open_network((uint8_t)seconds);
    esp_zigbee_lock_release();
    return (result == EZB_ERR_NONE) ? NULL : "permit join failed";
}

static const char *switch_on_off(const bridge_request_t *request) {
    const char *error = NULL;
    if (!BridgeArgs_Has(request, 5U,
                        "usage: zb onoff <short hex> <ep> <on|off|toggle>",
                        &error)) {
        return error;
    }
    char short_text[SHORT_TEXT_LEN + 2U];
    (void)snprintf(short_text, sizeof(short_text), "0x%s", request->args[2]);
    uint32_t short_address = 0U;
    uint32_t endpoint = 0U;
    if (!BridgeProtocol_ParseUint(short_text, SHORT_ADDRESS_MAX,
                                  &short_address) ||
        !BridgeArgs_Uint(request, 3U, ENDPOINT_MAX, &endpoint, &error)) {
        return "short address: hex; endpoint: 1..240";
    }
    ezb_zcl_on_off_cmd_t command = {
        .cmd_ctrl =
            {
                .dst_addr = {.addr_mode = EZB_ADDR_MODE_SHORT,
                             .u.short_addr = (uint16_t)short_address},
                .dst_ep = (uint8_t)endpoint,
                .src_ep = ZIGBEE_ENDPOINT,
            },
    };
    const char *action = request->args[4];
    if (!lock_stack()) {
        return "zigbee stack busy";
    }
    ezb_err_t result = EZB_ERR_FAIL;
    if (strcmp(action, "on") == 0) {
        result = ezb_zcl_on_off_on_cmd_req(&command);
    } else if (strcmp(action, "off") == 0) {
        result = ezb_zcl_on_off_off_cmd_req(&command);
    } else if (strcmp(action, "toggle") == 0) {
        result = ezb_zcl_on_off_toggle_cmd_req(&command);
    } else {
        esp_zigbee_lock_release();
        return "action: on, off or toggle";
    }
    esp_zigbee_lock_release();
    return (result == EZB_ERR_NONE) ? NULL : "send failed";
}

const char *Cmd_Zigbee(const bridge_request_t *request, json_writer_t *data) {
    if (request->arg_count < 2U) {
        return "usage: zb form | permit | devices | onoff";
    }
    const char *action = request->args[1];
    if (strcmp(action, "form") == 0) {
        if (!s_is_started) {
            if (xTaskCreate(zigbee_task, "zigbee", ZIGBEE_TASK_STACK_BYTES,
                            NULL, ZIGBEE_TASK_PRIORITY, NULL) != pdPASS) {
                return "no memory for the zigbee task";
            }
            s_is_started = true;
        }
        return NULL;
    }
    if (!s_is_started || !s_is_up) {
        return "network not up yet: zb form, then wait a few seconds";
    }
    if (strcmp(action, "permit") == 0) {
        return permit_join(request);
    }
    if (strcmp(action, "devices") == 0) {
        return list_devices(data);
    }
    if (strcmp(action, "onoff") == 0) {
        return switch_on_off(request);
    }
    return "unknown zb action";
}
