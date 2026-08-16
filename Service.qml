import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth

// Everything that must exist once, not once per screen.
//
// A bar surface is created per monitor, so a two-display desktop would
// otherwise run two `watch` processes holding two sockets against the same
// daemon, and every mode change would be sent twice. The shell mounts a
// `service` plugin exactly once and hands it to views via
// shell.serviceFor(id), so the socket, the state file and the command queue
// live here and the panel only renders them.
Item {
  id: root

  // Injected by the shell when the service is mounted.
  property var shell: null
  property var manifest: null
  property var settings: ({})

  // Views hand their inline shell.json settings over; every panel instance has
  // the same ones, so whichever arrives first is as good as any.
  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property string cli: pluginDir + "bin/omarchy-airpods"

  // The bridge defaults to $XDG_RUNTIME_DIR, but the shell's environment is
  // not guaranteed to match a command's, so the path is computed once here and
  // handed to both sides explicitly. Falling back to /tmp keeps a session
  // without XDG_RUNTIME_DIR degraded rather than broken.
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string statePath: runtimeDir + "/omarchy-airpods.json"

  // ---- state -------------------------------------------------------------

  property var state: ({})

  readonly property bool daemonRunning: state.daemon === true
  readonly property bool connected: state.connected === true
  readonly property string deviceName: state.name || "AirPods"
  readonly property string mac: state.mac || ""
  readonly property string mode: state.mode || ""
  readonly property bool allowOff: state.allowOff !== false

  // Config toggles are applied by the AirPods but never echoed back on the
  // live stream — measured on AirPods Pro 0x2024: the new value only appears
  // after the daemon reconnects and re-reads the config block. Listening mode
  // does echo, so only these are held optimistically; without it the switch
  // sits on its old value until the next reconnect and reads as broken.
  property var pendingFlags: ({})

  // Bumped on every write so the named properties below re-evaluate; QML does
  // not track reads of pendingFlags made inside a function.
  property int flagRevision: 0

  function flag(name) {
    var pending = pendingFlags[name]
    return pending === undefined ? state[name] === true : pending
  }

  readonly property bool conversationAwareness: flagRevision >= 0 && flag("conversationAwareness")
  readonly property bool earDetection: flagRevision >= 0 && flag("earDetection")
  readonly property bool oneBudAnc: flagRevision >= 0 && flag("oneBudAnc")
  readonly property bool adaptiveVolume: flagRevision >= 0 && flag("adaptiveVolume")
  readonly property bool sleepDetection: flagRevision >= 0 && flag("sleepDetection")
  readonly property bool volumeSwipe: flagRevision >= 0 && flag("volumeSwipe")

  readonly property int ancStrength: pendingFlags.ancStrength !== undefined
    ? pendingFlags.ancStrength
    : (state.ancStrength || 0)

  // True while the controls are drawn from remembered capabilities rather than
  // something the device reported this session. The AirPods send their config
  // block once per AACP session and do not always resend it on reconnect.
  readonly property bool stale: state.stale === true

  function holdFlag(name, value) {
    var next = {}
    for (var key in pendingFlags) next[key] = pendingFlags[key]
    next[name] = value
    pendingFlags = next
    flagRevision += 1
  }

  // Once the device confirms a held value — which only happens on reconnect —
  // stop overriding, so the report becomes the authority again.
  function reconcileFlags() {
    var next = {}
    var changed = false
    for (var key in pendingFlags) {
      if (state[key] === pendingFlags[key]) changed = true
      else next[key] = pendingFlags[key]
    }
    if (changed) {
      pendingFlags = next
      flagRevision += 1
    }
  }
  readonly property var battery: state.battery || ({})
  readonly property var ear: state.ear || ({})

  // Only what the device has actually told us about. AirPods Pro report a
  // subset of the config identifiers — this pair is absent on some models, and
  // a switch rendered from a default rather than a report is a switch that
  // lies about the device's state.
  readonly property var supports: state.supports || ({})

  function reports(name) {
    return supports[name] === true
  }

  readonly property bool reportsConversationAwareness: supports.conversationAwareness === true
  readonly property bool reportsEarDetection: supports.earDetection === true
  readonly property bool reportsOneBudAnc: supports.oneBudAnc === true
  readonly property bool reportsAdaptiveVolume: supports.adaptiveVolume === true
  readonly property bool reportsSleepDetection: supports.sleepDetection === true
  readonly property bool reportsVolumeSwipe: supports.volumeSwipe === true
  readonly property bool reportsAncStrength: supports.ancStrength === true

  // Whether there is anything to put in the extra-settings section at all.
  readonly property bool hasExtraSettings: reportsOneBudAnc || reportsAdaptiveVolume
    || reportsSleepDetection || reportsVolumeSwipe || reportsAncStrength

  function batteryOf(component) {
    var entry = battery[component]
    return entry && typeof entry.level === "number" ? entry.level : -1
  }

  // The device has told us this component exists, even if it cannot report a
  // level right now. Distinguishes "no case on an AirPods Max" from "case is
  // present but the buds are not in it".
  function batteryKnown(component) {
    return battery[component] !== undefined
  }

  function chargingOf(component) {
    var entry = battery[component]
    return !!(entry && entry.charging)
  }

  // The bud that dies first ends the session, so that is the number worth
  // showing. The case is excluded — it is not what runs out mid-call.
  readonly property int lowestBudBattery: {
    var levels = []
    var candidates = ["left", "right", "headphone"]
    for (var i = 0; i < candidates.length; i++) {
      var level = batteryOf(candidates[i])
      if (level >= 0) levels.push(level)
    }
    if (levels.length === 0) return -1
    var lowest = levels[0]
    for (var j = 1; j < levels.length; j++) if (levels[j] < lowest) lowest = levels[j]
    return lowest
  }

  readonly property bool inEar: ear.left === "in_ear" || ear.right === "in_ear"

  // Projected minutes until the lowest bud is empty, or -1 while the drain
  // samples cannot support an answer. A percentage says where you are; this
  // says whether you can take the next call.
  readonly property int minutesLeft: state.minutesLeft === undefined ? -1 : state.minutesLeft

  readonly property string timeLeftLabel: {
    if (minutesLeft < 0) return ""
    if (minutesLeft < 60) return "~" + minutesLeft + "m left"
    var hours = Math.floor(minutesLeft / 60)
    var mins = minutesLeft % 60
    return mins === 0 ? "~" + hours + "h left" : "~" + hours + "h " + mins + "m left"
  }

  // ---- the watched state file ---------------------------------------------

  property FileView stateFile: FileView {
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        root.state = JSON.parse(text())
      } catch (e) {
        root.state = ({})
      }
      root.reconcileFlags()
    }
    onLoadFailed: root.state = ({})
  }

  // ---- the socket owner ----------------------------------------------------

  // One long-lived process holds the Unix socket and folds every event into
  // the state file. It reconnects on its own, so a daemon restart does not
  // need anything from this side.
  Process {
    id: watcher
    running: true
    command: [root.cli, "--state", root.statePath, "watch"]
    stderr: StdioCollector {
      waitForEnd: false
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw !== "") console.warn("airpods watch:", raw)
      }
    }
    // The bridge is meant to outlive any single daemon; if it exits anyway,
    // bring it back rather than leaving the bar frozen on stale state.
    onExited: function(code) {
      if (code !== 0) console.warn("airpods watch exited", code)
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 3000
    repeat: false
    onTriggered: if (!watcher.running) watcher.running = true
  }

  // ---- codec ---------------------------------------------------------------

  // AirPods only speak SBC and AAC, and PipeWire ranks AAC highest — but the
  // choice is not stable. Measured here: a fresh connect negotiated AAC, and a
  // later reconnect came back on SBC-XQ with no user action. PipeWire exposes
  // each codec as a card profile, so re-selecting the AAC profile is how you
  // pin it. `switch-codec` via pactl send-message is not available on this
  // build — it answers "No such entity".
  readonly property bool forceAac: setting("forceAac", true)
  readonly property string cardName: mac === "" ? "" : "bluez_card." + mac.replace(/:/g, "_")

  property string codecError: ""
  property int codecAttempts: 0

  readonly property int codecMaxAttempts: 12

  Process {
    id: codecProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.codecError = String(text || "").trim()
    }
    // pactl exits non-zero while the card is still absent. That is the retry
    // signal, not an error worth surfacing.
    onExited: function(code) {
      if (code === 0) {
        root.codecError = ""
        codecTimer.stop()
      }
    }
  }

  function applyAacProfile() {
    if (!forceAac || cardName === "" || codecProc.running) return
    codecProc.command = ["pactl", "set-card-profile", cardName, "a2dp-sink"]
    codecProc.running = true
  }

  // The card does not exist the instant BlueZ reports the device connected —
  // PipeWire has to see it and build the profile list first, which was
  // measured at up to ~12s on a reconnect. A single delayed shot fired into
  // the void; this retries until pactl reports success or the window closes.
  Timer {
    id: codecTimer
    interval: 3000
    repeat: true
    running: false
    onTriggered: {
      if (!root.connected || root.codecAttempts >= root.codecMaxAttempts) {
        stop()
        return
      }
      root.codecAttempts += 1
      root.applyAacProfile()
    }
  }

  onConnectedChanged: {
    codecAttempts = 0
    if (connected && forceAac) codecTimer.restart()
    else codecTimer.stop()
    // A fresh session re-arms the low-battery latches, and a healthy one
    // clears the watchdog budget so a later independent race still gets its
    // three attempts rather than inheriting an exhausted counter.
    if (!connected) firedThresholds = ({})
    else recoveryAttempts = 0
  }

  // ---- commands ------------------------------------------------------------

  property string actionError: ""
  property var actionQueue: []

  Process {
    id: actionProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw !== "") root.actionError = raw
      }
    }
    onExited: function(code) {
      if (code === 0) root.actionError = ""
      root.drainQueue()
    }
  }

  function run(args) {
    if (actionProc.running) {
      actionQueue = actionQueue.concat([args])
      return
    }
    actionProc.command = [root.cli, "--state", root.statePath].concat(args)
    actionProc.running = true
  }

  function drainQueue() {
    if (actionQueue.length === 0) return
    var queued = actionQueue.slice()
    var next = queued.shift()
    actionQueue = queued
    actionProc.command = [root.cli, "--state", root.statePath].concat(next)
    actionProc.running = true
  }

  // The daemon echoes the AirPods' acknowledgement back through the state
  // file, so nothing is set optimistically here — a mode that did not take
  // stays visibly untaken instead of lying to the user for a second.
  function setMode(mode) {
    if (!connected) return
    run(["set-mode", String(mode)])
  }

  function setFlag(identifier, enabled) {
    if (!connected) return
    run(["set", String(identifier), enabled ? "1" : "2"])
  }

  // state key -> the identifier name the bridge understands.
  readonly property var flagIdentifiers: ({
    conversationAwareness: "conversation-detect",
    earDetection: "ear-detection",
    oneBudAnc: "one-bud-anc",
    adaptiveVolume: "adaptive-volume",
    sleepDetection: "sleep-detection",
    volumeSwipe: "volume-swipe"
  })

  function toggleFlag(name) {
    var identifier = flagIdentifiers[name]
    if (!identifier) return
    var next = !flag(name)
    holdFlag(name, next)
    setFlag(identifier, next)
  }

  function toggleConversationAwareness() { toggleFlag("conversationAwareness") }
  function toggleEarDetection() { toggleFlag("earDetection") }

  function setAncStrength(value) {
    if (!connected) return
    var clamped = Math.max(0, Math.min(100, Math.round(value)))
    holdFlag("ancStrength", clamped)
    run(["set", "auto-anc-strength", String(clamped)])
  }

  // ---- starting the daemon -------------------------------------------------

  // Omarchy deliberately never runs anything from a plugin at install time, so
  // "enable the service" would otherwise be a manual step in a README that
  // people reasonably skip. The unit is a *user* unit, so starting it needs no
  // privileges and the plugin can simply do it.
  //
  // If the unit does not exist the package is not installed, which is not
  // something this can fix — so it stops asking and says so instead.
  property bool daemonMissing: false
  property int startAttempts: 0

  Process {
    id: startProc
    onExited: function(code) {
      // A missing unit exits non-zero. Distinguishing that from a unit that
      // exists but failed to start matters: one is a install-the-package
      // problem for the user, the other is worth retrying.
      if (code !== 0) {
        root.daemonMissing = true
        console.warn("airpods: could not start airpods-tui (exit " + code
                     + "); is the package installed?")
      }
    }
  }

  Timer {
    id: startTimer
    interval: 15000
    repeat: false
    running: !root.daemonRunning && !root.daemonMissing && root.startAttempts < 2
    onTriggered: {
      if (root.daemonRunning) return
      root.startAttempts += 1
      startProc.command = ["systemctl", "--user", "start", "airpods-tui"]
      startProc.running = true
    }
  }

  // ---- daemon watchdog -----------------------------------------------------

  // The failure this exists for: on first enable the daemon started before
  // BlueZ was ready, so it never opened the AACP session. BlueZ showed the
  // AirPods connected, the daemon showed nothing, and only a manual
  // `systemctl --user restart airpods-tui` fixed it. That is a race a fresh
  // boot can lose too, and it looks exactly like a broken plugin.
  //
  // Detect the contradiction — BlueZ has one of our known devices connected
  // while the daemon insists nothing is — and restart the unit. Restarting is
  // safe: it is a user unit, needs no privileges, and reconnecting is the
  // daemon's normal startup path.
  readonly property var knownMacs: state.knownMacs || []

  readonly property bool bluezHasDevice: {
    if (knownMacs.length === 0) return false
    var devices = Bluetooth.devices ? Bluetooth.devices.values : []
    for (var i = 0; i < devices.length; i++) {
      var device = devices[i]
      if (!device || !device.connected) continue
      if (knownMacs.indexOf(String(device.address)) !== -1) return true
    }
    return false
  }

  // Only a sustained contradiction counts. A reconnect legitimately spends a
  // few seconds with BlueZ ahead of the AACP session, and restarting into that
  // window would break the very thing it is meant to repair.
  readonly property bool desynced: daemonRunning && bluezHasDevice && !connected

  property int recoveryAttempts: 0

  Process { id: recoveryProc }

  Timer {
    id: desyncTimer
    interval: 30000
    repeat: false
    running: root.desynced && root.recoveryAttempts < 3
    onTriggered: {
      if (!root.desynced) return
      root.recoveryAttempts += 1
      console.warn("airpods: BlueZ has the device but the daemon does not; restarting airpods-tui"
                   + " (attempt " + root.recoveryAttempts + ")")
      recoveryProc.command = ["systemctl", "--user", "restart", "airpods-tui"]
      recoveryProc.running = true
    }
  }

  // ---- low battery ---------------------------------------------------------

  // A tinted bar label only helps someone already looking at the bar. The
  // point of failure is a bud dying mid-call, so this interrupts once per
  // threshold and then stays quiet until the buds are charged again.
  readonly property bool notifyLowBattery: setting("notifyLowBattery", true)
  readonly property int warnAt: Math.max(0, setting("lowBatteryThreshold", 20))
  readonly property int criticalAt: Math.max(0, setting("criticalBatteryThreshold", 10))

  // Which thresholds have already fired for the current discharge, so a bud
  // hovering on the boundary does not notify on every battery report.
  property var firedThresholds: ({})

  Process { id: notifyProc }

  function notify(urgency, summary, body) {
    notifyProc.command = ["notify-send", "-a", "AirPods", "-u", urgency,
                          "-i", "audio-headphones", summary, body]
    notifyProc.running = true
  }

  function checkBattery() {
    if (!notifyLowBattery || !connected) return
    var buds = [
      { key: "left", label: "Left bud" },
      { key: "right", label: "Right bud" },
      { key: "headphone", label: "Headphones" }
    ]
    var fired = {}
    for (var key in firedThresholds) fired[key] = firedThresholds[key]
    var changed = false

    for (var i = 0; i < buds.length; i++) {
      var level = batteryOf(buds[i].key)
      // The case is deliberately excluded: it is not what runs out mid-call,
      // and it only reports at all while the buds sit in it.
      if (level < 0) continue

      // Charging clears the latch, so the next discharge notifies again.
      if (chargingOf(buds[i].key) || (warnAt > 0 && level > warnAt)) {
        if (fired[buds[i].key] !== undefined) { delete fired[buds[i].key]; changed = true }
        continue
      }

      var already = fired[buds[i].key] || 0
      if (criticalAt > 0 && level <= criticalAt && already < 2) {
        notify("critical", buds[i].label + " at " + level + "%",
               deviceName + " is about to die.")
        fired[buds[i].key] = 2
        changed = true
      } else if (warnAt > 0 && level <= warnAt && already < 1) {
        notify("normal", buds[i].label + " at " + level + "%", deviceName)
        fired[buds[i].key] = 1
        changed = true
      }
    }

    if (changed) firedThresholds = fired
  }

  onBatteryChanged: checkBattery()

  function rename(name) {
    var trimmed = String(name || "").trim()
    if (trimmed === "" || !connected) return
    run(["rename", trimmed])
  }
}
