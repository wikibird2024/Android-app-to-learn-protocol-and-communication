#ifndef BRIDGE_COMMANDS_H
#define BRIDGE_COMMANDS_H

#include "bridge_protocol.h"

#include "sdkconfig.h"

#include <stddef.h>

/* One handler per command word (see bridge_protocol.h for the signature).
   Handlers run one at a time: bridge_io holds a lock around every command,
   so the bus state below has a single user and needs no lock of its own. */
const char *Cmd_Ping(const bridge_request_t *request, json_writer_t *data);
const char *Cmd_Help(const bridge_request_t *request, json_writer_t *data);
const char *Cmd_I2c(const bridge_request_t *request, json_writer_t *data);
const char *Cmd_Spi(const bridge_request_t *request, json_writer_t *data);
const char *Cmd_Can(const bridge_request_t *request, json_writer_t *data);
const char *Cmd_OneWire(const bridge_request_t *request, json_writer_t *data);
const char *Cmd_Wifi(const bridge_request_t *request, json_writer_t *data);
const char *Cmd_EspNow(const bridge_request_t *request, json_writer_t *data);
#if CONFIG_BRIDGE_ZIGBEE
const char *Cmd_Zigbee(const bridge_request_t *request, json_writer_t *data);
#endif

/* The command table used by bridge_io. */
const bridge_command_t *BridgeCommands_Table(size_t *count);

/* Shared argument helpers: write the error text to *error and return false
   when an argument is missing or out of range. */
bool BridgeArgs_Uint(const bridge_request_t *request, uint8_t index,
                     uint32_t max_value, uint32_t *value, const char **error);
bool BridgeArgs_Has(const bridge_request_t *request, uint8_t count,
                    const char *usage, const char **error);

#endif
