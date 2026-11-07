#include "bridge_io.h"

#include "driver/uart.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "lwip/sockets.h"

#include <string.h>

#define UART_RX_BUFFER_BYTES 1024U
#define UART_READ_TIMEOUT_MS 100U
#define TASK_STACK_BYTES 6144U
#define TASK_PRIORITY 5U
#define TCP_LISTEN_BACKLOG 1
#define TCP_KEEPALIVE_IDLE_S 10
#define TCP_KEEPALIVE_INTERVAL_S 5
#define TCP_KEEPALIVE_COUNT 3

static const char *TAG = "bridge_io";

static const bridge_command_t *s_table;
static size_t s_table_len;

/* Commands from UART and TCP run one at a time under this lock. */
static SemaphoreHandle_t s_command_lock;

/* Guards both outputs, so a reply and an event never mix bytes. */
static SemaphoreHandle_t s_output_lock;

/* Written by the TCP task only, read by BridgeIo_SendEvent under
   s_output_lock. -1 when no client is connected. */
static int s_client_socket = -1;

typedef void (*write_fn)(const char *text, size_t len);

static void write_uart(const char *text, size_t len) {
    (void)uart_write_bytes(CONFIG_ESP_CONSOLE_UART_NUM, text, len);
}

static void write_tcp(const char *text, size_t len) {
    if (s_client_socket < 0) {
        return;
    }
    size_t sent = 0U;
    while (sent < len) {
        int result = send(s_client_socket, text + sent, len - sent, 0);
        if (result <= 0) {
            return; /* the TCP task notices the dead socket on its next read */
        }
        sent += (size_t)result;
    }
}

static void run_line(char *line, write_fn write) {
    static char reply[BRIDGE_REPLY_MAX_LEN];
    (void)xSemaphoreTake(s_command_lock, portMAX_DELAY);
    bool has_reply =
        BridgeProtocol_Handle(s_table, s_table_len, line, reply, sizeof(reply));
    if (has_reply) {
        (void)xSemaphoreTake(s_output_lock, portMAX_DELAY);
        write(reply, strlen(reply));
        (void)xSemaphoreGive(s_output_lock);
    }
    (void)xSemaphoreGive(s_command_lock);
}

/* Collects bytes into a line; a line longer than the buffer is dropped
   whole, so a half command never runs. */
typedef struct {
    char text[BRIDGE_LINE_MAX_LEN];
    size_t len;
    bool is_overflow;
} line_buffer_t;

static void feed_byte(line_buffer_t *buffer, char byte, write_fn write) {
    if (byte == '\n') {
        if (!buffer->is_overflow) {
            buffer->text[buffer->len] = '\0';
            run_line(buffer->text, write);
        }
        buffer->len = 0U;
        buffer->is_overflow = false;
        return;
    }
    if (buffer->len + 1U >= sizeof(buffer->text)) {
        buffer->is_overflow = true;
        return;
    }
    buffer->text[buffer->len] = byte;
    buffer->len++;
}

static void uart_task(void *arg) {
    (void)arg;
    static line_buffer_t buffer;
    uint8_t chunk[64];
    while (true) {
        int count =
            uart_read_bytes(CONFIG_ESP_CONSOLE_UART_NUM, chunk, sizeof(chunk),
                            pdMS_TO_TICKS(UART_READ_TIMEOUT_MS));
        for (int i = 0; i < count; i++) {
            feed_byte(&buffer, (char)chunk[i], write_uart);
        }
    }
}

static void serve_client(int client_socket) {
    static line_buffer_t buffer;
    buffer.len = 0U;
    buffer.is_overflow = false;
    char chunk[128];
    while (true) {
        int count = recv(client_socket, chunk, sizeof(chunk), 0);
        if (count <= 0) {
            return;
        }
        for (int i = 0; i < count; i++) {
            feed_byte(&buffer, chunk[i], write_tcp);
        }
    }
}

static void tcp_task(void *arg) {
    (void)arg;
    int listen_socket = socket(AF_INET, SOCK_STREAM, IPPROTO_IP);
    struct sockaddr_in address = {
        .sin_family = AF_INET,
        .sin_port = htons(CONFIG_BRIDGE_TCP_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    int reuse = 1;
    (void)setsockopt(listen_socket, SOL_SOCKET, SO_REUSEADDR, &reuse,
                     sizeof(reuse));
    if (listen_socket < 0 ||
        bind(listen_socket, (struct sockaddr *)&address, sizeof(address)) !=
            0 ||
        listen(listen_socket, TCP_LISTEN_BACKLOG) != 0) {
        ESP_LOGE(TAG, "TCP server failed to start");
        vTaskDelete(NULL);
        return;
    }
    ESP_LOGI(TAG, "TCP server on port %d", CONFIG_BRIDGE_TCP_PORT);
    while (true) {
        int client_socket = accept(listen_socket, NULL, NULL);
        if (client_socket < 0) {
            continue;
        }
        /* Keepalive notices a phone that walked away without closing. */
        int keepalive = 1;
        int idle_s = TCP_KEEPALIVE_IDLE_S;
        int interval_s = TCP_KEEPALIVE_INTERVAL_S;
        int count = TCP_KEEPALIVE_COUNT;
        (void)setsockopt(client_socket, SOL_SOCKET, SO_KEEPALIVE, &keepalive,
                         sizeof(keepalive));
        (void)setsockopt(client_socket, IPPROTO_TCP, TCP_KEEPIDLE, &idle_s,
                         sizeof(idle_s));
        (void)setsockopt(client_socket, IPPROTO_TCP, TCP_KEEPINTVL, &interval_s,
                         sizeof(interval_s));
        (void)setsockopt(client_socket, IPPROTO_TCP, TCP_KEEPCNT, &count,
                         sizeof(count));
        ESP_LOGI(TAG, "app connected");
        (void)xSemaphoreTake(s_output_lock, portMAX_DELAY);
        s_client_socket = client_socket;
        (void)xSemaphoreGive(s_output_lock);

        serve_client(client_socket);

        (void)xSemaphoreTake(s_output_lock, portMAX_DELAY);
        s_client_socket = -1;
        (void)xSemaphoreGive(s_output_lock);
        (void)close(client_socket);
        ESP_LOGI(TAG, "app disconnected");
    }
}

void BridgeIo_Start(const bridge_command_t *table, size_t table_len) {
    s_table = table;
    s_table_len = table_len;
    s_command_lock = xSemaphoreCreateMutex();
    s_output_lock = xSemaphoreCreateMutex();
    ESP_ERROR_CHECK(uart_driver_install(CONFIG_ESP_CONSOLE_UART_NUM,
                                        UART_RX_BUFFER_BYTES, 0, 0, NULL, 0));
    (void)xTaskCreate(uart_task, "bridge_uart", TASK_STACK_BYTES, NULL,
                      TASK_PRIORITY, NULL);
    (void)xTaskCreate(tcp_task, "bridge_tcp", TASK_STACK_BYTES, NULL,
                      TASK_PRIORITY, NULL);
}

void BridgeIo_SendEvent(const char *json_line) {
    size_t len = strlen(json_line);
    (void)xSemaphoreTake(s_output_lock, portMAX_DELAY);
    write_uart(json_line, len);
    write_uart("\n", 1U);
    write_tcp(json_line, len);
    write_tcp("\n", 1U);
    (void)xSemaphoreGive(s_output_lock);
}
