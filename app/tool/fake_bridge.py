#!/usr/bin/env python3
"""Fake ESP32 bridge: speaks the bridge's text protocol over TCP, so the app
and its tests run with no hardware. Same protocol as
firmware/bridge/components/bridge_protocol/bridge_protocol.h:

  request  "<id> <command> <args...>\\n"     (id optional when typed)
  reply    {"id":7,"ok":true,"data":...}
  error    {"id":7,"ok":false,"error":"..."}
  event    {"event":"can","id":"123","ext":false,"rtr":false,"data":"0102"}

Fake devices:
  I2C   BME280 at 0x76 (register 0xD0 = chip id 0x60), OLED at 0x3C
  SPI   SPI flash: 9F → JEDEC id EF 40 18; other bytes loop back
  CAN   echoes every sent frame back as an rx event; while started,
        sends id 0x123 every second with a counter
  1-Wire one DS18B20 (Maxim App Note 27 style ROM with a valid CRC) at 25.0625 °C
  Modbus --modbus-port N: a Modbus TCP slave, holding registers 0..99 = 100+address
  WebSocket --ws-port N: echo server (RFC 6455): echoes text/binary, answers ping, closes politely

Standard library only. One client at a time per port, like the firmware.

  python3 tool/fake_bridge.py --port 3333 --modbus-port 1502
"""

import argparse
import base64
import hashlib
import json
import socket
import socketserver
import struct
import threading
import time

FIRMWARE_VERSION = "0.1.0-fake"


def crc8_maxim(data):
    crc = 0
    for byte in data:
        for _ in range(8):
            mix = (crc ^ byte) & 1
            crc >>= 1
            if mix:
                crc ^= 0x8C
            byte >>= 1
    return crc


DS18B20_ROM = bytes([0x28, 0xAA, 0x3C, 0x51, 0x0B, 0x00, 0x00])
DS18B20_ROM += bytes([crc8_maxim(DS18B20_ROM)])


def ds18b20_scratchpad(celsius):
    raw = int(round(celsius * 16)) & 0xFFFF
    body = bytes([raw & 0xFF, raw >> 8, 0x4B, 0x46, 0x7F, 0xFF, 0x0C, 0x10])
    return body + bytes([crc8_maxim(body)])


class BridgeState:
    """What the fake remembers between commands (like the firmware's buses)."""

    def __init__(self):
        self.i2c_ready = False
        self.spi_ready = False
        self.can_running = False
        self.onewire_ready = False
        self.espnow_ready = False
        self.wifi_ssid = ""
        self.i2c_registers = {0x76: {0xD0: 0x60, 0xF2: 0x01}, 0x3C: {}}


class CommandError(Exception):
    pass


def parse_number(text, maximum):
    try:
        value = int(text, 16) if text.lower().startswith("0x") else int(text, 10)
    except ValueError:
        raise CommandError(f"not a number: {text}")
    if not 0 <= value <= maximum:
        raise CommandError(f"out of range: {text}")
    return value


def parse_hex(text):
    if text == "-":
        return b""
    try:
        return bytes.fromhex(text)
    except ValueError:
        raise CommandError(f"not hex: {text}")


def need(args, count, usage):
    if len(args) < count:
        raise CommandError(f"usage: {usage}")


