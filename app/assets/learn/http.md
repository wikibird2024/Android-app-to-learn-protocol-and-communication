# HTTP/1.1

*Text lines over TCP*

```text
request
GET /api/status HTTP/1.1
Host: 192.168.1.50
Accept: application/json
<blank line>

response
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 15
<blank line>
{"temp": 21.5}
```

The blank line (`\r\n\r\n`) ends the headers. The body length comes from
one of:

- `Content-Length`
- `Transfer-Encoding: chunked` (size in hex, then data, … `0` ends)
- the server closing the connection

## Methods

| Method | Use |
|---|---|
| GET | read |
| POST | create / act |
| PUT | replace |
| PATCH | change |
| DELETE | remove |

## Status

| Class | Meaning |
|---|---|
| 2xx | ok |
| 3xx | go elsewhere |
| 4xx | your request is wrong |
| 5xx | the server failed |

This tool writes the request bytes itself over a TCP (or TLS) socket with
`Connection: close`, so the Inside tab shows exactly what went on the
wire.

## ESP32 tips

- `esp_http_server` serves one request at a time.
- Keep JSON small: RAM is tight.
- REST = nouns in the path, verbs as methods: `PUT /api/led {"on":true}`.

## Try

GET `http://httpbin.org/get`, then look at the chunked or
Content-Length body in Inside.
