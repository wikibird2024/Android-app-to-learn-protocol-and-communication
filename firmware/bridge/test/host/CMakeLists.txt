# Host unit tests for the plain-C parts of the bridge (no ESP-IDF, no board).
#
#   cmake -S firmware/bridge/test/host -B build-host && cmake --build build-host
#   ctest --test-dir build-host --output-on-failure
cmake_minimum_required(VERSION 3.16)
project(bridge_host_tests C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

set(BRIDGE_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../..)

option(HOST_TESTS_SANITIZE "Build with address and undefined-behaviour sanitizers" ON)

add_library(unity STATIC unity/unity.c)
target_include_directories(unity PUBLIC unity)

set(STRICT_WARNINGS -Wall -Wextra -Werror -Wshadow -Wconversion -Wno-sign-conversion)

function(add_host_test name)
  cmake_parse_arguments(ARG "" "" "SOURCES;INCLUDES" ${ARGN})
  add_executable(${name} ${ARG_SOURCES})
  target_include_directories(${name} PRIVATE ${ARG_INCLUDES})
  target_link_libraries(${name} PRIVATE unity)
  target_compile_options(${name} PRIVATE ${STRICT_WARNINGS})
  if(HOST_TESTS_SANITIZE)
    target_compile_options(${name} PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer)
    target_link_options(${name} PRIVATE -fsanitize=address,undefined)
  endif()
  add_test(NAME ${name} COMMAND ${name})
endfunction()

enable_testing()

add_host_test(test_bridge_protocol
  SOURCES test_bridge_protocol.c
          ${BRIDGE_ROOT}/components/bridge_protocol/bridge_protocol.c
          ${BRIDGE_ROOT}/components/bridge_protocol/json_writer.c
  INCLUDES ${BRIDGE_ROOT}/components/bridge_protocol)
