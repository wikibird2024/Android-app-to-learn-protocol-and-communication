#ifndef JSON_WRITER_H
#define JSON_WRITER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Builds one line of JSON into a fixed buffer, with no heap. Commas between
   items are added by the writer. When the buffer is full, is_overflow is set
   and later writes do nothing, so callers check once at the end. */
typedef struct {
    char *text;
    size_t size;
    size_t len;
    bool is_overflow;
    bool needs_comma;
} json_writer_t;

void JsonWriter_Init(json_writer_t *writer, char *buffer, size_t size);

/* Objects and arrays. A key is only given inside an object; pass NULL for
   array items and for the top-level value. */
void JsonWriter_BeginObject(json_writer_t *writer, const char *key);
void JsonWriter_EndObject(json_writer_t *writer);
void JsonWriter_BeginArray(json_writer_t *writer, const char *key);
void JsonWriter_EndArray(json_writer_t *writer);

void JsonWriter_AddText(json_writer_t *writer, const char *key,
                        const char *value);
void JsonWriter_AddInt(json_writer_t *writer, const char *key, int64_t value);
void JsonWriter_AddBool(json_writer_t *writer, const char *key, bool value);

/* Bytes as a lowercase hex string, "0a1b". */
void JsonWriter_AddHex(json_writer_t *writer, const char *key,
                       const uint8_t *bytes, size_t len);

/* Already-valid JSON (for example a nested reply from a handler). */
void JsonWriter_AddRaw(json_writer_t *writer, const char *key,
                       const char *json);

#endif
