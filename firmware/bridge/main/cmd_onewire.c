#include "bridge_commands.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "onewire_bus.h"
#include "onewire_cmd.h"
#include "onewire_device.h"

#include <string.h>

#define ONEWIRE_MAX_DEVICES 8U
#define ONEWIRE_ROM_BYTES 8U
#define ONEWIRE_RX_BYTES 10U
#define DS18B20_CMD_CONVERT_T 0x44U
#define DS18B20_CMD_READ_SCRATCHPAD 0xBEU
#define DS18B20_SCRATCHPAD_BYTES 9U
#define DS18B20_CONVERSION_MS 750U
#define GPIO_MAX 48U
#define BITS_PER_BYTE 8U

/* Only the command task touches this (see bridge_commands.h). */
static onewire_bus_handle_t s_bus;

/* The component keeps the ROM as a uint64 with the family code in the
   lowest byte; on the wire (and in the app) the family code comes first. */
static void rom_to_bytes(onewire_device_address_t address, uint8_t *rom) {
    for (uint8_t i = 0U; i < ONEWIRE_ROM_BYTES; i++) {
        rom[i] = (uint8_t)(address >> (i * BITS_PER_BYTE));
    }
}

static const char *init_bus(const bridge_request_t *request) {
    const char *error = NULL;
    uint32_t pin = 0U;
    if (!BridgeArgs_Uint(request, 2U, GPIO_MAX, &pin, &error)) {
        return "usage: ow init <pin>";
    }
    if (s_bus != NULL) {
        (void)onewire_bus_del(s_bus);
        s_bus = NULL;
    }
    onewire_bus_config_t bus_config = {
        .bus_gpio_num = (int)pin,
        .flags.en_pull_up = true,
    };
    onewire_bus_rmt_config_t rmt_config = {
        .max_rx_bytes = ONEWIRE_RX_BYTES,
    };
    if (onewire_new_bus_rmt(&bus_config, &rmt_config, &s_bus) != ESP_OK) {
        s_bus = NULL;
        return "1-Wire init failed (pin or RMT channel in use?)";
    }
    return NULL;
}

static const char *search(json_writer_t *data) {
    onewire_device_iter_handle_t iterator = NULL;
    if (onewire_new_device_iter(s_bus, &iterator) != ESP_OK) {
        return "search failed";
    }
    JsonWriter_BeginArray(data, NULL);
    onewire_device_t device;
    uint8_t found = 0U;
    while (found < ONEWIRE_MAX_DEVICES &&
           onewire_device_iter_get_next(iterator, &device) == ESP_OK) {
        uint8_t rom[ONEWIRE_ROM_BYTES];
        rom_to_bytes(device.address, rom);
        JsonWriter_AddHex(data, NULL, rom, sizeof(rom));
        found++;
    }
    JsonWriter_EndArray(data);
    (void)onewire_del_device_iter(iterator);
    return NULL;
}

static const char *read_ds18b20(const bridge_request_t *request,
                                json_writer_t *data) {
    const char *error = NULL;
    if (!BridgeArgs_Has(request, 3U, "usage: ow ds18b20 <rom>", &error)) {
        return error;
    }
    uint8_t rom[ONEWIRE_ROM_BYTES];
    if (BridgeProtocol_ParseHex(request->args[2], rom, sizeof(rom)) !=
        (int32_t)ONEWIRE_ROM_BYTES) {
        return "rom: 16 hex digits";
    }
    uint8_t select[1U + ONEWIRE_ROM_BYTES] = {ONEWIRE_CMD_MATCH_ROM};
    memcpy(&select[1], rom, sizeof(rom));

    if (onewire_bus_reset(s_bus) != ESP_OK) {
        return "no presence pulse (wiring or pull-up?)";
    }
    uint8_t convert = DS18B20_CMD_CONVERT_T;
    if (onewire_bus_write_bytes(s_bus, select, sizeof(select)) != ESP_OK ||
        onewire_bus_write_bytes(s_bus, &convert, 1U) != ESP_OK) {
        return "write failed";
    }
    vTaskDelay(pdMS_TO_TICKS(DS18B20_CONVERSION_MS));

    uint8_t read_command = DS18B20_CMD_READ_SCRATCHPAD;
    uint8_t scratchpad[DS18B20_SCRATCHPAD_BYTES];
    if (onewire_bus_reset(s_bus) != ESP_OK ||
        onewire_bus_write_bytes(s_bus, select, sizeof(select)) != ESP_OK ||
        onewire_bus_write_bytes(s_bus, &read_command, 1U) != ESP_OK ||
        onewire_bus_read_bytes(s_bus, scratchpad, sizeof(scratchpad)) !=
            ESP_OK) {
        return "read failed";
    }
    /* CRC is checked by the app, which also shows why it failed. */
    JsonWriter_BeginObject(data, NULL);
    JsonWriter_AddHex(data, "scratchpad", scratchpad, sizeof(scratchpad));
    JsonWriter_EndObject(data);
    return NULL;
}

const char *Cmd_OneWire(const bridge_request_t *request, json_writer_t *data) {
    if (request->arg_count < 2U) {
        return "usage: ow init | search | ds18b20";
    }
    if (strcmp(request->args[1], "init") == 0) {
        return init_bus(request);
    }
    if (s_bus == NULL) {
        return "1-Wire not initialised: ow init <pin>";
    }
    if (strcmp(request->args[1], "search") == 0) {
        return search(data);
    }
    if (strcmp(request->args[1], "ds18b20") == 0) {
        return read_ds18b20(request, data);
    }
    return "unknown ow action";
}
