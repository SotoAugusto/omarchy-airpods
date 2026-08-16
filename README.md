# AirPods for Omarchy

Battery, noise control and the settings Apple hides, in the Omarchy bar.

![Preview](preview.png)

The bar slot shows the **active listening mode** rather than a headphones icon —
the widget only exists while AirPods are connected, so a slot saying "AirPods
are here" says nothing you cannot already see. Hovering gives per-bud charge,
mode and placement without opening anything.

## Built on other people's work

This plugin draws no Bluetooth frames of its own. It stands on two projects:

- **[LibrePods](https://github.com/librepods-org/librepods)** — the project that
  reverse-engineered Apple's AACP protocol and made AirPods legible on
  non-Apple platforms. Every Linux AirPods tool, this one included, exists
  downstream of that work. Its Linux client has been rewritten from Qt to Rust
  (the `linux/rust` branch, packaged as `librepods-rust-bin`), an `iced` desktop
  app with a tray icon that is now growing beyond Apple hardware. It is the
  natural choice if you want a GUI rather than a bar widget — this plugin does
  not drive it, because the Rust rewrite exposes no CLI or IPC for anything
  outside its own window to talk to.
- **[airpods-tui](https://github.com/annoyedmilk/airpods-tui)** by annoyedmilk —
  the daemon this plugin actually speaks to. It owns the L2CAP session, the
  protocol, ear detection and media handling.

What is left for this plugin is the shell front end. See
[ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md) for the rest, including where the
debt is knowledge rather than code.

## Requirements

[`airpods-tui`](https://github.com/annoyedmilk/airpods-tui) running as a daemon.
It owns the Bluetooth session; this plugin talks to it, not to your AirPods.

```bash
yay -S airpods-tui-bin          # or airpods-tui-git to build from source
sudo systemctl restart bluetooth
systemctl --user enable --now airpods-tui
```

The package's install hook adds `DeviceID = bluetooth:004C:0000:0000` to
`/etc/bluetooth/main.conf`, which makes your machine identify as Apple. Without
it the AirPods pair and play audio, but refuse to open the control channel that
everything here depends on — so the bluetooth restart must happen **before** you
pair.

## Install

```bash
omarchy plugin add https://github.com/SotoAugusto/omarchy-airpods --enable
omarchy restart shell
```

## Removal

```bash
omarchy plugin remove io.github.sotoaugusto.airpods
omarchy restart shell
```

That removes the plugin and its bar entry. Two things live outside the plugin
directory and are left behind deliberately, since removing a shell widget
should not reconfigure your audio or Bluetooth:

```bash
rm -f ~/.local/state/omarchy/airpods-capabilities.json   # remembered device capabilities
```

The `airpods-tui` daemon and the BlueZ `DeviceID` line belong to that package,
not to this plugin — remove them with `yay -R airpods-tui-bin`, whose own hook
reverts `/etc/bluetooth/main.conf`.

## What it changes on your system

Nothing at install time. While running it may, all of it documented and
reversible:

- write remembered device capabilities to
  `~/.local/state/omarchy/airpods-capabilities.json` and live state to
  `$XDG_RUNTIME_DIR/omarchy-airpods.json`
- re-select the AAC PipeWire card profile on connect — turn off with the
  **Force AAC on connect** setting
- restart the `airpods-tui` **user** unit if BlueZ and the daemon disagree for
  30 seconds, capped at three attempts

It never uses sudo, never edits your Hyprland or shell config, and never
touches `/etc`.

## What it does

- **Battery** per bud and case, with charging state and a low-battery warning
- **Time remaining**, projected from the measured drain rate
- **Noise control** — Off / Noise Cancellation / Transparency / Adaptive
- **Ear detection** shown per bud, so "one in ear" says which
- **Settings** the device reports: adaptive ANC strength, ANC with one bud,
  adaptive volume, volume swipe, sleep detection, conversation awareness
- **Rename**
- **AAC pinning** — re-selects the AAC card profile on connect

### Controls

| | |
|---|---|
| Click | Open the panel |
| Right-click | Noise Cancellation ⇄ Transparency |
| Middle-click | Cycle all modes |
| `1`–`4` | Select a mode directly |
| `c` | Cycle modes |
| `a` | Conversation awareness |
| `s` / `k` | Show settings / shortcuts |

Right-click flips that specific pair because it is what the AirPods' own
press-and-hold does, and because every other Omarchy bar widget uses right-click
for one action rather than a long cycle.

Optional Hyprland bindings:

```lua
o.bind("SUPER + ALT + A", "AirPods", "omarchy-shell shell toggle io.github.sotoaugusto.airpods")
o.bind("SUPER + ALT + N", "AirPods noise mode", "omarchy-shell io.github.sotoaugusto.airpods cycleMode")
o.bind("SUPER + ALT + Q", "AirPods quiet toggle", "omarchy-shell io.github.sotoaugusto.airpods toggleQuiet")
```

## How it works

```
airpods-tui daemon  ──unix socket──  bin/omarchy-airpods  ──state file──  Service.qml  ──  Panel.qml
```

`bin/omarchy-airpods` owns the socket because QML cannot comfortably frame a
length-prefixed binary protocol. It folds the daemon's event stream into a flat
JSON state file the shell watches, and accepts one-shot commands.

`Service.qml` is a `service` plugin, so the shell mounts it **once** regardless
of monitor count. A bar surface is built per monitor, so putting the socket in
the widget would mean one `watch` process per display and every command sent
twice. `Panel.qml` only renders.

```bash
tests/run          # no AirPods, daemon or BlueZ needed
```

## Protocol notes

Everything here was measured against AirPods Pro (`0x2024`). Written down
because none of it is documented and all of it is easy to get wrong.

**Identifiers serialize as integers, not names.** `ControlCommandIdentifiers`
derives serde's `Serialize_repr`, so a command is
`["<mac>", {"ControlCommand": [13, [2]]}]` — not `"ListeningMode"`. A name is
accepted by the JSON parser, rejected by the deserializer, and dropped with an
error you will not see.

**Listening mode echoes; config toggles do not.** Setting a mode comes back on
the event stream within a second. Setting conversation awareness is *applied*
but never echoed — the new value only appears after the daemon reconnects and
re-reads the config. Config toggles are therefore held optimistically in the UI;
without that a switch sits on its old value and reads as broken.

**Modes are refused unless a bud is in an ear.** In the case *and* merely out of
the ear both fail. The daemon accepts the write and the buds ignore it, so this
looks exactly like a bug.

**The config block does not survive a reconnect.** The device dumps ~15
identifiers shortly after the AACP session comes up; the daemon's retained
snapshot drops `ControlCommand` events, so a client connecting later sees none
of them. Support is a property of the device, not the session, so it is cached
per-MAC in `~/.local/state/omarchy/airpods-capabilities.json`. Without that the
panel hides controls that work.

**`AllowOffOption` is never reported, but Off works.** Gating the Off button on
a positive report hid a mode the device accepts. Absence is not refusal.

**The case only knows its charge through the buds.** With them out it reports
level 0 / status disconnected — lid open or shut. Rendering that as "0%" is a
lie; hiding the row makes it look broken. It shows as unavailable.

**The codec is not stable.** AirPods speak only SBC and AAC. A fresh connect
negotiated AAC and a later reconnect came back on SBC-XQ unprompted.
`pactl send-message … switch-codec` answers `No such entity`; the working lever
is `set-card-profile <card> a2dp-sink`. The bluez card can take ~12s to appear
after BlueZ reports the device connected, so the pin retries.

## Known limitations

- A config write the device *rejects* shows as applied until the next reconnect,
  because rejections are as silent as acceptances.
- Drain history is in memory, so the time estimate resets when the shell
  restarts and needs ~10 minutes of wear to reappear.
- `shortcuts` and `settings` use a direct IPC target, which on a multi-monitor
  setup reaches one arbitrary instance. Device actions are unaffected.
- Untested on AirPods Max — the "Headphones" battery row has never rendered.

## License

MIT — see [LICENSE](LICENSE).

No third-party code is vendored.

The Bluetooth work belongs to **[airpods-tui](https://github.com/annoyedmilk/airpods-tui)**
by annoyedmilk (GPL-3.0-or-later), which this plugin drives as a separate
process over a Unix socket, and upstream of that to
**[LibrePods](https://github.com/librepods-org/librepods)** (AGPL-3.0-or-later),
which worked out Apple's AACP protocol in the first place. Neither is vendored
or linked; both are why this is possible.