def handle(state, args, send_event):
    command, rest = args[0], args[1:]
    if command == "ping":
        return {
            "name": "protolab-bridge",
            "version": FIRMWARE_VERSION,
            "target": "fake",
            "mac": "24:6f:28:00:00:01",
            "features": ["i2c", "spi", "can", "onewire", "espnow"],
        }
    if command == "help":
        return [
            {"name": name, "usage": usage}
            for name, usage in [
                ("ping", "ping"),
                ("i2c", "i2c init <sda> <scl> <hz> | scan | xfer <addr> <hex|-> <read len>"),
                ("spi", "spi init <sclk> <mosi> <miso> <cs> <hz> <mode> | xfer <hex>"),
                ("can", "can init <tx> <rx> <bitrate> | send <id> <hex|-> [ext] [rtr] | status | stop"),
                ("ow", "ow init <pin> | search | ds18b20 <rom>"),
                ("wifi", "wifi status | scan | set <ssid> <password|->"),
                ("espnow", "espnow init | send <mac> <hex>"),
            ]
        ]
    if command == "i2c":
        need(rest, 1, "i2c init|scan|xfer")
        if rest[0] == "init":
            need(rest, 4, "i2c init <sda> <scl> <hz>")
            parse_number(rest[3], 1000000)
            state.i2c_ready = True
            return None
        if not state.i2c_ready:
            raise CommandError("i2c not initialised: i2c init <sda> <scl> <hz>")
        if rest[0] == "scan":
            return sorted(state.i2c_registers)
        if rest[0] == "xfer":
            need(rest, 4, "i2c xfer <addr> <hex|-> <read len>")
            address = parse_number(rest[1], 0x7F)
            written = parse_hex(rest[2])
            read_len = parse_number(rest[3], 255)
            registers = state.i2c_registers.get(address)
            if registers is None:
                raise CommandError(f"no ACK from 0x{address:02x}")
            pointer = written[0] if written else 0
            for offset, value in enumerate(written[1:]):
                registers[pointer + offset] = value
            read = bytes(registers.get((pointer + i) & 0xFF, 0) for i in range(read_len))
            return {"read": read.hex()}
    if command == "spi":
        need(rest, 1, "spi init|xfer")
        if rest[0] == "init":
            need(rest, 7, "spi init <sclk> <mosi> <miso> <cs> <hz> <mode>")
            parse_number(rest[6], 3)
            state.spi_ready = True
            return None
        if rest[0] == "xfer":
            if not state.spi_ready:
                raise CommandError("spi not initialised")
            need(rest, 2, "spi xfer <hex>")
            out = parse_hex(rest[1])
            if out[:1] == b"\x9f":
                answer = bytes([0xFF, 0xEF, 0x40, 0x18]) + bytes(max(0, len(out) - 4))
                return {"read": answer[: len(out)].hex()}
            return {"read": out.hex()}
    if command == "can":
        need(rest, 1, "can init|send|status|stop")
        if rest[0] == "init":
            need(rest, 4, "can init <tx> <rx> <bitrate>")
            parse_number(rest[3], 1000000)
            state.can_running = True
            return None
        if rest[0] == "stop":
            state.can_running = False
            return None
        if rest[0] == "status":
            return {"state": "running" if state.can_running else "stopped", "tx_errors": 0, "rx_errors": 0}
        if rest[0] == "send":
            if not state.can_running:
                raise CommandError("can not started")
            need(rest, 3, "can send <id> <hex|-> [ext] [rtr]")
            is_extended = "ext" in rest[3:]
            frame_id = parse_number("0x" + rest[1], 0x1FFFFFFF if is_extended else 0x7FF)
            data = parse_hex(rest[2])
            if len(data) > 8:
                raise CommandError("0..8 data bytes")
            send_event({"event": "can", "id": f"{frame_id:x}", "ext": is_extended, "rtr": "rtr" in rest[3:], "data": data.hex()})
            return None
    if command == "ow":
        need(rest, 1, "ow init|search|ds18b20")
        if rest[0] == "init":
            need(rest, 2, "ow init <pin>")
            state.onewire_ready = True
            return None
        if not state.onewire_ready:
            raise CommandError("1-Wire not initialised")
        if rest[0] == "search":
            return [DS18B20_ROM.hex()]
        if rest[0] == "ds18b20":
            need(rest, 2, "ow ds18b20 <rom>")
            if parse_hex(rest[1]) != DS18B20_ROM:
                raise CommandError("no presence pulse for that ROM")
            time.sleep(0.75)  # 12-bit conversion time, like the real sensor
            return {"scratchpad": ds18b20_scratchpad(25.0625).hex()}
    if command == "wifi":
        need(rest, 1, "wifi status|scan|set")
        if rest[0] == "status":
            return {"mode": "sta" if state.wifi_ssid else "ap", "ssid": state.wifi_ssid or "protolab-bridge", "ip": "192.168.4.1", "rssi": -48}
        if rest[0] == "scan":
            return [
                {"ssid": "bench-lab", "rssi": -45, "channel": 6, "auth": "WPA2"},
                {"ssid": "guest", "rssi": -78, "channel": 11, "auth": "open"},
            ]
        if rest[0] == "set":
            need(rest, 3, "wifi set <ssid> <password|->")
            state.wifi_ssid = rest[1]
            return None
    if command == "espnow":
        need(rest, 1, "espnow init|send")
        if rest[0] == "init":
            state.espnow_ready = True
            return None
        if rest[0] == "send":
            if not state.espnow_ready:
                raise CommandError("espnow not started")
            need(rest, 3, "espnow send <mac> <hex>")
            data = parse_hex(rest[2])
            send_event({"event": "espnow", "mac": rest[1], "rssi": -40, "data": data.hex()})
            return None
    if command in ("zb", "ot"):
        raise CommandError(f"{command}: not built for this chip (needs ESP32-C6/H2)")
    raise CommandError("unknown command")


