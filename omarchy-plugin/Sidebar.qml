import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Api.js" as Api

// Left column: phone status + live view, phone actions, new session, session list.
Item {
  id: root

  property var service: null
  property bool active: false
  property bool large: false
  property color fg: Color.foreground
  property color bg: Color.background
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.menuFamily

  signal toggleLarge()
  signal closePanel()

  readonly property string phoneState: service ? service.phoneState : "no_phone"
  readonly property var phone: Api.phoneInfo(phoneState)
  readonly property string selectedId: service ? service.selectedId : ""

  // Plain rows rebuilt per revision: [{header,label} | {id,title,state,pending,updatedAt,now}]
  readonly property var rows: {
    if (!service || service.revision < 0) return []
    var groups = [["waiting", "Needs you"], ["running", "Running"], ["queued", "Queued"], ["idle", "Idle"], ["ended", "Ended"]]
    var out = []
    for (var g = 0; g < groups.length; g++) {
      var items = service.sessions.filter(function(s) {
        if (s.archived && !service.showArchived) return false
        var st = (s.state === "failed" || s.state === "budget") ? "ended" : s.state
        return st === groups[g][0]
      })
      if (!items.length) continue
      out.push({ header: true, label: groups[g][1] })
      for (var i = 0; i < items.length; i++) {
        var s = items[i]
        out.push({ header: false, id: s.id, title: s.name || s.title || "Session", state: s.state,
                   pending: s.pending || 0, updatedAt: s.updatedAt, now: s.now || "" })
      }
    }
    return out
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: Style.space(14)
    spacing: Style.space(10)

    // Header
    RowLayout {
      Layout.fillWidth: true
      Text {
        Layout.fillWidth: true
        text: "Piphone"
        color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.subtitle; font.weight: Font.DemiBold
        elide: Text.ElideRight
      }
      Button { text: root.large ? "⤡" : "⤢"; tooltipText: root.large ? "Compact" : "Large"; fontFamily: root.fontFamily; onClicked: root.toggleLarge() }
      Button { text: "✕"; tooltipText: "Close (Esc)"; fontFamily: root.fontFamily; onClicked: root.closePanel() }
    }

    // Phone status + live view
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: root.large ? Style.space(420) : Style.space(300)
      radius: Style.space(12)
      color: Util.alpha(root.fg, 0.04)
      border.width: 1; border.color: Util.alpha(root.fg, 0.08)

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(10)
        spacing: Style.space(6)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          Rectangle {
            Layout.preferredWidth: Style.space(8); Layout.preferredHeight: Style.space(8); radius: width / 2
            color: root.phoneState === "ready" ? root.accent : root.phoneState === "error" ? root.urgent : Util.alpha(root.fg, 0.3)
          }
          Text {
            Layout.fillWidth: true
            text: root.phone.label
            color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.weight: Font.DemiBold
            elide: Text.ElideRight
          }
        }
        LiveView {
          Layout.fillWidth: true
          Layout.fillHeight: true
          active: root.active && root.phoneState === "ready"
          fg: root.fg; fontFamily: root.fontFamily
          hint: root.phone.hint
        }
        Text {
          Layout.fillWidth: true
          visible: !!(root.service && root.service.expiryLabel)
          text: root.service ? root.service.expiryLabel : ""
          color: Util.alpha(root.fg, 0.45); font.family: root.fontFamily; font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)
      readonly property bool can: root.phoneState === "ready" && !(root.service && root.service.phoneBusy)
      Button { Layout.fillWidth: true; text: "Home"; bordered: true; enabled: parent.can; fontFamily: root.fontFamily; onClicked: root.service.phoneAction("home") }
      Button { Layout.fillWidth: true; text: "Screenshot"; bordered: true; enabled: parent.can; fontFamily: root.fontFamily; onClicked: root.service.phoneAction("screenshot") }
      Button { Layout.fillWidth: true; text: "Terminal"; bordered: true; fontFamily: root.fontFamily; onClicked: root.service.openTerminal() }
    }

    Button {
      Layout.fillWidth: true
      text: "+  New session"
      bordered: true; selected: root.selectedId === ""; accent: root.accent; fontFamily: root.fontFamily
      onClicked: if (root.service) root.service.select("")
    }

    // Sessions
    ListView {
      id: list
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      spacing: Style.space(2)
      model: root.rows
      boundsBehavior: Flickable.StopAtBounds
      delegate: Item {
        id: row
        required property var modelData
        width: list.width
        height: modelData.header ? Style.space(26) : Style.space(46)

        Text {
          visible: row.modelData.header
          anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.bottomMargin: Style.space(4)
          text: String(row.modelData.label || "").toUpperCase()
          color: Util.alpha(root.fg, 0.45); font.family: root.fontFamily; font.pixelSize: Style.font.caption
          font.weight: Font.DemiBold; font.letterSpacing: 1
        }

        Rectangle {
          visible: !row.modelData.header
          anchors.fill: parent
          radius: Style.space(8)
          color: row.modelData.id === root.selectedId ? Util.alpha(root.accent, 0.16)
               : rowMouse.containsMouse ? Util.alpha(root.fg, 0.06) : "transparent"

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8)
            spacing: Style.space(8)
            Rectangle {
              Layout.preferredWidth: Style.space(7); Layout.preferredHeight: Style.space(7); radius: width / 2
              color: row.modelData.state === "waiting" ? root.urgent : row.modelData.state === "running" ? root.accent : Util.alpha(root.fg, 0.25)
            }
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 0
              Text {
                Layout.fillWidth: true
                text: Api.oneLine(row.modelData.title, 120)
                color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
              Text {
                Layout.fillWidth: true
                text: row.modelData.state === "running" && row.modelData.now ? Api.oneLine(row.modelData.now, 80) : Api.relTime(row.modelData.updatedAt)
                color: Util.alpha(root.fg, 0.45); font.family: root.fontFamily; font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
            Rectangle {
              visible: row.modelData.pending > 0
              Layout.preferredHeight: Style.space(18); Layout.preferredWidth: Math.max(Style.space(18), badge.implicitWidth + Style.space(10))
              radius: height / 2; color: root.urgent
              Text { id: badge; anchors.centerIn: parent; text: String(row.modelData.pending); color: root.bg; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.weight: Font.Bold }
            }
          }
          MouseArea { id: rowMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.service.select(row.modelData.id) }
        }
      }
      Text {
        visible: list.count === 0
        anchors.centerIn: parent
        text: "No sessions yet"
        color: Util.alpha(root.fg, 0.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption
      }
    }
  }
}
