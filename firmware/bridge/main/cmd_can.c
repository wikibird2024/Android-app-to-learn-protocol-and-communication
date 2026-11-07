#include "bridge_commands.h"

#include "bridge_io.h"

#include "driver/twai.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include <stdio.h>
#include <string.h>

#define CAN_MAX_DATA_BYTES 8U
#define CAN_STANDARD_ID_MAX 0x7FFU
#define CAN_EXTENDED_ID_MAX 0x1FFFFFFFU
#define CAN_BITRATE_MAX 1000000U
#define CAN_TX_TIMEOUT_MS 100U
#define CAN_RX_POLL_MS 100U
#define CAN_RX_STACK_BYTES 4096U
#define CAN_RX_PRIORITY 6U
#define CAN_EVENT_MAX_LEN 128U
#define GPIO_MAX 48U
#define ID_TEXT_LEN 12U

/* s_is_running: written by the command task, read by the rx task, which
   stops itself when it turns false and then clears s_is_rx_alive. */
static volatile bool s_is_running;
static volatile bool s_is_rx_alive;

static bool timing_for(uint32_t bitrate, twai_timing_config_t *timing) {
    static const twai_timing_config_t timing_125k =
        TWAI_TIMING_CONFIG_125KBITS();
    static const twai_timing_config_t timing_250k =
        TWAI_TIMING_CONFIG_250KBITS();
    static const twai_timing_config_t timing_500k =
        TWAI_TIMING_CONFIG_500KBITS();
    static const twai_timing_config_t timing_1m = TWAI_TIMING_CONFIG_1MBITS();
    switch (bitrate) {
    case 125000U:
        *timing = timing_125k;
        return true;
    case 250000U:
        *timing = timing_250k;
        return true;
    case 500000U:
        *timing = timing_500k;
        return true;
    case 1000000U:
        *timing = timing_1m;
        return true;
    default:
        return false;
    }
}

static void rx_task(void *arg) {
    (void)arg;
    char line[CAN_EVENT_MAX_LEN];
    char id_text[ID_TEXT_LEN];
    while (s_is_running) {
        twai_message_t message;
        if (twai_receive(&message, pdMS_TO_TICKS(CAN_RX_POLL_MS)) != ESP_OK) {
            continue;
        }
        uint8_t len = (message.data_length_code > CAN_MAX_DATA_BYTES)
                          ? CAN_MAX_DATA_BYTES
                          : message.data_length_code;
        json_writer_t writer;
        JsonWriter_Init(&writer, line, sizeof(line));
        (void)snprintf(id_text, sizeof(id_text), "%lx",
                       (unsigned long)message.identifier);
        JsonWriter_BeginObject(&writer, NULL);
        JsonWriter_AddText(&writer, "event", "can");
        JsonWriter_AddText(&writer, "id", id_text);
        JsonWriter_AddBool(&writer, "ext", message.extd != 0U);
        JsonWriter_AddBool(&writer, "rtr", message.rtr != 0U);
        JsonWriter_AddHex(&writer, "data", message.data,
                          message.rtr ? 0U : len);
        JsonWriter_EndObject(&writer);
        if (!writer.is_overflow) {
            BridgeIo_SendEvent(line);
        }
    }
    s_is_rx_alive = false;
    vTaskDelete(NULL);
}

static void stop_bus(void) {
    if (!s_is_running) {
        return;
    }
    s_is_running = false;
    /* Let the rx task see the flag and leave twai_receive first. */
    while (s_is_rx_alive) {
        vTaskDelay(pdMS_TO_TICKS(CAN_RX_POLL_MS));
    }
    (void)twai_stop();
    (void)twai_driver_uninstall();
}

