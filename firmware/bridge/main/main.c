#include "bridge_commands.h"
#include "bridge_io.h"
#include "bridge_wifi.h"

#include "esp_event.h"
#include "esp_log.h"
#include "nvs_flash.h"

static const char *TAG = "protolab";

void app_main(void) {
    esp_err_t result = nvs_flash_init();
    if (result == ESP_ERR_NVS_NO_FREE_PAGES ||
        result == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        result = nvs_flash_init();
    }
    ESP_ERROR_CHECK(result);
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    BridgeWifi_Start();
    size_t command_count = 0U;
    const bridge_command_t *table = BridgeCommands_Table(&command_count);
    BridgeIo_Start(table, command_count);
    ESP_LOGI(TAG, "bridge ready: type \"help\" here, or connect the app");

    /* shortcut: logs share the console UART with replies and could split a
       reply line; quiet them after boot. Move replies to their own UART or
       USB-JTAG if that ever shows up. */
    esp_log_level_set("*", ESP_LOG_WARN);
}
