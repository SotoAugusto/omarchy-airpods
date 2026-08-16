#!/usr/bin/env python3
"""End-to-end bridge tests against the mock daemon.

Covers the parts that are pure protocol and would fail silently: the
length-prefixed framing, folding AppEvents into the flat state the shell reads,
and the exact JSON shape of an outbound command. That last one is easy to get
wrong in a way nothing catches — the daemon logs an error and drops the frame,
so a mis-encoded command looks identical to a device that ignored it.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "bin", "omarchy-airpods")
MAC = "AA:BB:CC:DD:EE:FF"

failures: list[str] = []


def check(name, got, want):
    if got == want:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: got {got!r}, want {want!r}")
        failures.append(name)


def main():
    root = tempfile.mkdtemp(prefix="airpods-test-")
    env = dict(os.environ, XDG_RUNTIME_DIR=root, XDG_STATE_HOME=os.path.join(root, "state"))
    state = os.path.join(root, "state.json")
    log = open(os.path.join(root, "daemon.log"), "w+")

    daemon = subprocess.Popen([sys.executable, os.path.join(HERE, "mock_daemon.py"), "40"],
                              env=env, stdout=log, stderr=subprocess.STDOUT)
    watcher = None
    try:
        time.sleep(1.0)

        def run(*args):
            return subprocess.run([BRIDGE, "--state", state, *args],
                                  env=env, capture_output=True, text=True)

        def read_state():
            with open(state) as handle:
                return json.load(handle)

        print("snapshot folding")
        snap = json.loads(run("status").stdout)
        check("daemon reachable", snap["daemon"], True)
        check("device identified", snap["mac"], MAC)
        check("name", snap["name"], "Mock AirPods Pro")
        check("listening mode decoded", snap["mode"], "anc")
        check("left battery", snap["battery"]["left"]["level"], 85)
        check("case charging flag", snap["battery"]["case"]["charging"], True)
        # status 4 means the component cannot report right now; a 0% here would
        # be a lie, and dropping the row entirely hides a component that exists.
        check("disconnected component -> level -1", snap["battery"]["headphone"]["level"], -1)
        check("ear detection", snap["ear"]["left"], "in_ear")
        check("config toggle decoded", snap["volumeSwipe"], True)
        check("config level decoded", snap["ancStrength"], 50)
        check("supports populated", sorted(snap["supports"]),
              ["adaptiveVolume", "ancStrength", "conversationAwareness",
               "oneBudAnc", "sleepDetection", "volumeSwipe"])

        print("\nwatch keeps the state file live")
        watcher = subprocess.Popen([BRIDGE, "--state", state, "watch"],
                                   env=env, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
        time.sleep(2.0)
        check("watch wrote state", read_state()["connected"], True)

        run("set-mode", "transparency")
        time.sleep(1.5)
        check("echoed mode reaches state file", read_state()["mode"], "transparency")

        print("\noutbound command encoding")
        run("set-mode", "adaptive")
        run("set", "conversation-detect", "1")
        time.sleep(1.0)
        log.flush()
        log.seek(0)
        sent = [json.loads(line[5:]) for line in log.read().splitlines()
                if line.startswith("RECV ")]
        # Identifiers serialize as integers (serde's Serialize_repr), not names.
        check("mode command shape", sent[-2], [MAC, {"ControlCommand": [13, [4]]}])
        check("toggle command shape", sent[-1], [MAC, {"ControlCommand": [40, [1]]}])

        print("\ncapability cache survives a daemon that sends no config")
        cache = os.path.join(root, "state", "omarchy", "airpods-capabilities.json")
        check("cache written", os.path.exists(cache), True)
        with open(cache) as handle:
            entry = json.load(handle)[MAC]
        check("cache remembers support", entry["supports"]["ancStrength"], True)
        check("cache remembers value", entry["values"]["ancStrength"], 50)
        check("known macs published", read_state()["knownMacs"], [MAC])

        print("\na malformed event does not kill the watcher")
        # Losing the watcher costs the drain history, which takes ten minutes
        # of wearing to rebuild, so one bad frame must not be fatal.
        run("set", "255", "1")
        time.sleep(1.5)
        check("watcher alive after bad frame", watcher.poll(), None)
        run("set-mode", "anc")
        time.sleep(1.5)
        check("still processing after bad frame", read_state()["mode"], "anc")

        print("\ndaemon disappears")
        daemon.terminate()
        daemon.wait(timeout=5)
        time.sleep(3.0)
        after = read_state()
        check("daemon flag cleared", after["daemon"], False)
        check("connection cleared", after["connected"], False)
        check("watch survived", watcher.poll(), None)

        result = run("set-mode", "anc")
        check("command without daemon exits non-zero", result.returncode != 0, True)

    finally:
        for proc in (watcher, daemon):
            if proc and proc.poll() is None:
                proc.terminate()
        log.close()

    print()
    if failures:
        print(f"{len(failures)} failed: {', '.join(failures)}")
        return 1
    print("all protocol tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