static const char *start_bus(const bridge_request_t *request) {
    const char *error = NULL;
    uint32_t tx_pin = 0U;
    uint32_t rx_pin = 0U;
    uint32_t bitrate = 0U;
    twai_timing_config_t timing;
    if (!BridgeArgs_Uint(request, 2U, GPIO_MAX, &tx_pin, &error) ||
        !BridgeArgs_Uint(request, 3U, GPIO_MAX, &rx_pin, &error) ||
        !BridgeArgs_Uint(request, 4U, CAN_BITRATE_MAX, &bitrate, &error)) {
        return "usage: can init <tx> <rx> <bitrate>";
    }
    if (!timing_for(bitrate, &timing)) {
        return "bitrate: 125000, 250000, 500000 or 1000000";
    }
    stop_bus();
    twai_general_config_t general = TWAI_GENERAL_CONFIG_DEFAULT(
        (gpio_num_t)tx_pin, (gpio_num_t)rx_pin, TWAI_MODE_NORMAL);
    twai_filter_config_t filter = TWAI_FILTER_CONFIG_ACCEPT_ALL();
    if (twai_driver_install(&general, &timing, &filter) != ESP_OK) {
        return "twai driver install failed";
    }
    if (twai_start() != ESP_OK) {
        (void)twai_driver_uninstall();
        return "twai start failed";
    }
    s_is_running = true;
    s_is_rx_alive = true;
    if (xTaskCreate(rx_task, "can_rx", CAN_RX_STACK_BYTES, NULL,
                    CAN_RX_PRIORITY, NULL) != pdPASS) {
        s_is_rx_alive = false;
        stop_bus();
        return "no memory for the rx task";
    }
    return NULL;
}

static const char *send_frame(const bridge_request_t *request) {
    const char *error = NULL;
    if (!BridgeArgs_Has(request, 4U, "usage: can send <id> <hex|-> [ext] [rtr]",
                        &error)) {
        return error;
    }
    twai_message_t message = {0};
    for (uint8_t i = 4U; i < request->arg_count; i++) {
        if (strcmp(request->args[i], "ext") == 0) {
            message.extd = 1U;
        } else if (strcmp(request->args[i], "rtr") == 0) {
            message.rtr = 1U;
        } else {
            return "flags: ext, rtr";
        }
    }
    /* The id is always hex, as CAN tools write it. */
    char id_text[ID_TEXT_LEN];
    (void)snprintf(id_text, sizeof(id_text), "0x%s", request->args[2]);
    uint32_t id = 0U;
    uint32_t id_max = message.extd ? CAN_EXTENDED_ID_MAX : CAN_STANDARD_ID_MAX;
    if (!BridgeProtocol_ParseUint(id_text, id_max, &id)) {
        return message.extd ? "id: hex up to 1fffffff" : "id: hex up to 7ff";
    }
    message.identifier = id;
    if (strcmp(request->args[3], "-") != 0) {
        int32_t len = BridgeProtocol_ParseHex(request->args[3], message.data,
                                              CAN_MAX_DATA_BYTES);
        if (len < 0) {
            return "data: hex, 0..8 bytes";
        }
        message.data_length_code = (uint8_t)len;
    }
    esp_err_t result =
        twai_transmit(&message, pdMS_TO_TICKS(CAN_TX_TIMEOUT_MS));
    if (result == ESP_ERR_TIMEOUT) {
        return "tx queue full (no other node ACKs?)";
    }
    return (result == ESP_OK) ? NULL : "send failed (bus-off?)";
}

static const char *status(json_writer_t *data) {
    twai_status_info_t info;
    if (twai_get_status_info(&info) != ESP_OK) {
        return "can not started";
    }
    static const char *const state_names[] = {"stopped", "running", "bus-off",
                                              "recovering"};
    JsonWriter_BeginObject(data, NULL);
    JsonWriter_AddText(data, "state",
                       (info.state <= TWAI_STATE_RECOVERING)
                           ? state_names[info.state]
                           : "unknown");
    JsonWriter_AddInt(data, "tx_errors", info.tx_error_counter);
    JsonWriter_AddInt(data, "rx_errors", info.rx_error_counter);
    JsonWriter_AddInt(data, "bus_errors", info.bus_error_count);
    JsonWriter_AddInt(data, "rx_missed", info.rx_missed_count);
    JsonWriter_EndObject(data);
    return NULL;
}

const char *Cmd_Can(const bridge_request_t *request, json_writer_t *data) {
    if (request->arg_count < 2U) {
        return "usage: can init | send | status | stop";
    }
    const char *action = request->args[1];
    if (strcmp(action, "init") == 0) {
        return start_bus(request);
    }
    if (strcmp(action, "stop") == 0) {
        stop_bus();
        return NULL;
    }
    if (!s_is_running) {
        return "can not started: can init <tx> <rx> <bitrate>";
    }
    if (strcmp(action, "send") == 0) {
        return send_frame(request);
    }
    if (strcmp(action, "status") == 0) {
        return status(data);
    }
    return "unknown can action";
}
