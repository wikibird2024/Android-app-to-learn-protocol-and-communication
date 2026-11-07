#ifndef BRIDGE_PROTOCOL_H
#define BRIDGE_PROTOCOL_H

#include "json_writer.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* The bridge's text protocol, shared by the UART console and the TCP port.
   Plain C with no ESP-IDF include, so it runs in host tests.

     request : "<id> <command> <args...>\n"   (id is optional when typed
               by hand; it is then 0)
     reply   : {"id":7,"ok":true,"data":...}\n
               {"id":7,"ok":false,"error":"..."}\n
     event   : {"event":"can","id":"123","data":"0102"}\n  (no request) */

#define BRIDGE_LINE_MAX_LEN 256U
#define BRIDGE_ARGS_MAX 16U
#define BRIDGE_REPLY_MAX_LEN 1024U

typedef struct {
    uint32_t request_id;
    uint8_t arg_count;
    /* Point into the line, which is split in place. args[0] is the
       command name. */
    char *args[BRIDGE_ARGS_MAX];
} bridge_request_t;

/* A command writes its result into data (one JSON value, for example an
   object) and returns NULL, or returns an error text and writes nothing. */
typedef const char *(*bridge_handler_fn)(const bridge_request_t *request,
                                         json_writer_t *data);

typedef struct {
    const char *name;
    const char *usage;
    bridge_handler_fn handler;
} bridge_command_t;

/* Splits line in place into id and words. Returns false for an empty line
   or one with more than BRIDGE_ARGS_MAX words. */
bool BridgeProtocol_ParseLine(char *line, bridge_request_t *request);

/* Parses line, runs the command from table and writes one reply line
   (with "\n") into reply. Returns false when nothing should be sent (an
   empty line). Unknown commands and bad lines get an error reply. */
bool BridgeProtocol_Handle(const bridge_command_t *table, size_t table_len,
                           char *line, char *reply, size_t reply_size);

/* "0a 1B" or "0a1b" → bytes. Returns the byte count, or -1 for an odd digit
   count, a non-hex character or more than out_size bytes. */
int32_t BridgeProtocol_ParseHex(const char *hex, uint8_t *out, size_t out_size);

/* "0x1f", "1f" (hex) and "31" (decimal with no letters) are NOT the same
   thing, so numbers are read in one fixed way: decimal, or hex with "0x".
   Returns false when text is not a number in range. */
bool BridgeProtocol_ParseUint(const char *text, uint32_t max_value,
                              uint32_t *value);

#endif
