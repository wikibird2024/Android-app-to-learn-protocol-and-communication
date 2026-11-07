#ifndef BRIDGE_IO_H
#define BRIDGE_IO_H

#include "bridge_protocol.h"

#include <stddef.h>

/* Starts the two ways in: a task reading lines from the console UART, and
   a TCP server (one client at a time) on CONFIG_BRIDGE_TCP_PORT. Both feed
   the same command table. */
void BridgeIo_Start(const bridge_command_t *table, size_t table_len);

/* Sends one event line (a JSON object, no newline) to the UART and to the
   TCP client if one is connected. Safe from any task, not from an ISR. */
void BridgeIo_SendEvent(const char *json_line);

#endif
