import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "PomoModel.js" as Pomo

// Bar face of the pomodoro. The engine lives in Service.qml
// (one per shell); this widget is one per monitor and only renders + relays.
//
//   left click    popup with the timer, controls, presets and toggles
//   right click   start / pause / resume
//   middle click  skip the current block
//   scroll        +/- 1 minute on the running block
BarWidget {
  id: root
  moduleName: "techywilbur.pomodoro"

  readonly property var pomo: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("techywilbur.pomodoro") : null
  readonly property bool ready: pomo !== null && pomo !== undefined
  readonly property string phase: ready ? pomo.phase : "idle"
  readonly property bool active: ready ? pomo.active : false
  readonly property bool running: ready ? pomo.running : false
  readonly property bool paused: ready ? pomo.paused : false
  readonly property string clock: ready ? pomo.clock : "00:00"
  readonly property string icon: ready ? pomo.icon : "󰔛"
  readonly property string phaseLabel: ready ? pomo.phaseLabel : "Pomodoro"
  readonly property real progress: ready ? pomo.progress : 0
  readonly property var cfg: ready ? pomo.config : Pomo.config(null)
  readonly property var dots: ready ? pomo.dots : []
  readonly property int todayCount: ready ? pomo.todayCount : 0
  readonly property int todayMinutes: ready ? pomo.todayMinutes : 0

  readonly property color accent: Color.accent
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property bool focusRunning: phase === "focus" && running
  readonly property real selectedFocusMinutes: {
    if (phase === "focus" && ready) return pomo.plannedMs / 60000
    if (phase === "idle" || phase === "ready") return cfg.focus
    return -1
  }

  readonly property string barText: {
    if (!ready) return "󰔛"
    if (phase === "idle") return "󰔛"
    if (phase === "ready") return icon + "  " + (pomo.readyNext === "break" ? "break?" : "focus?")
    return icon + "  " + clock
  }

  readonly property string tooltip: {
    if (!ready) return "Pomodoro"
    if (phase === "idle") return "Pomodoro — click for options, right-click to start " + cfg.focus + " min focus"
    if (phase === "ready") return phaseLabel + " — right-click to continue"
    return phaseLabel + (paused ? " (paused)" : "") + " · " + clock + " left · " + pomo.cyclesDone + "/" + cfg.longEvery + " this set"
  }

  property bool popupOpen: false

  // Shape contract the shell expects from a bar widget with a panel.
  readonly property bool opened: popupOpen
  function open() { popupOpen = true }
  function close() { popupOpen = false }
  function togglePanel() { popupOpen = !popupOpen }

  function currentSettingsEntry() {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    return entry
  }

  function syncSettingsToService() {
    if (root.ready && typeof root.pomo.updateConfigEntry === "function")
      root.pomo.updateConfigEntry(root.currentSettingsEntry())
  }

  onSettingsChanged: syncSettingsToService()
  onPomoChanged: syncSettingsToService()
  Component.onCompleted: Qt.callLater(syncSettingsToService)

  function writeSetting(name, value) {
    var entry = root.currentSettingsEntry()
    entry[name] = value
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    root.syncSettingsToService()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "techywilbur.pomodoro"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? root.icon : root.barText
    foreground: root.focusRunning ? root.accent : (root.bar ? root.bar.barForeground : Color.foreground)
    dimmed: root.paused
    useActiveColor: false
    tooltipText: root.tooltip
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(b) {
      if (!root.ready) return
      if (b === Qt.RightButton) root.pomo.toggle()
      else if (b === Qt.MiddleButton) root.pomo.skip()
      else root.togglePanel()
    }
    onWheelMoved: function(delta) {
      if (!root.ready || !root.active) return
      root.pomo.extend(delta > 0 ? 1 : -1)
    }
  }

  // Thin progress hairline along the bottom edge of the slot while a block runs.
  Rectangle {
    visible: root.active && !root.vertical
    anchors.left: parent.left
    anchors.leftMargin: Style.space(6)
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(3)
    height: Math.max(1, Style.space(2))
    width: Math.max(0, (parent.width - Style.space(12)) * root.progress)
    radius: height / 2
    color: root.phase === "focus" ? root.accent : root.fg
    opacity: root.paused ? 0.35 : 0.8
    Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(312))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Flickable {
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      flickableDirection: Flickable.VerticalFlick
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        // ---- header: phase + session dots
        Item {
          width: parent.width
          height: headerLabel.implicitHeight

          Text {
            id: headerLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.phaseLabel.toUpperCase()
            color: root.phase === "focus" ? root.accent : root.fg
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 2
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(5)
            Repeater {
              model: root.dots
              Rectangle {
                required property string modelData
                width: Style.space(8)
                height: width
                radius: width / 2
                color: modelData === "done" ? root.accent
                     : modelData === "current" ? Util.alpha(root.accent, 0.35)
                     : Util.alpha(root.fg, 0.14)
                border.width: modelData === "current" ? 1 : 0
                border.color: root.accent
              }
            }
          }
        }

        // ---- the clock
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.phase === "idle" ? Pomo.mmss(root.cfg.focus * 60000)
              : root.phase === "ready" ? "--:--"
              : root.clock
          color: root.paused ? Util.alpha(root.fg, 0.55) : root.fg
          font.family: root.bar.fontFamily
          font.pixelSize: Math.round(Style.font.displayLarge * 1.7)
          font.bold: true
        }

        Rectangle {
          width: parent.width
          height: Math.max(2, Style.space(3))
          radius: height / 2
          color: Util.alpha(root.fg, 0.12)
          Rectangle {
            height: parent.height
            radius: parent.radius
            width: parent.width * (root.active ? root.progress : (root.phase === "ready" ? 1 : 0))
            color: root.phase === "focus" ? root.accent : root.fg
            Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
          }
        }

        // ---- transport
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(6)

          Button {
            iconText: root.running ? "󰏤" : "󰐊"
            text: root.phase === "idle" ? "Start" : root.phase === "ready" ? "Continue" : root.running ? "Pause" : "Resume"
            foreground: root.fg
            accent: root.accent
            bordered: true
            selected: root.running
            onClicked: if (root.ready) root.pomo.toggle()
          }
          Button {
            iconText: "󰒭"
            tooltipText: "Skip this block"
            foreground: root.fg
            accent: root.accent
            bordered: true
            enabled: root.active || root.phase === "ready"
            opacity: enabled ? 1 : 0.4
            onClicked: if (root.ready) root.pomo.skip()
          }
          Button {
            text: "+5"
            tooltipText: "Add five minutes"
            foreground: root.fg
            accent: root.accent
            bordered: true
            enabled: root.active
            opacity: enabled ? 1 : 0.4
            onClicked: if (root.ready) root.pomo.extend(5)
          }
          Button {
            iconText: "󰓛"
            tooltipText: "Stop and reset the set"
            foreground: root.fg
            accent: root.accent
            bordered: true
            enabled: root.phase !== "idle"
            opacity: enabled ? 1 : 0.4
            onClicked: if (root.ready) root.pomo.stop()
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ---- quick starts
        PanelSectionHeader { text: "Focus"; foreground: root.fg; fontFamily: root.bar.fontFamily }

        Flow {
          objectName: "focusPresets"
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: root.cfg.presets
            Button {
              required property var modelData
              text: modelData + " min"
              foreground: root.fg
              accent: root.accent
              bordered: true
              selected: Number(modelData) === root.selectedFocusMinutes
              tooltipText: "Start a " + modelData + " min focus block (right-click sets the default)"
              onClicked: if (root.ready) root.pomo.startFocus(Number(modelData))
              onRightClicked: root.writeSetting("focus", Number(modelData))
            }
          }
        }

        PanelSectionHeader { text: "Break"; foreground: root.fg; fontFamily: root.bar.fontFamily }

        Flow {
          width: parent.width
          spacing: Style.space(6)
          Button {
            iconText: "󰅶"
            text: "Short · " + root.cfg.shortBreak + " min"
            foreground: root.fg
            accent: root.accent
            bordered: true
            selected: root.phase === "short"
            onClicked: if (root.ready) root.pomo.startBreak("short", 0)
          }
          Button {
            iconText: "󰅶"
            text: "Long · " + root.cfg.longBreak + " min"
            foreground: root.fg
            accent: root.accent
            bordered: true
            selected: root.phase === "long"
            onClicked: if (root.ready) root.pomo.startBreak("long", 0)
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ---- toggles (persisted inline on this widget's shell.json entry)
        Toggle {
          width: parent.width
          label: "Silence notifications"
          checked: root.cfg.dnd
          foreground: root.fg
          accent: root.accent
          fontFamily: root.bar.fontFamily
          onClicked: root.writeSetting("dnd", !root.cfg.dnd)
        }
        Toggle {
          width: parent.width
          label: "Full-screen break"
          checked: root.cfg.overlay
          foreground: root.fg
          accent: root.accent
          fontFamily: root.bar.fontFamily
          onClicked: root.writeSetting("overlay", !root.cfg.overlay)
        }
        Toggle {
          width: parent.width
          label: "End-of-block chime"
          checked: root.cfg.sound
          foreground: root.fg
          accent: root.accent
          fontFamily: root.bar.fontFamily
          onClicked: root.writeSetting("sound", !root.cfg.sound)
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        Text {
          width: parent.width
          text: "Today · " + root.todayCount + (root.todayCount === 1 ? " session · " : " sessions · ") + root.todayMinutes + " min focused"
          color: Util.alpha(root.fg, 0.6)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
