#!/usr/bin/env python3
"""Drain-estimate maths and its refusal-to-answer guards.

Pure unit tests with a mocked clock: the real thing needs ten minutes of
battery drain per case, which is not a test anyone runs twice.

The guards matter more than the arithmetic. AirPods report battery in 1%
steps, so dividing a 1-point drop by three minutes yields a confident wrong
answer; every case below that expects `unknown` is protecting against exactly
that class of nonsense.
"""

from __future__ import annotations

import importlib.util
import os
import sys
from importlib.machinery import SourceFileLoader

BRIDGE = os.path.join(os.path.dirname(__file__), "..", "bin", "omarchy-airpods")
loader = SourceFileLoader("ap", os.path.abspath(BRIDGE))
spec = importlib.util.spec_from_loader("ap", loader)
ap = importlib.util.module_from_spec(spec)
loader.exec_module(ap)

CLOCK = [0.0]
ap.time.monotonic = lambda: CLOCK[0]

failures: list[str] = []


def check(name, got, want):
    if got == want:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: got {got!r}, want {want!r}")
        failures.append(name)


def state_at(level, charging=False):
    return {
        "battery": {
            "left": {"level": level, "charging": charging},
            "right": {"level": level + 1, "charging": charging},
        },
        "minutesLeft": -1,
    }


def feed(samples):
    """samples: [(seconds, level, charging)] -> [(seconds, level, minutesLeft)]"""
    ap.BATTERY_HISTORY.clear()
    results = []
    for seconds, level, charging in samples:
        CLOCK[0] = seconds
        state = state_at(level, charging)
        ap.update_estimate(state)
        results.append((seconds, level, state["minutesLeft"]))
    return results


print("estimate arithmetic")

# 1% every 5 minutes is 12%/hour. At t=600 the lowest bud is 98 and the window
# has a 2-point drop over 600s, which is the first sample that clears both
# guards: 98 / (2/600) / 60 == 489 minutes.
check("12%/h from 98% -> 489min", feed([(i * 300, 100 - i, False) for i in range(3)])[-1][2], 489)
check("6%/h from 44% -> 440min", feed([(i * 600, 50 - i, False) for i in range(7)])[-1][2], 440)
check("24%/h from 52% -> 129min", feed([(i * 300, 60 - i * 2, False) for i in range(5)])[-1][2], 129)

print("\nguards: refuses to answer without support")

check("single sample", feed([(0, 100, False)])[-1][2], -1)
check("span below 10min", feed([(0, 100, False), (300, 99, False)])[-1][2], -1)
# A long span but a 1-point drop is still one quantisation step of evidence.
check("drop below 2%", feed([(0, 100, False), (1200, 99, False)])[-1][2], -1)

print("\nguards: discards a discharge that ended")

discharging = [(i * 600, 90 - i * 3, False) for i in range(4)]
check("charging clears history",
      feed(discharging + [(2400, 78, True)])[-1][2], -1)
check("level rise clears history",
      feed(discharging + [(2400, 95, False)])[-1][2], -1)
check("gap over 30min clears history",
      feed([(0, 90, False), (600, 87, False), (1200, 84, False), (3200, 82, False)])[-1][2], -1)

print("\nguards: recovers after a reset")

# After a charge the samples restart; a fresh discharge must estimate again.
after_charge = feed(discharging + [(2400, 78, True)] +
                    [(2400 + i * 600, 100 - i * 2, False) for i in range(1, 4)])
check("estimates again after charging", after_charge[-1][2] > 0, True)

print("\nno battery report at all")
empty = {"battery": {}, "minutesLeft": 99}
ap.update_estimate(empty)
check("no levels -> unknown", empty["minutesLeft"], -1)

print()
if failures:
    print(f"{len(failures)} failed: {', '.join(failures)}")
    sys.exit(1)
print("all estimate tests passed")