class BridgeHandler(socketserver.StreamRequestHandler):
    def handle(self):
        state = BridgeState()
        lock = threading.Lock()
        is_open = [True]

        def send(obj):
            with lock:
                if is_open[0]:
                    self.wfile.write((json.dumps(obj, separators=(",", ":")) + "\n").encode())

        def heartbeat():
            counter = 0
            while is_open[0]:
                time.sleep(1.0)
                if state.can_running:
                    counter = (counter + 1) & 0xFF
                    try:
                        send({"event": "can", "id": "123", "ext": False, "rtr": False, "data": f"{counter:02x}00"})
                    except OSError:
                        return

        threading.Thread(target=heartbeat, daemon=True).start()
        # Like the firmware's boot log on UART: console noise the app must ignore.
        self.wfile.write(b"I (312) protolab: fake bridge ready\n")
        try:
            for raw in self.rfile:
                words = raw.decode(errors="replace").split()
                if not words:
                    continue
                request_id = 0
                if words[0].isdigit():
                    request_id = int(words[0])
                    words = words[1:]
                if not words:
                    send({"id": request_id, "ok": False, "error": "bad line"})
                    continue
                try:
                    data = handle(state, words, send)
                    send({"id": request_id, "ok": True, "data": data})
                except CommandError as error:
                    send({"id": request_id, "ok": False, "error": str(error)})
        finally:
            is_open[0] = False


class ModbusHandler(socketserver.BaseRequestHandler):
    """Modbus TCP slave: function 3 reads holding registers 0..99."""

    def handle(self):
        registers = [100 + address for address in range(100)]
        while True:
            header = self.request.recv(7)
            if len(header) < 7:
                return
            transaction, _protocol, length, unit = struct.unpack(">HHHB", header)
            pdu = self.request.recv(length - 1)
            function = pdu[0]
            if function == 3:
                address, quantity = struct.unpack(">HH", pdu[1:5])
                if address + quantity > len(registers):
                    reply = bytes([0x83, 0x02])
                else:
                    values = registers[address : address + quantity]
                    reply = bytes([3, quantity * 2]) + b"".join(struct.pack(">H", value) for value in values)
            elif function == 6:
                address, value = struct.unpack(">HH", pdu[1:5])
                if address >= len(registers):
                    reply = bytes([0x86, 0x02])
                else:
                    registers[address] = value
                    reply = pdu[:5]
            else:
                reply = bytes([function | 0x80, 0x01])
            self.request.sendall(struct.pack(">HHHB", transaction, 0, len(reply) + 1, unit) + reply)


class WebSocketHandler(socketserver.StreamRequestHandler):
    """RFC 6455 echo server: the upgrade, then unmask client frames and echo
    them unmasked. Enough to check the app's hand-written client."""

    GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    def handle(self):
        headers = {}
        request_line = self.rfile.readline().decode(errors="replace")
        while True:
            line = self.rfile.readline().decode(errors="replace").strip()
            if not line:
                break
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        key = headers.get("sec-websocket-key")
        if not request_line.startswith("GET ") or not key:
            self.wfile.write(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            return
        accept = base64.b64encode(hashlib.sha1((key + self.GUID).encode()).digest()).decode()
        self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                          f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
        while True:
            head = self.rfile.read(2)
            if len(head) < 2:
                return
            opcode = head[0] & 0x0F
            length = head[1] & 0x7F
            if length == 126:
                length = struct.unpack(">H", self.rfile.read(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self.rfile.read(8))[0]
            mask = self.rfile.read(4) if head[1] & 0x80 else b"\0\0\0\0"
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(self.rfile.read(length)))
            reply_opcode = 0xA if opcode == 0x9 else opcode
            self.wfile.write(self._frame(reply_opcode, payload))
            if opcode == 0x8:
                return

    @staticmethod
    def _frame(opcode, payload):
        if len(payload) < 126:
            header = bytes([0x80 | opcode, len(payload)])
        elif len(payload) < 65536:
            header = bytes([0x80 | opcode, 126]) + struct.pack(">H", len(payload))
        else:
            header = bytes([0x80 | opcode, 127]) + struct.pack(">Q", len(payload))
        return header + payload


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=3333)
    parser.add_argument("--modbus-port", type=int, default=0, help="also run a Modbus TCP slave (0 = off)")
    parser.add_argument("--ws-port", type=int, default=0, help="also run a WebSocket echo server (0 = off)")
    options = parser.parse_args()

    servers = [Server((options.host, options.port), BridgeHandler)]
    if options.modbus_port:
        servers.append(Server((options.host, options.modbus_port), ModbusHandler))
    if options.ws_port:
        servers.append(Server((options.host, options.ws_port), WebSocketHandler))
    for server in servers[1:]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"fake bridge on {options.host}:{options.port}" + (f", Modbus TCP on {options.modbus_port}" if options.modbus_port else "")
          + (f", WebSocket on {options.ws_port}" if options.ws_port else ""), flush=True)
    try:
        servers[0].serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    socket.setdefaulttimeout(None)
    main()
