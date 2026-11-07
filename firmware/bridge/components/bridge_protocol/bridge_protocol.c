#include "bridge_protocol.h"

#include <stdio.h>
#include <string.h>

#define BRIDGE_REQUEST_ID_MAX 0xFFFFFFFFU

static bool is_space(char character) {
    return character == ' ' || character == '\t' || character == '\r' ||
           character == '\n';
}

static int32_t hex_digit_value(char character) {
    if (character >= '0' && character <= '9') {
        return character - '0';
    }
    if (character >= 'a' && character <= 'f') {
        return character - 'a' + 10;
    }
    if (character >= 'A' && character <= 'F') {
        return character - 'A' + 10;
    }
    return -1;
}

static void write_error(json_writer_t *writer, uint32_t request_id,
                        const char *error) {
    JsonWriter_BeginObject(writer, NULL);
    JsonWriter_AddInt(writer, "id", request_id);
    JsonWriter_AddBool(writer, "ok", false);
    JsonWriter_AddText(writer, "error", error);
    JsonWriter_EndObject(writer);
}

bool BridgeProtocol_ParseUint(const char *text, uint32_t max_value,
                              uint32_t *value) {
    uint32_t base = 10U;
    const char *cursor = text;
    if (cursor[0] == '0' && (cursor[1] == 'x' || cursor[1] == 'X')) {
        base = 16U;
        cursor += 2;
    }
    if (*cursor == '\0') {
        return false;
    }
    uint64_t result = 0U;
    for (; *cursor != '\0'; cursor++) {
        int32_t digit = hex_digit_value(*cursor);
        if (digit < 0 || (uint32_t)digit >= base) {
            return false;
        }
        result = result * base + (uint32_t)digit;
        if (result > max_value) {
            return false;
        }
    }
    *value = (uint32_t)result;
    return true;
}

int32_t BridgeProtocol_ParseHex(const char *hex, uint8_t *out,
                                size_t out_size) {
    size_t count = 0U;
    int32_t high_nibble = -1;
    for (const char *cursor = hex; *cursor != '\0'; cursor++) {
        if (is_space(*cursor)) {
            continue;
        }
        int32_t digit = hex_digit_value(*cursor);
        if (digit < 0) {
            return -1;
        }
        if (high_nibble < 0) {
            high_nibble = digit;
            continue;
        }
        if (count >= out_size) {
            return -1;
        }
        out[count] = (uint8_t)((high_nibble << 4) | digit);
        count++;
        high_nibble = -1;
    }
    return (high_nibble < 0) ? (int32_t)count : -1;
}

bool BridgeProtocol_ParseLine(char *line, bridge_request_t *request) {
    request->request_id = 0U;
    request->arg_count = 0U;
    char *cursor = line;
    while (*cursor != '\0') {
        while (is_space(*cursor)) {
            *cursor = '\0';
            cursor++;
        }
        if (*cursor == '\0') {
            break;
        }
        if (request->arg_count >= BRIDGE_ARGS_MAX) {
            return false;
        }
        request->args[request->arg_count] = cursor;
        request->arg_count++;
        while (*cursor != '\0' && !is_space(*cursor)) {
            cursor++;
        }
    }
    if (request->arg_count == 0U) {
        return false;
    }
    /* A leading number is the request id, not a command. */
    uint32_t request_id = 0U;
    if (BridgeProtocol_ParseUint(request->args[0], BRIDGE_REQUEST_ID_MAX,
                                 &request_id)) {
        request->request_id = request_id;
        for (uint8_t i = 1U; i < request->arg_count; i++) {
            request->args[i - 1U] = request->args[i];
        }
        request->arg_count--;
    }
    return request->arg_count > 0U;
}

bool BridgeProtocol_Handle(const bridge_command_t *table, size_t table_len,
                           char *line, char *reply, size_t reply_size) {
    if (reply_size < 2U) {
        return false;
    }
    bridge_request_t request;
    json_writer_t writer;
    /* Keep one byte for the "\n" that ends the reply line. */
    JsonWriter_Init(&writer, reply, reply_size - 1U);

    bool is_blank = true;
    for (const char *cursor = line; *cursor != '\0'; cursor++) {
        if (!is_space(*cursor)) {
            is_blank = false;
            break;
        }
    }
    if (is_blank) {
        return false;
    }

    if (!BridgeProtocol_ParseLine(line, &request)) {
        write_error(&writer, request.request_id, "bad line");
    } else {
        const bridge_command_t *command = NULL;
        for (size_t i = 0U; i < table_len; i++) {
            if (strcmp(table[i].name, request.args[0]) == 0) {
                command = &table[i];
                break;
            }
        }
        if (command == NULL) {
            write_error(&writer, request.request_id, "unknown command");
        } else {
            JsonWriter_BeginObject(&writer, NULL);
            JsonWriter_AddInt(&writer, "id", request.request_id);
            JsonWriter_AddBool(&writer, "ok", true);
            /* Write the data first; if the handler fails, start over with
               an error reply so a half-written value is never sent. */
            size_t data_start = writer.len + strlen(",\"data\":");
            JsonWriter_AddRaw(&writer, "data", "");
            writer.needs_comma = false;
            const char *error = command->handler(&request, &writer);
            if (error != NULL) {
                JsonWriter_Init(&writer, reply, reply_size - 1U);
                write_error(&writer, request.request_id, error);
            } else {
                if (writer.len == data_start) {
                    JsonWriter_AddRaw(&writer, NULL, "null");
                }
                writer.needs_comma = true;
                JsonWriter_EndObject(&writer);
            }
        }
    }

    if (writer.is_overflow) {
        JsonWriter_Init(&writer, reply, reply_size - 1U);
        write_error(&writer, request.request_id, "reply too long");
    }
    reply[writer.len] = '\n';
    reply[writer.len + 1U] = '\0';
    return true;
}
