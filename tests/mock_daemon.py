#!/usr/bin/env python3
"""A stand-in for the airpods-tui daemon, speaking the same wire protocol.

Lets the bridge be tested without AirPods, without BlueZ, and without the real
daemon — which matters because the interesting cases (a device that refuses a
write, a config block that never arrives) are hard to stage on real hardware.

Protocol, from airpods-tui's src/ipc.rs:
  frame   = 4-byte big-endian length, then JSON
  inbound = ["<mac>", {"ControlCommand": [<identifier>, [<byte>]]}]
  outbound= AppEvent, with the whole snapshot replayed on connect
"""

from __future__ import annotations

import json
import os
import socket
import struct
import sys
import threading
import time

SOCK = os.path.join(os.environ["XDG_RUNTIME_DIR"], "airpods-tui.sock")
MAC = "AA:BB:CC:DD:EE:FF"
CLIENTS: set[socket.socket] = set()

# Mirrors a real AirPods Pro snapshot: identity, the config block, batteries,
# ear state, and the listening mode.
SNAPSHOT = [
    {"DeviceConnected": {"mac": MAC, "name": "Mock AirPods Pro", "product_id": 8228}},
    {"AACPEvent": [MAC, {"ControlCommand": {"identifier": 0x25, "value": [1]}}]},
    {"AACPEvent": [MAC, {"ControlCommand": {"identifier": 0x28, "value": [2]}}]},
    {"AACPEvent": [MAC, {"ControlCommand": {"identifier": 0x1B, "value": [2]}}]},
    {"AACPEvent": [MAC, {"ControlCommand": {"identifier": 0x26, "value": [2]}}]},
    {"AACPEvent": [MAC, {"ControlCommand": {"identifier": 0x35, "value": [2]}}]},
    {"AACPEvent": [MAC, {"ControlCommand": {"identifier": 0x2E, "value": [50]}}]},
    {"AACPEvent": [MAC, {"BatteryInfo": [
        {"component": 4, "level": 85, "status": 2},
        {"component": 2, "level": 82, "status": 2},
        {"component": 8, "level": 60, "status": 1},
        # The case reports level 0 / disconnected whenever the buds are not in
        # it, which the bridge must not render as "0%".
        {"component": 1, "level": 0, "status": 4},
    ]}]},
    {"AACPEvent": [MAC, {"EarDetection": {
        "old_left": 1, "old_right": 1, "new_left": 0, "new_right": 0}}]},
    {"AACPEvent": [MAC, {"ControlCommand": {"identifier": 0x0D, "value": [2]}}]},
]

# Identifiers the mock echoes back when written. Listening mode echoes on real
# hardware; the config toggles do not, and that asymmetry is the whole reason
# the shell holds them optimistically, so the mock reproduces it.
ECHOES = {0x0D}

# Writing this identifier makes the mock reply with a structurally invalid
# event, so the bridge's resilience to a bad frame can be tested on purpose
# rather than waited for.
POISON = 0xFF
POISON_EVENT = {"AACPEvent": [MAC, {"BatteryInfo": "not-a-list"}]}

# Writing this makes the mock emit a burst of the live talking signal and a
# batch of unchanged battery reports — the two things a real device sends
# repeatedly without the shell needing to redraw.
CHATTER = 0xFE


def write_msg(conn, payload):
    data = json.dumps(payload).encode()
    conn.sendall(struct.pack(">I", len(data)) + data)


def read_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError
        buf += chunk
    return buf


def serve(conn):
    CLIENTS.add(conn)
    for event in SNAPSHOT:
        write_msg(conn, event)
    try:
        while True:
            (length,) = struct.unpack(">I", read_exact(conn, 4))
            payload = json.loads(read_exact(conn, length))
            print("RECV " + json.dumps(payload), flush=True)
            if not (isinstance(payload, list) and isinstance(payload[1], dict)):
                continue
            command = payload[1]
            if "ControlCommand" not in command:
                continue
            identifier, value = command["ControlCommand"]
            if identifier == CHATTER:
                for _ in range(25):
                    for peer in list(CLIENTS):
                        try:
                            write_msg(peer, {"AACPEvent": [MAC, {"ConversationalAwareness": 1}]})
                            write_msg(peer, {"AACPEvent": [MAC, {"ConversationalAwareness": 2}]})
                            write_msg(peer, {"AACPEvent": [MAC, {"BatteryInfo": [
                                {"component": 4, "level": 85, "status": 2}]}]})
                        except OSError:
                            CLIENTS.discard(peer)
                continue
            if identifier == POISON:
                for peer in list(CLIENTS):
                    try:
                        write_msg(peer, POISON_EVENT)
                    except OSError:
                        CLIENTS.discard(peer)
                continue
            if identifier not in ECHOES:
                continue
            # Broadcast, like the daemon's own channel — not just to the sender.
            event = {"AACPEvent": [payload[0], {
                "ControlCommand": {"identifier": identifier, "value": value}}]}
            for peer in list(CLIENTS):
                try:
                    write_msg(peer, event)
                except OSError:
                    CLIENTS.discard(peer)
    except (ConnectionError, struct.error, OSError):
        pass
    finally:
        CLIENTS.discard(conn)
        conn.close()


def main():
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCK)
    server.listen(4)
    print(f"mock daemon on {SOCK}", flush=True)

    deadline = time.time() + float(sys.argv[1] if len(sys.argv) > 1 else 30)
    server.settimeout(1.0)
    while time.time() < deadline:
        try:
            conn, _ = server.accept()
        except socket.timeout:
            continue
        threading.Thread(target=serve, args=(conn,), daemon=True).start()
    server.close()
    os.unlink(SOCK)


if __name__ == "__main__":
    main()
