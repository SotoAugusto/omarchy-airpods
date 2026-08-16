# Acknowledgements

No third-party code is vendored into this plugin. What follows is what it was
built on, learned from, or runs inside — including cases where the debt is
knowledge rather than code, since those are the ones that are easy to leave
unsaid.

## Depends on

**[airpods-tui](https://github.com/annoyedmilk/airpods-tui)** by annoyedmilk —
GPL-3.0-or-later. Every byte that reaches the AirPods goes through its daemon.
It owns the L2CAP session, the AACP protocol, ear detection, media handling and
the BlueZ `DeviceID` setup; this plugin is a shell front end that speaks to it
over a Unix socket and would do nothing at all without it.

The debt is larger than "it is a dependency". The bridge's wire format was
derived by reading its source:

- `src/ipc.rs` — the 4-byte big-endian length prefix, the JSON framing, the
  snapshot-replay-on-connect behaviour, and the `(String, DeviceCommand)` tuple
  shape of an inbound command.
- `src/bluetooth/aacp.rs` — the `ControlCommandIdentifiers` table, the
  `BatteryComponent` / `BatteryStatus` / `EarDetectionStatus` enums, and the
  fact that all of them serialize as integers rather than names because they
  derive serde's `Serialize_repr`.
- `src/devices/enums.rs` — the listening-mode byte values.

Those are interface facts rather than copied implementation, and the two
programs are separate processes communicating over a socket, which is why this
plugin is MIT rather than GPL. If that reading is ever disputed, relicensing to
match is the obvious remedy and no great loss.

**[LibrePods](https://github.com/librepods-org/librepods)** — AGPL-3.0-or-later.
Not used here, and no code or protocol constant in this plugin came from it —
but it is the project that made Apple's AACP protocol legible on non-Apple
platforms, and the lineage every Linux AirPods tool now stands on.

Its **Rust port** deserves naming specifically. The Linux client was rewritten
from Qt/C++ to Rust on the `linux/rust` branch — `iced` for the UI, `ksni` for
the tray, `bluer` for Bluetooth — and it is what `librepods-rust-bin` and
`librepods-rust-git` package. It is also expanding past Apple: `devices/nothing.rs`
and a device-type registry mean it is becoming a multi-vendor earbud app rather
than an AirPods one.

It was evaluated alongside airpods-tui before any of this was written. The
deciding factor was not quality: the Qt client shipped a `librepods-ctl` CLI,
and the Rust rewrite dropped it without replacing it — its `dbus-crossroads`
dependency comes from the tray library, not a control interface. Its entire
argument surface is `--debug`, `--no-tray`, `--start-minimized`, `--le-debug`
and `--version`. Nothing outside its own window can drive it, which rules it
out as a backend for a bar widget and rules it *in* as the better choice for
anyone who wants a desktop app.

## Runs inside

**[Omarchy](https://github.com/basecamp/omarchy)** — MIT. The desktop and the
shell that hosts this. The plugin contract (`manifest.json`, `kinds`,
`entryPoints`), the `qs.Ui` component kit (`Panel`, `KeyboardPanel`,
`PanelHero`, `PanelSectionHeader`, `PanelSeparator`, `PanelActionButton`,
`PanelSlider`, `ButtonGroup`, `ToggleSwitch`, `WidgetButton`, `TextField`,
`OpticalGlyph`), and the `qs.Commons` `Style` / `Color` / `Util` tokens are all
Omarchy's.

Several of its solutions were adopted after nearly inventing worse ones:

- The **service + view split** is modeled on `plugins/services/media`, which
  keeps shared state in a `service`-kind plugin reached through
  `shell.serviceFor(id)`. A bar surface is built per monitor, so without it this
  plugin would have held one socket per display.
- The **panel structure** — `manageIpc: false` plus an owned `IpcHandler`,
  `KeyboardPanel` wrapping a `PanelKeyCatcher` — follows
  `plugins/panels/bluetooth`.
- The **right-click convention** was read off the first-party widgets rather
  than guessed: audio toggles mute, bluetooth toggles the adapter, tailscale
  toggles the VPN. One action, not a long cycle.
- `Bar.findPanelWidget` and its comment about a fixed IPC target reaching only
  one per-monitor instance is why the panel hotkey routes through
  `shell toggle` instead of a direct target.

**[Quickshell](https://quickshell.outfoxxed.me/)** — LGPL-3.0-only. The QML
shell framework Omarchy is built on. `Process`, `FileView`, `IpcHandler`,
`SystemClock` and `Quickshell.Bluetooth` do the work that would otherwise need a
compiled helper.

## Talks to

**[BlueZ](https://www.bluez.org/)** — GPL-2.0-only. The Linux Bluetooth stack.
Its `org.bluez.Device1` properties are what the daemon watches, and what the
plugin's watchdog reads to notice that BlueZ and the daemon disagree.

**[PipeWire](https://pipewire.org/)** / WirePlumber — MIT and LGPL-2.1-or-later.
Bluetooth audio routing and the A2DP card profiles. AAC pinning is a
`pactl set-card-profile` against the `bluez5` device it exposes.

## Looks like

**[Material Design Icons](https://pictogrammers.com/library/mdi/)** — Apache-2.0,
delivered through **[Nerd Fonts](https://www.nerdfonts.com/)** in
**JetBrains Mono** (OFL-1.1). Every glyph in the bar and the panel is theirs.
The noise-control set was chosen by rendering candidates in the actual bar font
and comparing them at 16px, which is the only size that matters and the one
where the obvious first choices fell apart.

## Built with

**Python 3** standard library only — `socket`, `struct`, `json`, `argparse`.
The bridge has no third-party dependencies and links nothing, which keeps a
component that holds a long-lived socket boring on purpose.

**[Claude Code](https://claude.com/claude-code)** — used throughout to reverse
the wire format, build the plugin, and test it against real hardware.
