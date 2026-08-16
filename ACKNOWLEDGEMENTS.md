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
Not used here, but it is the project that made Apple's AACP protocol legible on
non-Apple platforms, and the lineage every Linux AirPods tool now stands on.
Evaluated alongside airpods-tui before starting; the deciding factor was that
its Rust rewrite dropped the `librepods-ctl` CLI and exposes no IPC, so nothing
outside its own GUI can drive it.

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
