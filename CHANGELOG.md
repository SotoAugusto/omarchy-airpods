# Changelog

## 0.1.7 — 2026-08-16

### Fixed

- The bar icon is now shown whenever setup is incomplete, regardless of
  `hideWhenDisconnected`. It was hidden while nothing was connected — which is
  the normal state of a fresh install — so the setup checklist was unreachable
  in exactly the case it exists for. Installing the plugin produced no icon, no
  way to open the panel, and every appearance of something broken rather than
  something unconfigured.
- While setup is incomplete the icon is a wrench in the urgent colour rather
  than a headphone, so it reads as needing attention instead of as a device
  that happens to be away, and the tooltip says what to do.

The icon returns to hiding on its own once the prerequisites are met, without
a restart — the check re-runs every 20 seconds.

## 0.1.6 — 2026-08-16

### Changed

- Documented what removing the plugin the ordinary way actually leaves behind,
  and how to clean it up afterwards. `teardown` is deleted along with the
  plugin, so anyone who removed it first had no script left to run and nothing
  telling them what survived.
- The uninstall row now names the consequence of skipping teardown — the daemon
  keeps running and starts at every login — rather than only explaining why it
  asks before stopping it.

Verified by removing the plugin through the plain `omarchy plugin remove`
workflow, which is what the Setup → Plugins → Remove Plugin menu runs: no
process is left behind, `shell.json` is tidied, and a git-installed plugin
leaves no backup folder.

## 0.1.5 — 2026-08-16

### Fixed

- `teardown` now disables the plugin before cleaning up. Found by actually
  running an uninstall: while the plugin is enabled its service holds a socket,
  rewrites the state file, and — by design — restarts the daemon whenever it
  finds it stopped. Teardown was being undone as it ran. The daemon came back
  within eight seconds and the state file was recreated immediately, so a
  completed uninstall still left a running daemon and a live state file behind.

## 0.1.4 — 2026-08-16

### Added

- **Uninstall this plugin** in the panel settings, copying the whole removal
  line in the only order that works. `teardown` lives inside the plugin
  directory, so removing the plugin first deletes the script meant to clean up
  after it; chaining them removes the chance to get that wrong.

### Fixed

- The settings section, and therefore uninstall, was gated behind an active
  connection and known device capabilities — invisible on a fresh install where
  nothing works, which is exactly when someone wants to remove it. The section
  now opens regardless; the device-specific controls inside keep their own
  guards.

## 0.1.3 — 2026-08-16

### Added

- A setup checklist in the panel. The plugin now checks its three
  prerequisites — the daemon binary, the BlueZ `DeviceID`, and whether the
  user unit is enabled — and when one is missing it says which, shows the
  exact command, and copies it to the clipboard on click. Every unmet cause
  otherwise produces the same symptom: an empty widget.
- A "Do all of it" row that copies the path to `setup`, for anyone who would
  rather run one command than three.

The checklist appears only while something is actually missing, and re-checks
every 20 seconds so it clears itself once the commands have been run, rather
than needing a shell restart to notice.

## 0.1.2 — 2026-08-16

### Added

- `setup` and `teardown` scripts for the parts a plugin cannot do for itself.
  Omarchy never executes anything from a plugin — it clones files, validates
  the manifest and flips a bit — so installing the daemon, setting the BlueZ
  `DeviceID` and restarting bluetooth are a script you run on purpose. Both are
  idempotent; `setup` prompts for sudo only if the DeviceID is not already set.

### Changed

- The daemon now starts itself. If the `airpods-tui` user unit exists but is
  not running, the plugin starts it — no privileges needed, so "enable the
  service" is no longer a step anyone has to remember. If the unit does not
  exist the plugin stops asking and says the package is missing, rather than
  retrying something it cannot fix.
- The disconnected panel now distinguishes its three causes: daemon starting,
  package not installed, or connected-but-no-AirPods. Only one of those is
  yours to fix, and it now says which.

## 0.1.1 — 2026-08-16

### Fixed

- Events that change nothing the shell renders no longer cost a state write.
  Measured: a burst of 75 such events caused 75 file writes before, and none
  now — each of which was also a JSON re-parse and a binding cascade in every
  bar instance.
- The live `ConversationalAwareness` talking signal is no longer recorded. It
  fires continuously while the wearer speaks and nothing rendered it, so with
  conversation awareness enabled it was the loudest write source in the
  plugin — invisible in testing only because the setting was off.

## 0.1.0 — 2026-08-16

First release.

### Added

- Battery per bud and case, with charging state, a low-battery notification at
  20% and 10%, and a tinted bar label below the threshold.
- Time remaining, projected from the measured drain rate of the lowest bud.
  Stays silent until the samples can support an answer — ten minutes and a 2%
  drop — because AirPods report in 1% steps and a shorter window produces a
  confident wrong number.
- Noise control: Off, Noise Cancellation, Transparency, Adaptive. Icon-only
  buttons with the full name in the tooltip and in the hero line.
- Per-bud ear detection, shown against each battery row, so "one in ear" says
  which one.
- The config the device reports: adaptive ANC strength, ANC with one bud,
  adaptive volume, volume swipe, sleep detection, conversation awareness.
  Controls appear only for identifiers the AirPods have actually reported.
- Rename, at the bottom of the folded settings section.
- AAC pinning. The negotiated codec was observed dropping to SBC-XQ on a
  reconnect with no user action, so the AAC card profile is re-selected on
  connect. Retries until the bluez card exists, which took up to 12s in
  testing. Turn it off with **Force AAC on connect**.
- Keyboard shortcuts behind a keyboard button: `1`–`4` select a mode, `c`
  cycles, `a` toggles conversation awareness, `s` and `k` fold the settings and
  shortcut lists. The list also documents the mouse and the global bindings, so
  the undiscoverable parts are written down somewhere.
- Bar tooltip with device, per-bud charge, mode and placement.
- A watchdog for the race that broke first-time setup: BlueZ reporting the
  AirPods connected while the daemon insists otherwise. After 30 seconds of
  disagreement it restarts the `airpods-tui` **user** unit, capped at three
  attempts. Matching is by MAC, so another headset cannot trigger it.
- `tests/run` — the wire protocol against a mock daemon, and the battery
  estimate on a mocked clock. No AirPods, BlueZ or daemon required.

### Notes on the device

Behaviour found by measurement rather than documentation, and worth knowing
before filing a bug against this plugin. The full list is in the README.

- Listening mode echoes back; config toggles are applied **silently** and only
  surface after a reconnect. Toggles are therefore held optimistically, so a
  switch does not sit on its old value looking broken.
- Mode changes are refused unless a bud is in an ear — in the case and merely
  out of the ear both fail, and the write is accepted before being ignored.
- The config block does not survive a reconnect, so capabilities are cached
  per-MAC in `~/.local/state/omarchy/airpods-capabilities.json`. Without that
  the panel would hide controls that work.
- `AllowOffOption` is never reported by AirPods Pro (`0x2024`) yet Off works,
  so absence is not treated as refusal.
- The case reports its charge only while the buds are inside it. Out of the
  case it sends level 0 / disconnected, which is shown as unavailable rather
  than as 0%.

### Known limitations

- A config write the device *rejects* shows as applied until the next
  reconnect, because rejections are as silent as acceptances.
- Drain history is in memory, so the time estimate resets when the shell
  restarts.
- `shortcuts` and `settings` use a direct IPC target, which reaches one
  arbitrary instance on a multi-monitor setup. Device actions are unaffected.
- Untested on AirPods Max — the "Headphones" battery row has never rendered.
