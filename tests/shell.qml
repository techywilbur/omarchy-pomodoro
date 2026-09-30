import QtQuick
import Quickshell
import "TestPlugin" as Plugin
import "Host" as Host

ShellRoot {
  id: test
  Host.PluginShellApi {
    id: api
    pluginId: "techywilbur.pomodoro"
    barConfig: ({layout: {center: [{id: pluginId, focus: 50, dnd: false, sound: false, notify: false, overlay: false}]}})
    _serviceLookup: function(id) { return id === pluginId ? engine : null }
    // Reproduce the host snapshot lag: widgets receive updated inline
    // settings before the scoped barConfig snapshot is refreshed.
    _updateSettings: function(id, settings) { widget.settings = settings; return true }
  }
  Plugin.Service { id: engine; shell: api; manifest: ({id: api.pluginId}) }
  QtObject {
    id: fakeBar
    property var shell: api
    property bool vertical: false
    property int barSize: 32
    property color foreground: "white"
    property color barForeground: "white"
    property color urgent: "red"
    property string fontFamily: "sans-serif"
    property bool foregroundAnimationEnabled: false
  }
  Plugin.BarWidget { id: widget; bar: fakeBar; settings: api.barConfig.layout.center[0] }
  function check(condition, message) {
    if (!condition) { console.error("FAIL", message); Qt.exit(1); throw new Error(message) }
    console.log("PASS", message)
  }
  function findItem(item, predicate, visited) {
    if (!item) return null
    visited = visited || []
    if (visited.indexOf(item) !== -1) return null
    visited.push(item)
    if (predicate(item)) return item
    var children = []
    var lists = [item.children, item.data, item.contentItem]
    for (var k = 0; k < lists.length; k++) {
      var list = lists[k]
      if (list && list.length !== undefined)
        for (var j = 0; j < list.length; j++) children.push(list[j])
      else if (list) children.push(list)
    }
    for (var i = 0; i < children.length; i++) {
      var found = findItem(children[i], predicate, visited)
      if (found) return found
    }
    return null
  }
  function findButton(item, label) {
    return findItem(item, function(candidate) { return candidate.text === label && typeof candidate.clicked === "function" })
  }
  Timer {
    interval: 1500
    running: true
    onTriggered: {
      check(widget.ready && engine.hydrated, "service available and restored")
      check(engine.paused && engine.remainingMs === 660000, "paused session restored without internal manifest metadata")
      engine.stop()
      check(engine.config.focus === 50, "scoped bar settings use 50 minutes")
      var start = findButton(widget, "Start")
      check(start !== null, "popup Start button exists")
      start.clicked()
      check(engine.running && engine.phase === "focus" && engine.plannedMs === 3000000, "Start button begins configured focus")
      start.clicked()
      check(!engine.running && engine.paused, "Pause button pauses")
      start.clicked()
      check(engine.running, "Resume button resumes")
      widget.writeSetting("focus", 40)
      check(engine.config.focus === 40 && widget.cfg.focus === 40, "popup setting updates engine and view")
      check(api.barConfig.layout.center[0].focus === 50, "settings synchronize despite stale host snapshot")
      var toggleKeys = ["dnd", "overlay", "sound"]
      var toggleLabels = ["Silence notifications", "Full-screen break", "End-of-block chime"]
      for (var toggleIndex = 0; toggleIndex < toggleKeys.length; toggleIndex++) {
        var key = toggleKeys[toggleIndex]
        var label = toggleLabels[toggleIndex]
        var toggle = findItem(widget, function(candidate) { return candidate.label === label && typeof candidate.clicked === "function" })
        check(toggle !== null, key + " toggle exists")
        var previous = engine.config[key]
        var otherKeys = toggleKeys.filter(function(candidate) { return candidate !== key })
        var otherValues = otherKeys.map(function(candidate) { return engine.config[candidate] })
        toggle.clicked()
        check(engine.config[key] === !previous && toggle.checked === !previous, key + " updates on first click")
        for (var otherIndex = 0; otherIndex < otherKeys.length; otherIndex++)
          check(engine.config[otherKeys[otherIndex]] === otherValues[otherIndex], key + " leaves " + otherKeys[otherIndex] + " unchanged")
        toggle.clicked()
        check(engine.config[key] === previous && toggle.checked === previous, key + " updates on second click without clicking another toggle")
      }
      api.barConfig = {layout: {right: [{id: api.pluginId, focus: 90, shortBreak: 9, sound: false, notify: false, overlay: false, dnd: false}]}}
      widget.settings = api.barConfig.layout.right[0]
      check(engine.config.focus === 90 && widget.cfg.shortBreak === 9, "external config hot reload and section change")
      engine.stop()
      start.clicked()
      check(engine.plannedMs === 5400000, "Start uses hot-reloaded duration")
      var fifteen = findButton(widget, "15 min")
      var twentyFive = findButton(widget, "25 min")
      var fifty = findButton(widget, "50 min")
      fifteen.clicked()
      check(fifteen.selected && !twentyFive.selected && !fifty.selected && engine.plannedMs === 900000, "selection follows 15-minute timer")
      fifty.clicked()
      check(fifty.selected && !twentyFive.selected && !fifteen.selected && engine.plannedMs === 3000000, "selection follows 50-minute timer")
      fifteen.rightClicked()
      check(engine.config.focus === 15 && fifty.selected, "right click updates default without changing active timer")
      var flow = findItem(widget, function(candidate) { return candidate.objectName === "focusPresets" })
      flow.width = 130
      flow.forceLayout()
      check(flow.implicitHeight > fifteen.height, "presets wrap on narrow popup")
      for (var i = 0; i < flow.children.length; i++) {
        var child = flow.children[i]
        if (child.visible && child.width > 0)
          check(child.x + child.width <= flow.width + 1, "preset stays within available width")
      }
      engine.stop()
      var shortBreak = findButton(widget, "Short · 9 min")
      check(shortBreak !== null, "break button reflects settings")
      shortBreak.clicked()
      check(engine.phase === "short" && engine.plannedMs === 540000, "break button starts configured break")
      var longBreak = findButton(widget, "Long · 15 min")
      check(shortBreak.selected && !longBreak.selected, "short break button shows selected state")
      check(!fifteen.selected && !twentyFive.selected && !fifty.selected, "focus presets are unselected during breaks")
      longBreak.clicked()
      check(longBreak.selected && !shortBreak.selected && engine.phase === "long", "long break button shows selected state")
      engine.stop()
      check(!shortBreak.selected && !longBreak.selected, "Stop clears break selection")
      check(engine.phase === "idle", "Stop resets timer")
      Qt.quit()
    }
  }
}
