import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "areu01or00.piphone"

  property string phoneState: "no_phone"
  property string phoneMessage: ""
  property int needsYou: 0
  property bool working: false
  readonly property bool ready: phoneState === "ready"
  readonly property bool error: phoneState === "error"
  readonly property string uiStatePath: Quickshell.env("XDG_RUNTIME_DIR") + "/iphone-agent/ui-state.json"

  function apply(raw) {
    try {
      var d = JSON.parse(raw || "{}")
      phoneState = String(d.state || "no_phone")
      phoneMessage = String(d.message || "")
      needsYou = Number(d.needsYou || 0)
      working = d.running === true
    } catch (e) { phoneState = "no_phone"; needsYou = 0; working = false }
  }

  function tooltip() {
    if (needsYou > 0) return "Piphone — " + needsYou + (needsYou === 1 ? " thing needs you" : " things need you")
    if (working) return "Piphone — working on your phone"
    if (phoneState === "ready") return "Piphone — iPhone ready"
    if (error) return "Piphone — " + (phoneMessage || "phone link error")
    return "Piphone — waiting for your iPhone"
  }

  FileView {
    path: root.uiStatePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.apply(text())
    onFileChanged: reload()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.needsYou > 0 ? "\uf10b " + root.needsYou : (root.error ? "\uf071" : "\uf10b")
    active: root.working || root.needsYou > 0 || root.error
    activeColor: root.needsYou > 0 || root.error ? Color.urgent : Color.accent
    dimmed: !root.ready && !root.working && root.needsYou === 0
    tooltipText: root.tooltip()
    onPressed: function(mouseButton) {
      if (!root.bar) return
      if (mouseButton === Qt.RightButton) {
        root.bar.run("omarchy-shell shell summon " + root.moduleName + " '{\"view\":\"new\"}'")
        return
      }
      root.bar.run("omarchy-shell shell toggle " + root.moduleName)
    }

    // Subtle pulse while the agent drives the phone.
    SequentialAnimation on scale {
      running: root.working
      loops: Animation.Infinite
      NumberAnimation { from: 1; to: 1.12; duration: 900; easing.type: Easing.InOutSine }
      NumberAnimation { from: 1.12; to: 1; duration: 900; easing.type: Easing.InOutSine }
    }
  }
}
