import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Live phone screen. c/mjpeg-tap keeps the newest frame of WDA's MJPEG stream in tmpfs;
// we reload that file. Decoding is downscaled via sourceSize, so it costs ~nothing.
Item {
  id: root

  property bool active: false
  property color fg: Color.foreground
  property string fontFamily: Style.font.menuFamily
  property string hint: ""

  readonly property string framePath: Quickshell.env("XDG_RUNTIME_DIR") + "/iphone-agent/frame.jpg"
  property int tick: 0
  property bool haveFrame: false

  Process { command: [(Quickshell.env("IPHONE_AGENT_REPO") || (Quickshell.env("HOME") + "/.config/omarchy/plugins/areu01or00.piphone")) + "/c/mjpeg-tap", "4"]; running: root.active }

  Timer {
    interval: 250; repeat: true; running: root.active
    onTriggered: root.tick++
  }
  onActiveChanged: if (!active) haveFrame = false

  // Phone-shaped box that fits the available area at the phone's aspect ratio.
  readonly property real aspect: 393 / 852
  readonly property real boxH: Math.min(height, width / aspect)
  readonly property real boxW: boxH * aspect

  Rectangle {
    width: root.boxW; height: root.boxH
    anchors.centerIn: parent
    radius: Style.space(14)
    color: Util.alpha(root.fg, 0.05)
    border.width: 1; border.color: Util.alpha(root.fg, 0.12)
    clip: true

    Image {
      id: img
      anchors.fill: parent
      anchors.margins: 1
      visible: root.active && root.haveFrame
      source: root.active ? "file://" + root.framePath + "?" + root.tick : ""
      sourceSize.width: Math.ceil(root.boxW * 1.5)   // decode at display size, not 1179×2556
      fillMode: Image.PreserveAspectFit
      cache: false
      asynchronous: false
      onStatusChanged: if (status === Image.Ready) root.haveFrame = true
    }

    Text {
      visible: !img.visible
      anchors.centerIn: parent
      width: parent.width - Style.space(16)
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      text: root.active ? "Starting live view…" : (root.hint || "Plug in your iPhone")
      color: Util.alpha(root.fg, 0.45); font.family: root.fontFamily; font.pixelSize: Style.font.caption
    }
  }
}
