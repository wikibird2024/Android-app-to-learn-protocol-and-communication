#include "json_writer.h"

#include <stdio.h>
#include <string.h>

static void append_char(json_writer_t *writer, char value) {
    /* Keep one byte for the terminating zero. */
    if (writer->is_overflow || writer->len + 1U >= writer->size) {
        writer->is_overflow = true;
        return;
    }
    writer->text[writer->len] = value;
    writer->len++;
    writer->text[writer->len] = '\0';
}

static void append_text(json_writer_t *writer, const char *value) {
    for (const char *cursor = value; *cursor != '\0'; cursor++) {
        append_char(writer, *cursor);
    }
}

static void append_quoted(json_writer_t *writer, const char *value) {
    static const char hex_digits[] = "0123456789abcdef";
    append_char(writer, '"');
    for (const unsigned char *cursor = (const unsigned char *)value;
         *cursor != '\0'; cursor++) {
        unsigned char character = *cursor;
        if (character == '"' || character == '\\') {
            append_char(writer, '\\');
            append_char(writer, (char)character);
        } else if (character == '\n') {
            append_text(writer, "\\n");
        } else if (character < 0x20U) {
            append_text(writer, "\\u00");
            append_char(writer, hex_digits[character >> 4]);
            append_char(writer, hex_digits[character & 0x0FU]);
        } else {
            append_char(writer, (char)character);
        }
    }
    append_char(writer, '"');
}

static void begin_item(json_writer_t *writer, const char *key) {
    if (writer->needs_comma) {
        append_char(writer, ',');
    }
    if (key != NULL) {
        append_quoted(writer, key);
        append_char(writer, ':');
    }
    writer->needs_comma = true;
}

void JsonWriter_Init(json_writer_t *writer, char *buffer, size_t size) {
    writer->text = buffer;
    writer->size = size;
    writer->len = 0U;
    writer->is_overflow = (size == 0U);
    writer->needs_comma = false;
    if (size > 0U) {
        buffer[0] = '\0';
    }
}

void JsonWriter_BeginObject(json_writer_t *writer, const char *key) {
    begin_item(writer, key);
    append_char(writer, '{');
    writer->needs_comma = false;
}

void JsonWriter_EndObject(json_writer_t *writer) {
    append_char(writer, '}');
    writer->needs_comma = true;
}

void JsonWriter_BeginArray(json_writer_t *writer, const char *key) {
    begin_item(writer, key);
    append_char(writer, '[');
    writer->needs_comma = false;
}

void JsonWriter_EndArray(json_writer_t *writer) {
    append_char(writer, ']');
    writer->needs_comma = true;
}

void JsonWriter_AddText(json_writer_t *writer, const char *key,
                        const char *value) {
    begin_item(writer, key);
    append_quoted(writer, value);
}

void JsonWriter_AddInt(json_writer_t *writer, const char *key, int64_t value) {
    char number[24];
    (void)snprintf(number, sizeof(number), "%lld", (long long)value);
    begin_item(writer, key);
    append_text(writer, number);
}

void JsonWriter_AddBool(json_writer_t *writer, const char *key, bool value) {
    begin_item(writer, key);
    append_text(writer, value ? "true" : "false");
}

void JsonWriter_AddHex(json_writer_t *writer, const char *key,
                       const uint8_t *bytes, size_t len) {
    static const char hex_digits[] = "0123456789abcdef";
    begin_item(writer, key);
    append_char(writer, '"');
    for (size_t i = 0; i < len; i++) {
        append_char(writer, hex_digits[bytes[i] >> 4]);
        append_char(writer, hex_digits[bytes[i] & 0x0FU]);
    }
    append_char(writer, '"');
}

void JsonWriter_AddRaw(json_writer_t *writer, const char *key,
                       const char *json) {
    begin_item(writer, key);
    append_text(writer, json);
}
