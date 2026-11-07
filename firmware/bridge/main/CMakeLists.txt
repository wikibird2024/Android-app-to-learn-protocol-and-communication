set(srcs
    main.c
    bridge_io.c
    bridge_wifi.c
    cmd_system.c
    cmd_i2c.c
    cmd_spi.c
    cmd_can.c
    cmd_onewire.c
    cmd_espnow.c)

if(CONFIG_BRIDGE_ZIGBEE)
    list(APPEND srcs cmd_zigbee.c)
endif()

idf_component_register(
    SRCS ${srcs}
    INCLUDE_DIRS "."
    PRIV_REQUIRES bridge_protocol esp_driver_i2c esp_driver_spi esp_driver_uart
                  driver esp_wifi esp_netif esp_event nvs_flash lwip)
