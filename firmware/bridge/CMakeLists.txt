# Protocol Lab ESP32 bridge.
#   idf.py set-target esp32s3 build      (I2C, SPI, CAN, 1-Wire, Wi-Fi, ESP-NOW)
#   idf.py set-target esp32c6 build      (+ Zigbee coordinator)
cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(protolab_bridge)
