#include "bridge_commands.h"

#include "driver/spi_master.h"

#include <string.h>

#define SPI_HOST_USED SPI2_HOST
#define SPI_MAX_TRANSFER_BYTES 64U
#define SPI_MAX_HZ 80000000U
#define SPI_MIN_HZ 1000U
#define SPI_MODE_MAX 3U
#define SPI_QUEUE_SIZE 1
#define BITS_PER_BYTE 8U
#define GPIO_MAX 48U

/* Only the command task touches these (see bridge_commands.h). */
static spi_device_handle_t s_device;
static bool s_is_bus_ready;

static void close_bus(void) {
    if (s_device != NULL) {
        (void)spi_bus_remove_device(s_device);
        s_device = NULL;
    }
    if (s_is_bus_ready) {
        (void)spi_bus_free(SPI_HOST_USED);
        s_is_bus_ready = false;
    }
}

static const char *init_bus(const bridge_request_t *request) {
    const char *error = NULL;
    uint32_t sclk = 0U;
    uint32_t mosi = 0U;
    uint32_t miso = 0U;
    uint32_t chip_select = 0U;
    uint32_t speed_hz = 0U;
    uint32_t mode = 0U;
    if (!BridgeArgs_Uint(request, 2U, GPIO_MAX, &sclk, &error) ||
        !BridgeArgs_Uint(request, 3U, GPIO_MAX, &mosi, &error) ||
        !BridgeArgs_Uint(request, 4U, GPIO_MAX, &miso, &error) ||
        !BridgeArgs_Uint(request, 5U, GPIO_MAX, &chip_select, &error) ||
        !BridgeArgs_Uint(request, 6U, SPI_MAX_HZ, &speed_hz, &error) ||
        !BridgeArgs_Uint(request, 7U, SPI_MODE_MAX, &mode, &error)) {
        return "usage: spi init <sclk> <mosi> <miso> <cs> <hz> <mode>";
    }
    if (speed_hz < SPI_MIN_HZ) {
        return "clock below 1000 Hz";
    }
    close_bus();
    spi_bus_config_t bus_config = {
        .mosi_io_num = (int)mosi,
        .miso_io_num = (int)miso,
        .sclk_io_num = (int)sclk,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = SPI_MAX_TRANSFER_BYTES,
    };
    if (spi_bus_initialize(SPI_HOST_USED, &bus_config, SPI_DMA_CH_AUTO) !=
        ESP_OK) {
        return "spi bus init failed (pins in use?)";
    }
    s_is_bus_ready = true;
    spi_device_interface_config_t device_config = {
        .mode = (uint8_t)mode,
        .clock_speed_hz = (int)speed_hz,
        .spics_io_num = (int)chip_select,
        .queue_size = SPI_QUEUE_SIZE,
    };
    if (spi_bus_add_device(SPI_HOST_USED, &device_config, &s_device) !=
        ESP_OK) {
        close_bus();
        return "spi device init failed";
    }
    return NULL;
}

static const char *transfer(const bridge_request_t *request,
                            json_writer_t *data) {
    const char *error = NULL;
    if (!BridgeArgs_Has(request, 3U, "usage: spi xfer <hex>", &error)) {
        return error;
    }
    uint8_t written[SPI_MAX_TRANSFER_BYTES];
    uint8_t read[SPI_MAX_TRANSFER_BYTES];
    int32_t len =
        BridgeProtocol_ParseHex(request->args[2], written, sizeof(written));
    if (len <= 0) {
        return "bytes: hex, 1..64";
    }
    spi_transaction_t transaction = {
        .length = (size_t)len * BITS_PER_BYTE,
        .tx_buffer = written,
        .rx_buffer = read,
    };
    if (spi_device_polling_transmit(s_device, &transaction) != ESP_OK) {
        return "spi transfer failed";
    }
    JsonWriter_BeginObject(data, NULL);
    JsonWriter_AddHex(data, "read", read, (size_t)len);
    JsonWriter_EndObject(data);
    return NULL;
}

const char *Cmd_Spi(const bridge_request_t *request, json_writer_t *data) {
    if (request->arg_count < 2U) {
        return "usage: spi init | xfer";
    }
    if (strcmp(request->args[1], "init") == 0) {
        return init_bus(request);
    }
    if (s_device == NULL) {
        return "spi not initialised";
    }
    if (strcmp(request->args[1], "xfer") == 0) {
        return transfer(request, data);
    }
    return "unknown spi action";
}
