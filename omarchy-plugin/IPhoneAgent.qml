import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Piphone panel. A layer-shell surface anchored to the top-right under the bar, sized from
// the focused screen so it can never overflow. Sessions live in Service.qml and keep running
// while the panel is closed.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null

  readonly property color bg: Color.menu.background
  readonly property color fg: Color.menu.text
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property string uiFont: Style.font.menuFamily

  property bool opened: false
  property bool large: false
  readonly property string selectedId: service ? service.selectedId : ""
  // Service mutates session objects in place; copy per revision so bindings see a new value.
  readonly property var selSession: {
    if (!service || service.revision < 0) return null
    var s = service.sessionFor(selectedId)
    return s ? Object.assign({}, s) : null
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) {}
    if (payload.view === "new" && service) service.select("")
    opened = true
    if (service) { service.panelOpen = true; service.refresh() }
  }
  function close() { opened = false; if (service) service.panelOpen = false }
  function dismiss() {
    close()
    if (shell && typeof shell.hide === "function") shell.hide((manifest && manifest.id) || "x.iphone-agent")
  }

  // Inspection hook for `omarchy-shell shell call x.iphone-agent view <new|first|large|compact>`.
  function view(arg) {
    if (!service) return "no service"
    if (arg === "new") service.select("")
    else if (arg === "first") { for (var i = 0; i < service.sessions.length; i++) if (!service.sessions[i].archived) { service.select(service.sessions[i].id); break } }
    else if (arg === "large") large = true
    else if (arg === "compact") large = false
    return selectedId || "new"
  }

  // The monitor Hyprland has focused; fall back to the first screen.
  readonly property var targetScreen: {
    var name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    for (var i = 0; i < Quickshell.screens.length; i++) if (Quickshell.screens[i].name === name) return Quickshell.screens[i]
    return Quickshell.screens.length ? Quickshell.screens[0] : null
  }

  PanelWindow {
    id: win
    visible: root.opened
    screen: root.targetScreen
    color: "transparent"
    anchors { top: true; right: true }
    margins { top: Style.gapsOut; right: Style.gapsOut }
    exclusionMode: ExclusionMode.Normal
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "x-iphone-agent"
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    // Fit the screen: never wider/taller than what is available (bar height ≈ reserved via margin).
    readonly property int availW: (screen ? screen.width : 1536) - Style.gapsOut * 2
    readonly property int availH: (screen ? screen.height : 864) - Style.gapsOut * 2 - Style.space(52)
    implicitWidth: Math.min(Style.space(root.large ? 1240 : 980), availW)
    implicitHeight: Math.min(Style.space(root.large ? 820 : 680), availH)

    Rectangle {
      id: card
      anchors.fill: parent
      radius: Style.space(14)
      color: Util.alpha(root.bg, 0.94)
      border.width: 1
      border.color: Util.alpha(root.fg, 0.14)
      clip: true

      Keys.onEscapePressed: root.dismiss()
      focus: true

      RowLayout {
        anchors.fill: parent
        spacing: 0

        Sidebar {
          Layout.preferredWidth: Style.space(260)
          Layout.fillHeight: true
          service: root.service
          active: root.opened
          large: root.large
          fg: root.fg; bg: root.bg; accent: root.accent; urgent: root.urgent; fontFamily: root.uiFont
          onToggleLarge: root.large = !root.large
          onClosePanel: root.dismiss()
        }

        Rectangle { Layout.fillHeight: true; Layout.preferredWidth: 1; color: Util.alpha(root.fg, 0.08) }

        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          NewSession {
            anchors.fill: parent
            visible: !root.selSession
            service: root.service
            fg: root.fg; bg: root.bg; accent: root.accent; urgent: root.urgent; fontFamily: root.uiFont
          }
          SessionView {
            anchors.fill: parent
            visible: !!root.selSession
            service: root.service
            session: root.selSession
            fg: root.fg; bg: root.bg; accent: root.accent; urgent: root.urgent; fontFamily: root.uiFont
          }
        }
      }
    }
  }
}
