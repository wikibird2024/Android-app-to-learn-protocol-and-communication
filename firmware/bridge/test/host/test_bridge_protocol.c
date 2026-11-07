#include "bridge_protocol.h"
#include "unity.h"

#include <string.h>

#define TEST_REPLY_SIZE 256U

static char s_reply[TEST_REPLY_SIZE];

static const char *echo_handler(const bridge_request_t *request,
                                json_writer_t *data) {
    JsonWriter_BeginArray(data, NULL);
    for (uint8_t i = 1U; i < request->arg_count; i++) {
        JsonWriter_AddText(data, NULL, request->args[i]);
    }
    JsonWriter_EndArray(data);
    return NULL;
}

static const char *fail_handler(const bridge_request_t *request,
                                json_writer_t *data) {
    (void)request;
    JsonWriter_AddText(data, NULL, "half written");
    return "bus busy";
}

static const char *silent_handler(const bridge_request_t *request,
                                  json_writer_t *data) {
    (void)request;
    (void)data;
    return NULL;
}

static const char *long_handler(const bridge_request_t *request,
                                json_writer_t *data) {
    (void)request;
    static const uint8_t bytes[200] = {0};
    JsonWriter_AddHex(data, NULL, bytes, sizeof(bytes));
    return NULL;
}

static const bridge_command_t s_table[] = {
    {"echo", "echo <words>", echo_handler},
    {"fail", "fail", fail_handler},
    {"silent", "silent", silent_handler},
    {"long", "long", long_handler},
};

static const char *handle(const char *text) {
    char line[BRIDGE_LINE_MAX_LEN];
    (void)strncpy(line, text, sizeof(line) - 1U);
    line[sizeof(line) - 1U] = '\0';
    bool has_reply =
        BridgeProtocol_Handle(s_table, sizeof(s_table) / sizeof(s_table[0]),
                              line, s_reply, sizeof(s_reply));
    return has_reply ? s_reply : NULL;
}

void setUp(void) {}
void tearDown(void) {}

static void test_reply_has_id_and_data(void) {
    TEST_ASSERT_EQUAL_STRING("{\"id\":7,\"ok\":true,\"data\":[\"a\",\"b\"]}\n",
                             handle("7 echo a b\r\n"));
}

static void test_id_is_optional_when_typed_by_hand(void) {
    TEST_ASSERT_EQUAL_STRING("{\"id\":0,\"ok\":true,\"data\":[]}\n",
                             handle("  echo"));
}

static void test_failed_handler_sends_only_the_error(void) {
    TEST_ASSERT_EQUAL_STRING("{\"id\":3,\"ok\":false,\"error\":\"bus busy\"}\n",
                             handle("3 fail"));
}

static void test_handler_without_data_gives_null(void) {
    TEST_ASSERT_EQUAL_STRING("{\"id\":4,\"ok\":true,\"data\":null}\n",
                             handle("4 silent"));
}

static void test_unknown_command(void) {
    TEST_ASSERT_EQUAL_STRING(
        "{\"id\":9,\"ok\":false,\"error\":\"unknown command\"}\n",
        handle("9 nope"));
}

static void test_blank_line_gives_no_reply(void) {
    TEST_ASSERT_NULL(handle(" \r\n"));
}

static void test_only_an_id_is_a_bad_line(void) {
    TEST_ASSERT_EQUAL_STRING("{\"id\":5,\"ok\":false,\"error\":\"bad line\"}\n",
                             handle("5"));
}

static void test_too_long_reply_becomes_an_error(void) {
    TEST_ASSERT_EQUAL_STRING(
        "{\"id\":2,\"ok\":false,\"error\":\"reply too long\"}\n",
        handle("2 long"));
}

static void test_text_is_escaped(void) {
    TEST_ASSERT_EQUAL_STRING(
        "{\"id\":1,\"ok\":true,\"data\":[\"a\\\"b\\\\\"]}\n",
        handle("1 echo a\"b\\"));
}

static void test_parse_hex(void) {
    uint8_t bytes[4];
    TEST_ASSERT_EQUAL_INT32(3, BridgeProtocol_ParseHex("0a 1B ff", bytes, 4));
    TEST_ASSERT_EQUAL_HEX8(0x0A, bytes[0]);
    TEST_ASSERT_EQUAL_HEX8(0x1B, bytes[1]);
    TEST_ASSERT_EQUAL_HEX8(0xFF, bytes[2]);
    TEST_ASSERT_EQUAL_INT32(0, BridgeProtocol_ParseHex("", bytes, 4));
    TEST_ASSERT_EQUAL_INT32(-1, BridgeProtocol_ParseHex("abc", bytes, 4));
    TEST_ASSERT_EQUAL_INT32(-1, BridgeProtocol_ParseHex("zz", bytes, 4));
    TEST_ASSERT_EQUAL_INT32(-1, BridgeProtocol_ParseHex("0102", bytes, 1));
}

static void test_parse_uint(void) {
    uint32_t value = 0U;
    TEST_ASSERT_TRUE(BridgeProtocol_ParseUint("0x1f", 255U, &value));
    TEST_ASSERT_EQUAL_UINT32(31U, value);
    TEST_ASSERT_TRUE(BridgeProtocol_ParseUint("400000", 1000000U, &value));
    TEST_ASSERT_EQUAL_UINT32(400000U, value);
    TEST_ASSERT_FALSE(BridgeProtocol_ParseUint("1f", 255U, &value));
    TEST_ASSERT_FALSE(BridgeProtocol_ParseUint("256", 255U, &value));
    TEST_ASSERT_FALSE(BridgeProtocol_ParseUint("0x", 255U, &value));
    TEST_ASSERT_FALSE(BridgeProtocol_ParseUint("-1", 255U, &value));
}

int main(void) {
    UNITY_BEGIN();
    RUN_TEST(test_reply_has_id_and_data);
    RUN_TEST(test_id_is_optional_when_typed_by_hand);
    RUN_TEST(test_failed_handler_sends_only_the_error);
    RUN_TEST(test_handler_without_data_gives_null);
    RUN_TEST(test_unknown_command);
    RUN_TEST(test_blank_line_gives_no_reply);
    RUN_TEST(test_only_an_id_is_a_bad_line);
    RUN_TEST(test_too_long_reply_becomes_an_error);
    RUN_TEST(test_text_is_escaped);
    RUN_TEST(test_parse_hex);
    RUN_TEST(test_parse_uint);
    return UNITY_END();
}
