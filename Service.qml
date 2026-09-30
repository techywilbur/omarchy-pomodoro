import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "PomoModel.js" as Pomo

// Pomodoro engine. One instance lives in the shell for the whole
// session; the bar widget (one per monitor) reads its state and calls into it.
//
// Time is kept as an absolute wall-clock end (`endsAt`) so the countdown
// survives suspend, shell restarts and theme switches: state is persisted to
// ~/.local/state/uni-pomo/state.json on every transition and rehydrated on
// load through the bundled `pomo-state-read` helper (bounded, O_NOFOLLOW,
// fstat-validated, whitelisted). Configuration is read live from this
// plugin's entry in shell.json.
//
// IPC: `omarchy-shell pomodoro <status|start|pause|resume|toggle|stop|skip|
//        focus <min>|shortBreak <min>|longBreak <min>|extend <min>|hideBreak|showBreak>`
Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string pluginId: "techywilbur.pomodoro"
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/uni-pomo"
  readonly property string statePath: stateDir + "/state.json"

  // Resolve the bundled helper relative to this component. Current shells
  // deliberately omit internal source metadata from third-party manifests.
  readonly property string stateReaderPath: decodeURIComponent(String(Qt.resolvedUrl("pomo-state-read")).replace(/^file:\/\//, ""))

  // ---- configuration (inline on the widget's bar entry; hot-reloaded by the shell)
  property var widgetEntry: null
  readonly property var hostEntry: {
    if (!shell) return null
    // Third-party plugins receive a scoped shell facade exposing barConfig.
    // Older shells provide the full shellConfig instead.
    if (shell.barConfig !== undefined)
      return Pomo.findEntry({bar: shell.barConfig}, pluginId)
    return Pomo.findEntry(shell.shellConfig, pluginId)
  }
  readonly property var entry: widgetEntry || hostEntry
  readonly property var config: Pomo.config(entry)

  function updateConfigEntry(value) {
    if (!value || value.id !== pluginId) return
    widgetEntry = JSON.parse(JSON.stringify(value))
  }

  // ---- state
  property string phase: "idle"        // idle | focus | short | long | ready
  property string readyNext: "focus"   // what a "ready" pause is waiting to start: focus | break
  property bool running: false
  property real endsAt: 0              // epoch ms, valid while running
  property real remainingMs: 0
  property real plannedMs: 0
  property int cyclesDone: 0           // focus blocks finished in the current set
  property string day: Pomo.todayKey()
  property int todayCount: 0
  property int todayMinutes: 0
  property bool dndBefore: false
  property bool dndApplied: false
  property bool overlayDismissed: false
  property int tipIndex: 0
  property bool hydrated: false

  readonly property bool active: phase === "focus" || Pomo.isBreak(phase)
  readonly property bool isBreak: Pomo.isBreak(phase)
  readonly property bool paused: active && !running
  readonly property real progress: plannedMs > 0 ? Math.min(1, Math.max(0, 1 - remainingMs / plannedMs)) : 0
  readonly property string clock: Pomo.mmss(remainingMs)
  readonly property string phaseLabel: Pomo.phaseLabel(phase, readyNext)
  readonly property string icon: Pomo.phaseIcon(phase, running)
  readonly property var dots: Pomo.sessionDots(cyclesDone, config.longEvery, phase)
  readonly property string tip: Pomo.tipFor(tipIndex)

  readonly property bool dndWanted: config.dnd && phase === "focus" && running
  readonly property bool overlayVisible: hydrated && config.overlay && !overlayDismissed && (isBreak || phase === "ready")
  readonly property var notificationService: shell && typeof shell.serviceFor === "function" ? shell.serviceFor("omarchy.notifications") : null

  // ------------------------------------------------------------------ engine

  function now() { return Date.now() }

  function tick() {
    if (!running) return
    var left = endsAt - now()
    if (left <= 0) {
      remainingMs = 0
      complete()
      return
    }
    remainingMs = left
  }

  function begin(nextPhase, minutes) {
    phase = nextPhase
    plannedMs = Math.max(1, minutes) * 60000
    remainingMs = plannedMs
    endsAt = now() + plannedMs
    running = true
    overlayDismissed = false
    tipIndex += 1
    persist()
  }

  function startFocus(minutes) {
    var m = Number(minutes) > 0 ? Number(minutes) : config.focus
    begin("focus", m)
  }

  function startBreak(kind, minutes) {
    var k = kind === "long" || kind === "short" ? kind : Pomo.nextBreakKind(cyclesDone, config.longEvery)
    var m = Number(minutes) > 0 ? Number(minutes) : (k === "long" ? config.longBreak : config.shortBreak)
    begin(k, m)
  }

  function enterReady(next) {
    phase = "ready"
    readyNext = next === "break" ? "break" : "focus"
    running = false
    remainingMs = 0
    plannedMs = 0
    endsAt = 0
    overlayDismissed = false
    persist()
  }

  function complete() {
    running = false
    if (phase === "focus") {
      bumpToday(plannedMs)
      cyclesDone += 1
      chime(config.soundFocusEnd)
      var kind = Pomo.nextBreakKind(cyclesDone, config.longEvery)
      var mins = kind === "long" ? config.longBreak : config.shortBreak
      notify("Focus complete", (kind === "long" ? "Long break — " : "Break — ") + mins + " min", "󰅶")
      if (config.autoStartBreak) startBreak(kind, 0)
      else enterReady("break")
    } else if (isBreak) {
      if (phase === "long") cyclesDone = 0
      chime(config.soundBreakEnd)
      notify("Break over", "Next: " + config.focus + " min focus", "󰧐")
      if (config.autoStartFocus) startFocus(0)
      else enterReady("focus")
    } else {
      stop()
    }
  }

  function pause() {
    if (!active || !running) return
    remainingMs = Math.max(0, endsAt - now())
    running = false
    persist()
  }

  function resume() {
    if (!active || running) return
    endsAt = now() + remainingMs
    running = true
    persist()
  }

  function toggle() {
    if (phase === "idle") startFocus(0)
    else if (phase === "ready") { if (readyNext === "break") startBreak("", 0); else startFocus(0) }
    else if (running) pause()
    else resume()
  }

  function start() {
    if (active && running) return
    toggle()
  }

  function skip() {
    if (phase === "focus") {
      running = false
      cyclesDone += 1
      var kind = Pomo.nextBreakKind(cyclesDone, config.longEvery)
      if (config.autoStartBreak) startBreak(kind, 0)
      else enterReady("break")
    } else if (isBreak) {
      if (phase === "long") cyclesDone = 0
      startFocus(0)
    } else if (phase === "ready") {
      toggle()
    }
  }

  function stop() {
    phase = "idle"
    readyNext = "focus"
    running = false
    remainingMs = 0
    plannedMs = 0
    endsAt = 0
    cyclesDone = 0
    overlayDismissed = false
    persist()
  }

  function extend(minutes) {
    var ms = Number(minutes) * 60000
    if (!ms || !active) return
    if (running) {
      endsAt += ms
      remainingMs = Math.max(0, endsAt - now())
    } else {
      remainingMs = Math.max(0, remainingMs + ms)
    }
    plannedMs = Math.max(plannedMs + ms, remainingMs, 60000)
    if (running && remainingMs <= 0) { complete(); return }
    persist()
  }

  function dismissOverlay() { overlayDismissed = true }
  function showOverlay() { overlayDismissed = false }

  function rollDay() {
    var today = Pomo.todayKey()
    if (day !== today) {
      day = today
      todayCount = 0
      todayMinutes = 0
    }
  }

  function bumpToday(ms) {
    rollDay()
    todayCount += 1
    todayMinutes += Math.round(ms / 60000)
  }

  // ------------------------------------------------------------------ effects

  onDndWantedChanged: syncDnd()

  function syncDnd() {
    var svc = notificationService
    if (!svc || typeof svc.setDoNotDisturb !== "function") return
    if (dndWanted && !dndApplied) {
      dndBefore = !!svc.doNotDisturb
      svc.setDoNotDisturb(true)
      dndApplied = true
      persist()
    } else if (!dndWanted && dndApplied) {
      svc.setDoNotDisturb(dndBefore)
      dndApplied = false
      persist()
    }
  }

  // The notifications service may come up after us; keep trying while the
  // wanted and applied DND states disagree.
  Timer {
    interval: 2000
    repeat: true
    running: root.hydrated && root.dndWanted !== root.dndApplied
    onTriggered: root.syncDnd()
  }

  function chime(path) {
    if (!config.sound || !path) return
    Quickshell.execDetached(["bash", "-c", 'pw-play --volume=0.9 "$1" 2>/dev/null || paplay "$1"', "_", path])
  }

  function notify(title, body, glyph) {
    if (!config.notify) return
    Quickshell.execDetached([omarchyPath + "/bin/omarchy-notification-send", "--app-name", "uni-pomo", "-g", glyph, "-u", "normal", title, body])
  }

  // ------------------------------------------------------------------ persistence

  function statusJson() {
    return JSON.stringify({
      phase: phase, label: phaseLabel, readyNext: readyNext,
      running: running, paused: paused,
      remaining: clock, remainingMs: Math.round(remainingMs), plannedMs: Math.round(plannedMs),
      progress: Math.round(progress * 1000) / 1000,
      cyclesDone: cyclesDone, longEvery: config.longEvery,
      todayCount: todayCount, todayMinutes: todayMinutes,
      dnd: dndApplied, breakScreen: overlayVisible,
      config: config
    })
  }

  function persist() {
    if (!hydrated) return
    stateFile.setText(JSON.stringify({
      version: 1, phase: phase, readyNext: readyNext, running: running,
      endsAt: endsAt, remainingMs: remainingMs, plannedMs: plannedMs,
      cyclesDone: cyclesDone, day: day, todayCount: todayCount, todayMinutes: todayMinutes,
      dndBefore: dndBefore, dndApplied: dndApplied, tipIndex: tipIndex
    }, null, 2) + "\n")
  }

  function hydrate(raw) {
    if (hydrated) return
    var s = Pomo.parseState(raw)
    hydrated = true
    if (!s) { rollDay(); return }

    day = String(s.day || day)
    todayCount = Number(s.todayCount || 0)
    todayMinutes = Number(s.todayMinutes || 0)
    rollDay()
    cyclesDone = Number(s.cyclesDone || 0)
    tipIndex = Number(s.tipIndex || 0)
    dndBefore = !!s.dndBefore
    dndApplied = !!s.dndApplied

    var p = String(s.phase || "idle")
    if (p === "focus" || p === "short" || p === "long") {
      plannedMs = Number(s.plannedMs || 0)
      if (s.running) {
        endsAt = Number(s.endsAt || 0)
        var left = endsAt - now()
        if (left < -config.staleAfter * 60000) {
          // Came back long after the block ended (reboot, overnight): drop it.
          phase = "idle"
          cyclesDone = 0
        } else {
          phase = p
          remainingMs = Math.max(0, left)
          running = true // an overdue block completes on the first tick
        }
      } else {
        phase = p
        remainingMs = Number(s.remainingMs || 0)
        running = false
      }
    } else if (p === "ready") {
      phase = "ready"
      readyNext = s.readyNext === "break" ? "break" : "focus"
    } else {
      phase = "idle"
    }
    syncDnd()
    persist()
  }

  // Write-only. The shell never reads the raw state path itself: `preload`
  // is off so this FileView only ever writes, and it writes atomically
  // (temp file + rename), so a symlink planted at the path is replaced, not
  // followed.
  FileView {
    id: stateFile
    path: root.statePath
    preload: false
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  // Reading goes through the bundled `pomo-state-read` helper instead of a
  // FileView on the predictable path: it opens the directory and the file
  // with O_NOFOLLOW (the file also O_NONBLOCK), fstat()s the already-open
  // descriptor (must be a regular file owned by us, at most 16 KiB), caps the
  // read, and prints only a whitelisted, range-checked object. A planted FIFO,
  // symlink or oversized file therefore cannot block or bloat the shell at
  // startup; the engine just starts fresh.
  Process {
    id: stateReader
    command: ["python3", root.stateReaderPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.hydrate(text)
    }
  }

  // If the helper could not run at all (no python, missing file), still
  // start the engine rather than sitting unhydrated forever.
  Timer {
    id: hydrateFallback
    interval: 5000
    onTriggered: root.hydrate("")
  }

  Component.onCompleted: {
    Quickshell.execDetached(["mkdir", "-p", root.stateDir])
    hydrateFallback.start()
    Qt.callLater(function() {
      if (root.stateReaderPath) stateReader.running = true
      else root.hydrate("")
    })
  }

  Timer {
    interval: 500
    repeat: true
    running: root.running
    triggeredOnStart: true
    onTriggered: root.tick()
  }

  Timer {
    interval: 20000
    repeat: true
    running: root.overlayVisible
    onTriggered: root.tipIndex += 1
  }

  IpcHandler {
    target: "pomodoro"

    function status(): string { return root.statusJson() }
    function start(): string { root.start(); return root.statusJson() }
    function pause(): string { root.pause(); return root.statusJson() }
    function resume(): string { root.resume(); return root.statusJson() }
    function toggle(): string { root.toggle(); return root.statusJson() }
    function stop(): string { root.stop(); return root.statusJson() }
    function skip(): string { root.skip(); return root.statusJson() }
    function focus(minutes: string): string { root.startFocus(Number(minutes)); return root.statusJson() }
    function shortBreak(minutes: string): string { root.startBreak("short", Number(minutes)); return root.statusJson() }
    function longBreak(minutes: string): string { root.startBreak("long", Number(minutes)); return root.statusJson() }
    function extend(minutes: string): string { root.extend(Number(minutes)); return root.statusJson() }
    function hideBreak(): string { root.dismissOverlay(); return root.statusJson() }
    function showBreak(): string { root.showOverlay(); return root.statusJson() }
  }

  // ------------------------------------------------------------------ break screen

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData
      visible: root.overlayVisible
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "uni-pomodoro"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
      exclusionMode: ExclusionMode.Ignore

      readonly property color fg: Color.foreground
      readonly property color accent: Color.accent
      readonly property string fontFamily: Style.font.family
      readonly property int ringSize: Math.round(Math.min(win.width, win.height) * 0.36)
      readonly property int ringStroke: Math.max(4, Math.round(ringSize * 0.02))

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, root.config.overlayDim)
      }

      Item {
        id: keys
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.dismissOverlay(); event.accepted = true }
          else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.phase === "ready") root.toggle(); else root.skip()
            event.accepted = true
          }
        }
      }

      Item {
        id: content
        anchors.fill: parent
        opacity: win.visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }

        Column {
          anchors.centerIn: parent
          spacing: Math.round(win.ringSize * 0.09)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.phaseLabel.toUpperCase()
            color: win.accent
            font.family: win.fontFamily
            font.pixelSize: Math.round(win.ringSize * 0.075)
            font.letterSpacing: Math.round(win.ringSize * 0.02)
            font.bold: true
          }

          Item {
            width: win.ringSize
            height: win.ringSize
            anchors.horizontalCenter: parent.horizontalCenter

            Shape {
              anchors.fill: parent
              preferredRendererType: Shape.CurveRenderer

              ShapePath {
                strokeColor: Util.alpha(win.fg, 0.12)
                strokeWidth: win.ringStroke
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                  centerX: win.ringSize / 2; centerY: win.ringSize / 2
                  radiusX: win.ringSize / 2 - win.ringStroke; radiusY: radiusX
                  startAngle: -90; sweepAngle: 360
                }
              }

              ShapePath {
                strokeColor: win.accent
                strokeWidth: win.ringStroke
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                  centerX: win.ringSize / 2; centerY: win.ringSize / 2
                  radiusX: win.ringSize / 2 - win.ringStroke; radiusY: radiusX
                  startAngle: -90
                  sweepAngle: root.phase === "ready" ? 360 : Math.max(0.01, 360 * (1 - root.progress))
                  Behavior on sweepAngle { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }
                }
              }
            }

            Text {
              anchors.centerIn: parent
              text: root.phase === "ready" ? (root.readyNext === "break" ? "󰅶" : "󰧐") : root.clock
              color: root.paused ? Util.alpha(win.fg, 0.5) : win.fg
              font.family: win.fontFamily
              font.pixelSize: Math.round(win.ringSize * (root.phase === "ready" ? 0.34 : 0.24))
              font.bold: true
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(win.width * 0.7, win.ringSize * 2.2)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.phase === "ready"
              ? (root.readyNext === "break" ? "Nice work. Take the break." : "Ready when you are.")
              : (root.paused ? "Paused." : root.tip)
            color: Util.alpha(win.fg, 0.72)
            font.family: win.fontFamily
            font.pixelSize: Math.round(win.ringSize * 0.06)
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Math.round(win.ringSize * 0.04)
            visible: root.dots.length > 0
            Repeater {
              model: root.dots
              Rectangle {
                required property string modelData
                width: Math.round(win.ringSize * 0.04)
                height: width
                radius: width / 2
                color: modelData === "done" ? win.accent
                     : modelData === "current" ? Util.alpha(win.accent, 0.35)
                     : Util.alpha(win.fg, 0.14)
                border.width: modelData === "current" ? 1 : 0
                border.color: win.accent
              }
            }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(10)

            Button {
              visible: root.phase === "ready"
              iconText: root.readyNext === "break" ? "󰅶" : "󰐊"
              text: root.readyNext === "break"
                ? "Start break"
                : "Start " + root.config.focus + " min focus"
              foreground: win.fg
              accent: win.accent
              bordered: true
              selected: true
              fontSize: Style.font.title
              horizontalPadding: Style.space(16)
              verticalPadding: Style.space(9)
              onClicked: root.toggle()
            }
            Button {
              visible: root.isBreak
              iconText: root.running ? "󰏤" : "󰐊"
              text: root.running ? "Pause" : "Resume"
              foreground: win.fg
              accent: win.accent
              bordered: true
              fontSize: Style.font.title
              horizontalPadding: Style.space(16)
              verticalPadding: Style.space(9)
              onClicked: root.toggle()
            }
            Button {
              visible: root.isBreak
              text: "+5 min"
              foreground: win.fg
              accent: win.accent
              bordered: true
              fontSize: Style.font.title
              horizontalPadding: Style.space(16)
              verticalPadding: Style.space(9)
              onClicked: root.extend(5)
            }
            Button {
              visible: root.isBreak
              iconText: "󰒭"
              text: "Skip break"
              foreground: win.fg
              accent: win.accent
              bordered: true
              fontSize: Style.font.title
              horizontalPadding: Style.space(16)
              verticalPadding: Style.space(9)
              onClicked: root.skip()
            }
            Button {
              iconText: "󰓛"
              text: "Stop"
              foreground: win.fg
              accent: win.accent
              bordered: true
              fontSize: Style.font.title
              horizontalPadding: Style.space(16)
              verticalPadding: Style.space(9)
              onClicked: root.stop()
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.phase === "ready" ? "Enter starts · Esc hides" : "Space skips · Esc hides this screen"
            color: Util.alpha(win.fg, 0.35)
            font.family: win.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
