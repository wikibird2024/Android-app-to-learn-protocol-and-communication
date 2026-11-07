#include "bridge_commands.h"

#include "driver/i2c_master.h"

#include <string.h>

#define I2C_ADDRESS_FIRST 0x08U
#define I2C_ADDRESS_LAST 0x77U
#define I2C_TIMEOUT_MS 50
#define I2C_MAX_TRANSFER_BYTES 64U
#define I2C_MAX_HZ 1000000U
#define I2C_MIN_HZ 1000U
#define I2C_GLITCH_FILTER_CYCLES 7U
#define GPIO_MAX 48U

/* Only the command task touches these (see bridge_commands.h). */
static i2c_master_bus_handle_t s_bus;
static uint32_t s_speed_hz;

static void close_bus(void) {
    if (s_bus != NULL) {
        (void)i2c_del_master_bus(s_bus);
        s_bus = NULL;
    }
}

static const char *init_bus(const bridge_request_t *request) {
    const char *error = NULL;
    uint32_t sda = 0U;
    uint32_t scl = 0U;
    uint32_t speed_hz = 0U;
    if (!BridgeArgs_Uint(request, 2U, GPIO_MAX, &sda, &error) ||
        !BridgeArgs_Uint(request, 3U, GPIO_MAX, &scl, &error) ||
        !BridgeArgs_Uint(request, 4U, I2C_MAX_HZ, &speed_hz, &error)) {
        return "usage: i2c init <sda> <scl> <hz>";
    }
    if (speed_hz < I2C_MIN_HZ) {
        return "clock below 1000 Hz";
    }
    close_bus();
    i2c_master_bus_config_t config = {
        .i2c_port = -1,
        .sda_io_num = (gpio_num_t)sda,
        .scl_io_num = (gpio_num_t)scl,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = I2C_GLITCH_FILTER_CYCLES,
        .flags.enable_internal_pullup = true,
    };
    if (i2c_new_master_bus(&config, &s_bus) != ESP_OK) {
        s_bus = NULL;
        return "i2c bus init failed (pins in use?)";
    }
    s_speed_hz = speed_hz;
    return NULL;
}

static const char *scan(json_writer_t *data) {
    JsonWriter_BeginArray(data, NULL);
    for (uint16_t address = I2C_ADDRESS_FIRST; address <= I2C_ADDRESS_LAST;
         address++) {
        if (i2c_master_probe(s_bus, address, I2C_TIMEOUT_MS) == ESP_OK) {
            JsonWriter_AddInt(data, NULL, address);
        }
    }
    JsonWriter_EndArray(data);
    return NULL;
}

static const char *transfer(const bridge_request_t *request,
                            json_writer_t *data) {
    const char *error = NULL;
    uint32_t address = 0U;
    uint32_t read_len = 0U;
    if (!BridgeArgs_Has(request, 5U, "usage: i2c xfer <addr> <hex|-> <len>",
                        &error) ||
        !BridgeArgs_Uint(request, 2U, I2C_ADDRESS_LAST, &address, &error) ||
        !BridgeArgs_Uint(request, 4U, I2C_MAX_TRANSFER_BYTES, &read_len,
                         &error)) {
        return error;
    }
    uint8_t written[I2C_MAX_TRANSFER_BYTES];
    int32_t written_len = 0;
    if (strcmp(request->args[3], "-") != 0) {
        written_len =
            BridgeProtocol_ParseHex(request->args[3], written, sizeof(written));
        if (written_len < 0) {
            return "write bytes: hex, max 64";
        }
    }
    if (written_len == 0 && read_len == 0U) {
        return "nothing to write or read";
    }
    i2c_device_config_t device_config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = (uint16_t)address,
        .scl_speed_hz = s_speed_hz,
    };
    i2c_master_dev_handle_t device = NULL;
    if (i2c_master_bus_add_device(s_bus, &device_config, &device) != ESP_OK) {
        return "cannot add device";
    }
    uint8_t read[I2C_MAX_TRANSFER_BYTES];
    esp_err_t result;
    if (read_len == 0U) {
        result = i2c_master_transmit(device, written, (size_t)written_len,
                                     I2C_TIMEOUT_MS);
    } else if (written_len == 0) {
        result = i2c_master_receive(device, read, read_len, I2C_TIMEOUT_MS);
    } else {
        result =
            i2c_master_transmit_receive(device, written, (size_t)written_len,
                                        read, read_len, I2C_TIMEOUT_MS);
    }
    (void)i2c_master_bus_rm_device(device);
    if (result != ESP_OK) {
        return (result == ESP_ERR_TIMEOUT) ? "timeout (SDA/SCL stuck?)"
                                           : "no ACK (wrong address?)";
    }
    JsonWriter_BeginObject(data, NULL);
    JsonWriter_AddHex(data, "read", read, read_len);
    JsonWriter_EndObject(data);
    return NULL;
}

const char *Cmd_I2c(const bridge_request_t *request, json_writer_t *data) {
    if (request->arg_count < 2U) {
        return "usage: i2c init | scan | xfer";
    }
    const char *action = request->args[1];
    if (strcmp(action, "init") == 0) {
        return init_bus(request);
    }
    if (s_bus == NULL) {
        return "i2c not initialised: i2c init <sda> <scl> <hz>";
    }
    if (strcmp(action, "scan") == 0) {
        return scan(data);
    }
    if (strcmp(action, "xfer") == 0) {
        return transfer(request, data);
    }
    return "unknown i2c action";
}
