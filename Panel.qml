import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// AirPods in the bar: battery at a glance, noise control one click away.
//
// All device state arrives through the service, which owns the daemon socket.
// This file only renders it and sends intents back — no socket, no timer, no
// per-monitor duplication.
Panel {
  id: root
  moduleName: "io.github.sotoaugusto.airpods"
  ipcTarget: "io.github.sotoaugusto.airpods"
  manageIpc: false

  readonly property var service: bar?.shell?.serviceFor("io.github.sotoaugusto.airpods")

  // The service has no settings of its own — the inline shell.json entry is
  // attached to the widget, and every panel instance carries the same one, so
  // whichever loads first hands them over. Without this the service silently
  // runs on defaults: the low-battery thresholds and the AAC pinning were both
  // reading fallbacks rather than anything the user had configured.
  onServiceChanged: pushSettings()
  onSettingsChanged: pushSettings()
  Component.onCompleted: pushSettings()

  function pushSettings() {
    if (service && "settings" in service) service.settings = settings
  }

  readonly property bool connected: service ? service.connected : false
  readonly property bool daemonRunning: service ? service.daemonRunning : false
  readonly property string deviceName: service ? service.deviceName : "AirPods"
  readonly property string mode: service ? service.mode : ""
  readonly property bool allowOff: service ? service.allowOff : true
  readonly property int lowestBattery: service ? service.lowestBudBattery : -1

  readonly property int lowThreshold: setting("lowBatteryThreshold", 20)
  readonly property bool batteryLow: lowThreshold > 0 && lowestBattery >= 0 && lowestBattery <= lowThreshold

  // A widget that vanishes is the honest default: AirPods are absent most of
  // the day, and a permanently dimmed glyph is just noise in the bar.
  visible: connected || !setting("hideWhenDisconnected", true)

  readonly property color dim: Qt.darker(barForeground, 1.45)

  // Panel is a plain Item rather than a BarWidget, so the orientation the bar
  // is running in has to be read off the bar directly.
  readonly property bool vertical: bar ? bar.vertical : false

  // A vertical bar is a narrow column of icon-sized cells. "󰋋  93%" laid out
  // sideways would either overflow the column or force the whole bar wider,
  // so the label is stacked under the glyph as its own cell instead.
  readonly property var verticalLines: {
    var lines = [barGlyph]
    var label = barLabelText
    if (label !== "" && label !== glyph) lines.push(label.replace("%", ""))
    return lines
  }

  // ---- identity ------------------------------------------------------------

  // Ear detection is the most informative thing the glyph can carry: in-ear
  // means the buds are actually doing something.
  // Inside the panel there is no competition, so the hero keeps the ear-state
  // headphones — which is where the in-ear indicator now lives.
  readonly property string identityGlyph: connected && service && service.inEar ? "󰋎" : "󰋋"

  // The bar is a different problem. omarchy.audio occupies the same section
  // using the identical headphones glyph, so a second one is a collision
  // rather than an identity. And the widget only exists while AirPods are
  // connected, so the slot spent saying "AirPods are here" says nothing you
  // cannot already see. It carries the active mode instead, falling back to a
  // boxed headphone for the few seconds after a reconnect before the mode
  // arrives.
  readonly property string barGlyph: connected && modeGlyph !== "" ? modeGlyph : "󰋌"

  // Semantics over volume metaphors. A crossed-out speaker says "muted",
  // which is the opposite of what ANC does, and the old Transparency glyph was
  // the same headphones mark this widget uses as its own identity — so with a
  // "Noise mode" bar label you got the icon twice.
  //   circle-slash  no processing
  //   shield        blocks the outside
  //   person+waves  hear the people around you
  //   sync arrows   continuously adjusting
  readonly property string modeGlyph: {
    if (mode === "off") return "󰜺"
    if (mode === "anc") return "󰒃"
    if (mode === "transparency") return "󰗋"
    if (mode === "adaptive") return "󰓦"
    return ""
  }

  readonly property string modeLabel: {
    if (mode === "anc") return "Noise Cancellation"
    if (mode === "transparency") return "Transparency"
    if (mode === "adaptive") return "Adaptive"
    if (mode === "off") return "Off"
    return ""
  }

  // Where the buds physically are, which explains an awful lot of otherwise
  // confusing behaviour — the AirPods refuse listening-mode changes in the
  // case, so saying so up front saves the user a puzzled click.
  readonly property string placementLabel: {
    if (!service || !connected) return ""
    var left = service.ear.left, right = service.ear.right
    if (left === "in_ear" && right === "in_ear") return "Both in ear"
    if (left === "in_ear" || right === "in_ear") return "One in ear"
    if (left === "in_case" || right === "in_case") return "In case"
    if (left === "out_of_ear" || right === "out_of_ear") return "Out of ear"
    return ""
  }

  readonly property bool inCase: service && (service.ear.left === "in_case" || service.ear.right === "in_case")

  // Measured on AirPods Pro 0x2024: listening-mode writes are accepted by the
  // daemon and then ignored by the buds unless one is actually in an ear —
  // in the case *and* merely out of the ear both refuse. Saying so beats
  // letting the click quietly do nothing.
  readonly property bool modeAvailable: service ? service.inEar : false

  readonly property string modeBlockedReason: {
    if (modeAvailable || !connected) return ""
    return inCase ? "unavailable in case" : "unavailable — not in ear"
  }

  function batteryLevel(component) {
    return service ? service.batteryOf(component) : -1
  }

  function batteryCharging(component) {
    return service ? service.chargingOf(component) : false
  }

  // Per-bud placement. "One in ear" in the hero is true but unhelpful — the
  // useful question is which one, and the battery row for that bud is where
  // the eye already is.
  function earStateOf(component) {
    if (!service || (component !== "left" && component !== "right")) return ""
    return service.ear[component] || ""
  }

  function earGlyphOf(component) {
    var state = earStateOf(component)
    if (state === "in_ear") return "󰋎"
    if (state === "in_case") return "󰂺"
    if (state === "out_of_ear") return "󰋋"
    return ""
  }

  function earTipOf(component) {
    var state = earStateOf(component)
    if (state === "in_ear") return "In ear"
    if (state === "in_case") return "In case"
    if (state === "out_of_ear") return "Out of ear"
    return ""
  }

  // ---- bar label -----------------------------------------------------------

  readonly property string barLabelText: {
    if (!connected) return ""
    var choice = setting("barLabel", "Lowest battery")
    if (choice === "Icon only") return ""
    // The bar icon is already the mode glyph, so this option has nothing
    // left to add — repeating it would print the same mark twice.
    if (choice === "Noise mode") return ""
    if (choice === "Both buds") {
      var left = batteryLevel("left"), right = batteryLevel("right")
      if (left < 0 && right < 0) return ""
      return (left < 0 ? "—" : left) + "/" + (right < 0 ? "—" : right)
    }
    return lowestBattery >= 0 ? lowestBattery + "%" : ""
  }

  // Hovering the bar should answer the question without opening anything:
  // what is connected, how much charge, which mode, where the buds are.
  readonly property string barTooltip: {
    if (!daemonRunning) return "AirPods — daemon not running"
    if (!connected) return "AirPods — not connected"
    var parts = [deviceName]
    var left = batteryLevel("left"), right = batteryLevel("right"), kase = batteryLevel("case")
    var charge = []
    if (left >= 0) charge.push("L " + left + "%" + (batteryCharging("left") ? "󰂄" : ""))
    if (right >= 0) charge.push("R " + right + "%" + (batteryCharging("right") ? "󰂄" : ""))
    if (kase >= 0) charge.push("Case " + kase + "%" + (batteryCharging("case") ? "󰂄" : ""))
    if (charge.length > 0) parts.push(charge.join("  "))
    if (modeLabel !== "") parts.push(modeLabel)
    if (placementLabel !== "") parts.push(placementLabel)
    return parts.join("\n")
  }

  // ---- modes ---------------------------------------------------------------

  // "Off" is offered unless the AirPods explicitly disallow it. Gating it on a
  // positive AllowOffOption report was tried and was wrong: AirPods Pro
  // (0x2024) never send that identifier yet accept listening-mode Off, so
  // requiring the report hid a mode that works.
  //
  // Icon-only, with the full name in the tooltip and in the hero line. Four
  // spelled-out labels do not fit the panel width, and truncating
  // "Transparency" to fit reads worse than a glyph that has a tooltip.
  readonly property var modeOptions: {
    var options = []
    if (allowOff) options.push({ value: "off", label: "", icon: "󰜺", tooltip: "Off" })
    options.push({ value: "anc", label: "", icon: "󰒃", tooltip: "Noise Cancellation" })
    options.push({ value: "transparency", label: "", icon: "󰗋", tooltip: "Transparency" })
    options.push({ value: "adaptive", label: "", icon: "󰓦", tooltip: "Adaptive" })
    return options
  }

  function setMode(value) {
    if (service) service.setMode(value)
  }

  // Right-clicking the bar cycles, which is the gesture that does not need the
  // panel open. It walks the same list the panel shows, so the two never
  // disagree about which modes exist.
  function cycleMode() {
    if (!connected || !service) return
    var options = modeOptions
    var index = -1
    for (var i = 0; i < options.length; i++) if (options[i].value === mode) index = i
    setMode(options[(index + 1) % options.length].value)
  }

  // The AirPods' own press-and-hold flips between Noise Cancellation and
  // Transparency, and every other bar widget uses right-click for its single
  // most common action rather than a long cycle. One click, always the same
  // destination. Off and Adaptive stay available on the panel, the number
  // keys, and middle-click.
  function toggleAncTransparency() {
    if (!connected || !service) return
    setMode(mode === "anc" ? "transparency" : "anc")
  }

  function selectModeByNumber(n) {
    var options = modeOptions
    if (n >= 1 && n <= options.length) setMode(options[n - 1].value)
  }

  // ---- keyboard legend -----------------------------------------------------

  // Discoverability without clutter: the shortcuts exist whether or not the
  // list is open, and the list stays folded until asked for.
  property bool legendOpen: false

  readonly property var legendRows: {
    var rows = []
    var options = modeOptions
    for (var i = 0; i < options.length; i++)
      rows.push({ key: String(i + 1), action: options[i].tooltip })
    rows.push({ key: "c", action: "Cycle noise mode" })
    if (service && service.reportsConversationAwareness)
      rows.push({ key: "a", action: "Conversation awareness" })
    if (service && service.reportsEarDetection)
      rows.push({ key: "e", action: "Ear detection" })
    if (service && service.hasExtraSettings)
      rows.push({ key: "s", action: "Show / hide settings" })
    rows.push({ key: "k", action: "Show / hide this list" })
    rows.push({ key: "Tab", action: "Next panel" })
    rows.push({ key: "Esc", action: "Close" })
    return rows
  }

  // Global binds live in ~/.config/hypr/bindings.lua and work with the panel
  // shut, so they are listed apart from the keys that only apply in here.
  readonly property var mouseRows: [
    { key: "Click", action: "Open this panel" },
    { key: "Right", action: "Noise Cancellation ⇄ Transparency" },
    { key: "Middle", action: "Cycle all modes" }
  ]

  readonly property var globalRows: setting("showGlobalShortcuts", true)
    ? [
        { key: "Super Alt A", action: "Open this panel" },
        { key: "Super Alt N", action: "Cycle noise mode" }
      ]
    : []

  function toggleLegend() { legendOpen = !legendOpen }

  // ---- extra settings ------------------------------------------------------

  // The AirPods report far more config than most people touch daily. Keeping
  // it folded means the common panel stays four rows tall, while the long tail
  // is one click away rather than absent.
  property bool settingsOpen: false

  function toggleSettings() { settingsOpen = !settingsOpen }

  // Built here rather than in the delegate so the rows carry plain values —
  // a delegate that reaches back into the service for each field re-evaluates
  // on every unrelated state write.
  readonly property var extraToggles: {
    var s = service
    if (!s) return []
    return [
      { key: "oneBudAnc", label: "ANC with one bud", supported: s.reportsOneBudAnc, checked: s.oneBudAnc },
      { key: "adaptiveVolume", label: "Adaptive volume", supported: s.reportsAdaptiveVolume, checked: s.adaptiveVolume },
      { key: "volumeSwipe", label: "Volume swipe on stem", supported: s.reportsVolumeSwipe, checked: s.volumeSwipe },
      { key: "sleepDetection", label: "Sleep detection", supported: s.reportsSleepDetection, checked: s.sleepDetection }
    ]
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (!opened) { legendOpen = false; settingsOpen = false }

  IpcHandler {
    target: "io.github.sotoaugusto.airpods"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function cycleMode(): void { root.cycleMode() }
    function toggleQuiet(): void { root.toggleAncTransparency() }
    function setMode(mode: string): void { root.setMode(mode) }
    function shortcuts(): void { root.open(); root.legendOpen = true }
    function settings(): void { root.open(); root.settingsOpen = true }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical
      ? ""
      : (root.barLabelText === "" ? root.barGlyph : root.barGlyph + "  " + root.barLabelText)
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    tooltipText: root.barTooltip
    foreground: root.batteryLow ? Color.urgent : (root.bar ? root.bar.barForeground : Color.foreground)
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleAncTransparency()
      else if (b === Qt.MiddleButton) root.cycleMode()
      else root.toggle()
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 2 ? button.fontSize * 0.85 : button.fontSize
          color: button.foreground
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key >= "1" && key <= "9") root.selectModeByNumber(parseInt(key, 10))
        else if (key === "c") root.cycleMode()
        else if (key === "a" && root.service) root.service.toggleConversationAwareness()
        else if (key === "e" && root.service) root.service.toggleEarDetection()
        else if (key === "s") root.toggleSettings()
        else if (key === "k" || key === "?") root.toggleLegend()
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(14)

        // ---------- Hero: device, charge, mode ----------
        PanelHero {
          width: parent.width
          foreground: root.barForeground
          fontFamily: Style.font.family
          title: root.deviceName
          // No `detail` pill. It renders as a bordered lozenge immediately
          // left of the gear and keyboard buttons, which put three
          // similarly-weighted rounded shapes in the top-right corner at
          // uneven spacing. The charge leads the meta line instead, so the
          // header is title-left / controls-right and the corner is even.
          // Placement is deliberately absent: the per-bud markers in the
          // battery rows say which bud is where, which is strictly more than
          // "BOTH IN EAR" said, and adding it back overflows the line into an
          // ellipsis.
          meta: root.connected
            ? [root.lowestBattery >= 0 ? root.lowestBattery + "%" : "",
               root.modeLabel].filter(s => s !== "").join(" · ")
            : (root.daemonRunning ? "Not connected" : "Daemon not running")

          iconComponent: Text {
            text: root.identityGlyph
            color: root.batteryLow ? Color.urgent : root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.display
          }

          // The legend lives behind one unobtrusive control rather than a
          // permanent block of grey text. A keyboard glyph names what it
          // opens; a bare "?" would only promise help in general.
          trailingControl: Row {
            spacing: Style.space(4)

            PanelActionButton {
              iconText: "󰒓"
              visible: root.service ? root.service.hasExtraSettings : false
              tooltipText: root.settingsOpen ? "Hide settings" : "More settings"
              foreground: root.settingsOpen ? Color.accent : root.dim
              hoverColor: root.barForeground
              fontFamily: Style.font.family
              onClicked: root.toggleSettings()
            }

            PanelActionButton {
              iconText: "󰌌"
              tooltipText: root.legendOpen ? "Hide keyboard shortcuts" : "Keyboard shortcuts"
              foreground: root.legendOpen ? Color.accent : root.dim
              hoverColor: root.barForeground
              fontFamily: Style.font.family
              onClicked: root.toggleLegend()
            }
          }
        }


        // ---------- Battery ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.connected

          Item {
            width: parent.width
            height: batteryHeader.implicitHeight

            PanelSectionHeader {
              id: batteryHeader
              anchors.left: parent.left
              text: "Battery"
              foreground: root.barForeground
            }

            // Only appears once the drain samples support it, which takes
            // about ten minutes of wearing. An estimate that shows up
            // immediately would be made of quantisation noise.
            Text {
              anchors.right: parent.right
              anchors.verticalCenter: batteryHeader.verticalCenter
              text: root.service ? root.service.timeLeftLabel : ""
              visible: text !== ""
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Repeater {
            model: [
              { key: "left", label: "Left" },
              { key: "right", label: "Right" },
              { key: "headphone", label: "Headphones" },
              { key: "case", label: "Case" }
            ]

            Item {
              id: batteryRow
              required property var modelData

              readonly property int level: root.batteryLevel(modelData.key)
              readonly property bool charging: root.batteryCharging(modelData.key)
              readonly property bool low: root.lowThreshold > 0 && level >= 0 && level <= root.lowThreshold
              readonly property bool unavailable: level < 0

              width: column.width
              height: visible ? Style.space(22) : 0
              // A component the device has never mentioned stays absent — an
              // AirPods Max has no case, and a blank row for it is a bug
              // report waiting to happen. One it *has* mentioned but cannot
              // currently read stays visible and says so, because a row that
              // disappears reads as a fault rather than as "not right now".
              visible: root.service ? root.service.batteryKnown(modelData.key) : false

              Text {
                id: batteryLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(64)
                text: batteryRow.modelData.label
                color: root.dim
                opacity: batteryRow.unavailable ? 0.55 : 1.0
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              // Lit only for the bud actually in an ear, so a glance at the
              // column answers "which one" without reading anything.
              Text {
                id: earMark
                anchors.left: batteryLabel.right
                anchors.leftMargin: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(14)
                text: root.earGlyphOf(batteryRow.modelData.key)
                visible: text !== ""
                color: root.earStateOf(batteryRow.modelData.key) === "in_ear"
                  ? Color.accent
                  : root.dim
                opacity: root.earStateOf(batteryRow.modelData.key) === "in_ear" ? 1.0 : 0.5
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              // A number tells you the level; a bar lets you see three of them
              // at once without reading any of them.
              Rectangle {
                id: track
                anchors.left: earMark.visible ? earMark.right : batteryLabel.right
                anchors.leftMargin: Style.space(4)
                anchors.right: batteryValue.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(7)
                radius: height / 2
                color: Util.alpha(root.barForeground, 0.16)

                Rectangle {
                  visible: !batteryRow.unavailable
                  width: Math.max(parent.height, parent.width * Math.max(0, Math.min(100, batteryRow.level)) / 100)
                  height: parent.height
                  radius: parent.radius
                  color: batteryRow.low
                    ? Color.urgent
                    : (batteryRow.charging ? Color.accent : root.barForeground)

                  Behavior on width {
                    NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                  }
                }
              }

              Text {
                id: batteryValue
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: batteryRow.unavailable
                  ? "—"
                  : batteryRow.level + "%" + (batteryRow.charging ? " 󰂄" : "")
                color: batteryRow.low ? Color.urgent : root.barForeground
                opacity: batteryRow.unavailable ? 0.55 : 1.0
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          // The case reports level 0 / disconnected whenever the buds are
          // not inside it, lid open or shut — it reads its charge through
          // them. Without this line the em dash looks like a failure.
          Text {
            width: parent.width
            visible: root.service && root.service.batteryKnown("case")
              && root.service.batteryOf("case") < 0
            wrapMode: Text.WordWrap
            text: "Reported only while the buds are inside."
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { width: parent.width; visible: root.connected }

        // ---------- Noise control ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.connected

          Item {
            width: parent.width
            height: modeHeader.implicitHeight

            PanelSectionHeader {
              id: modeHeader
              anchors.left: parent.left
              text: "Noise control"
              foreground: root.barForeground
            }

            // Why the buttons are dimmed, stated where the buttons are.
            Text {
              anchors.right: parent.right
              anchors.verticalCenter: modeHeader.verticalCenter
              visible: root.modeBlockedReason !== ""
              text: root.modeBlockedReason
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          ButtonGroup {
            width: parent.width
            options: root.modeOptions
            value: root.mode
            foreground: root.barForeground
            accent: Color.accent
            opacity: root.modeAvailable ? 1.0 : 0.45
            onChanged: function(value) { root.setMode(value) }
          }
        }

        // ---------- Toggles ----------
        PanelSeparator {
          width: parent.width
          visible: root.connected && root.service
            && (root.service.reportsConversationAwareness || root.service.reportsEarDetection)
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          // An empty toggle block is worse than no block: it reads as a section
          // that failed to load rather than one the device has nothing to put
          // in. Only identifiers the AirPods actually report appear here.
          visible: root.connected && root.service
            && (root.service.reportsConversationAwareness || root.service.reportsEarDetection)

          Item {
            width: parent.width
            height: visible ? awarenessSwitch.implicitHeight : 0
            visible: root.service ? root.service.reportsConversationAwareness : false

            Text {
              anchors.left: parent.left
              anchors.right: awarenessSwitch.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: "Conversation awareness"
              elide: Text.ElideRight
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            ToggleSwitch {
              id: awarenessSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.service ? root.service.conversationAwareness : false
              foreground: root.barForeground
              accent: Color.accent
              onToggled: if (root.service) root.service.toggleConversationAwareness()
            }
          }

          Item {
            width: parent.width
            height: visible ? earSwitch.implicitHeight : 0
            visible: root.service ? root.service.reportsEarDetection : false

            Text {
              anchors.left: parent.left
              anchors.right: earSwitch.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: "Ear detection"
              elide: Text.ElideRight
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            ToggleSwitch {
              id: earSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.service ? root.service.earDetection : false
              foreground: root.barForeground
              accent: Color.accent
              onToggled: if (root.service) root.service.toggleEarDetection()
            }
          }
        }


        PanelSeparator { width: parent.width; visible: root.legendOpen }

        // ---------- More settings ----------
        PanelSeparator {
          width: parent.width
          visible: root.settingsOpen && root.connected
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.settingsOpen && root.connected

          Item {
            width: parent.width
            height: settingsHeader.implicitHeight

            PanelSectionHeader {
              id: settingsHeader
              anchors.left: parent.left
              text: "Settings"
              foreground: root.barForeground
            }

            // The device sends its config block once per session and does not
            // always resend it, so these can be drawn from memory. Say so rather
            // than presenting a remembered value as a live reading.
            Text {
              anchors.right: parent.right
              anchors.verticalCenter: settingsHeader.verticalCenter
              visible: root.service ? root.service.stale : false
              text: "remembered"
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // Adaptive ANC strength. Only meaningful in Adaptive mode, so it dims
          // outside it rather than vanishing — hiding it would make the mode feel
          // like it lost a feature.
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.service ? root.service.reportsAncStrength : false
            opacity: root.mode === "adaptive" ? 1.0 : 0.55

            Item {
              width: parent.width
              height: strengthLabel.implicitHeight

              Text {
                id: strengthLabel
                anchors.left: parent.left
                text: "Adaptive strength"
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: strengthLabel.verticalCenter
                text: root.mode === "adaptive"
                  ? (root.service ? root.service.ancStrength : 0) + "%"
                  : "Adaptive mode only"
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: 0
              maximum: 100
              step: 5
              integer: true
              value: root.service ? root.service.ancStrength : 0
              onMoved: function(v) { if (root.service) root.service.setAncStrength(v) }
            }
          }

          Repeater {
            model: root.extraToggles

            Item {
              required property var modelData
              width: parent.width
              height: visible ? extraSwitch.implicitHeight : 0
              visible: modelData.supported

              Text {
                anchors.left: parent.left
                anchors.right: extraSwitch.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: parent.modelData.label
                elide: Text.ElideRight
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              ToggleSwitch {
                id: extraSwitch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: parent.modelData.checked
                foreground: root.barForeground
                accent: Color.accent
                onToggled: if (root.service) root.service.toggleFlag(parent.modelData.key)
              }
            }
          }

          PanelSeparator { width: parent.width }

          // Renaming is a once-ever action, so it lives at the bottom of the
          // folded section rather than costing a row in the everyday panel.
          Column {
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: "Rename"
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            TextField {
              id: renameField
              width: parent.width
              placeholderText: root.deviceName
              foreground: root.barForeground
              accent: Color.accent
              font.family: Style.font.family
              onAccepted: {
                if (root.service) root.service.rename(text)
                text = ""
                focus = false
              }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Enter to apply. The name comes back from the buds, so it may take a reconnect to show."
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

        }

        // ---------- Keyboard legend ----------
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.legendOpen

          PanelSectionHeader {
            width: parent.width
            text: "Shortcuts"
            foreground: root.barForeground
          }

          Repeater {
            model: root.legendRows

            Item {
              required property var modelData
              width: column.width
              height: Style.space(22)

              // A key chip reads as something you press. Plain text in a list
              // reads as prose about pressing something.
              Rectangle {
                id: chip
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(Style.space(22), chipLabel.implicitWidth + Style.space(10))
                height: Style.space(18)
                radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                color: "transparent"
                border.width: 1
                border.color: Util.alpha(root.barForeground, 0.35)

                Text {
                  id: chipLabel
                  anchors.centerIn: parent
                  text: parent.parent.modelData.key
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                anchors.left: chip.right
                anchors.leftMargin: Style.space(10)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: parent.modelData.action
                color: root.dim
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          PanelSeparator { width: parent.width; visible: root.mouseRows.length > 0 }

          PanelSectionHeader {
            width: parent.width
            text: "Mouse"
            foreground: root.barForeground
            visible: root.mouseRows.length > 0
          }

          Repeater {
            model: root.mouseRows

            Item {
              required property var modelData
              width: column.width
              height: Style.space(22)

              // A key chip reads as something you press. Plain text in a list
              // reads as prose about pressing something.
              Rectangle {
                id: chip
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(Style.space(22), chipLabel.implicitWidth + Style.space(10))
                height: Style.space(18)
                radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                color: "transparent"
                border.width: 1
                border.color: Util.alpha(root.barForeground, 0.35)

                Text {
                  id: chipLabel
                  anchors.centerIn: parent
                  text: parent.parent.modelData.key
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                anchors.left: chip.right
                anchors.leftMargin: Style.space(10)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: parent.modelData.action
                color: root.dim
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          PanelSeparator { width: parent.width; visible: root.globalRows.length > 0 }

          PanelSectionHeader {
            width: parent.width
            text: "Anywhere"
            foreground: root.barForeground
            visible: root.globalRows.length > 0
          }

          Repeater {
            model: root.globalRows

            Item {
              required property var modelData
              width: column.width
              height: Style.space(22)

              // A key chip reads as something you press. Plain text in a list
              // reads as prose about pressing something.
              Rectangle {
                id: chip
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(Style.space(22), chipLabel.implicitWidth + Style.space(10))
                height: Style.space(18)
                radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                color: "transparent"
                border.width: 1
                border.color: Util.alpha(root.barForeground, 0.35)

                Text {
                  id: chipLabel
                  anchors.centerIn: parent
                  text: parent.parent.modelData.key
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                anchors.left: chip.right
                anchors.leftMargin: Style.space(10)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: parent.modelData.action
                color: root.dim
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }


        // ---------- Nothing to control ----------
        Text {
          width: parent.width
          visible: !root.connected
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          text: root.daemonRunning
            ? "No AirPods connected. Connect them and the controls appear here."
            : "The airpods-tui daemon is not running.\n\nStart it with:\nsystemctl --user enable --now airpods-tui"
        }

        Text {
          width: parent.width
          visible: root.service ? String(root.service.actionError || "") !== "" : false
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          text: root.service ? root.service.actionError : ""
        }
      }
    }
  }
}
