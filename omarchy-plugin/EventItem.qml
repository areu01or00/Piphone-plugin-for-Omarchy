import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "Api.js" as Api

// One timeline entry. Kinds: user agent step look approval status error result.
Item {
  id: root

  property var ev: ({})
  property color fg: Color.foreground
  property color bg: Color.background
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.menuFamily

  // In the timeline a pending approval is only a pointer; the actionable card is pinned below.
  property bool inTimeline: false
  signal decide(string id, var value)
  signal grant(string app, string where)
  signal expand(var ev)

  function postParts() { var m = String(root.ev.title || "").match(/^Post to (.*?) \/ (.*?) —/); return m ? { app: m[1], where: m[2] } : null }
  readonly property bool isPlan: String(root.ev.title || "").indexOf("Plan checkpoint") === 0

  readonly property string kind: String(ev.kind || "")
  readonly property int pad: Style.space(3)

  implicitHeight: loader.item ? loader.item.implicitHeight + pad * 2 : 0

  Loader {
    id: loader
    y: root.pad
    width: root.width
    sourceComponent: {
      switch (root.kind) {
        case "user": return userC
        case "agent": return agentC
        case "step": return stepC
        case "look": return lookC
        case "approval": return (root.inTimeline && !root.ev.decision) ? pendingNoteC : approvalC
        case "status": return statusC
        case "error": return errorC
        case "result": return resultC
        default: return agentC
      }
    }
  }

  component Body: Text {
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    lineHeight: 1.15
  }

  Component {
    id: userC
    Item {
      implicitHeight: bubble.height
      Rectangle {
        id: bubble
        anchors.right: parent.right
        width: Math.min(parent.width * 0.8, userText.implicitWidth + Style.space(28))
        height: userText.implicitHeight + Style.space(20)
        radius: Style.space(12)
        color: Util.alpha(root.accent, 0.16)
        border.width: 1; border.color: Util.alpha(root.accent, 0.32)
        Body {
          id: userText
          anchors.fill: parent
          anchors.margins: Style.space(10)
          text: Api.clean(root.ev.text, 4000)
        }
      }
    }
  }

  Component {
    id: agentC
    Column {
      spacing: Style.space(3)
      Body { width: parent.width; text: Api.clean(root.ev.text, 8000) }
      Body { visible: root.ev.final === false; width: parent.width; text: "▍"; color: root.accent }
    }
  }

  Component {
    id: stepC
    Rectangle {
      implicitHeight: stepRow.implicitHeight + Style.space(10)
      radius: Style.space(8)
      color: mouse.containsMouse ? Util.alpha(root.fg, 0.05) : "transparent"
      Row {
        id: stepRow
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        anchors.margins: Style.space(8)
        spacing: Style.space(8)
        Text {
          width: parent.width - Style.space(96)
          text: (root.ev.ok === false ? "✕  " : root.ev.ok === true ? "✓  " : "·  ") + Api.oneLine(root.ev.text, 200)
          color: root.ev.ok === false ? root.urgent : Util.alpha(root.fg, 0.62)
          font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        Text {
          text: root.ev.ms ? (root.ev.ms >= 1000 ? (root.ev.ms / 1000).toFixed(1) + "s" : root.ev.ms + "ms") : ""
          color: Util.alpha(root.fg, 0.35)
          font.family: root.fontFamily; font.pixelSize: Style.font.caption
        }
      }
      MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.expand(root.ev) }
    }
  }

  Component {
    id: lookC
    Row {
      spacing: Style.space(10)
      Rectangle {
        width: Style.space(84); height: Style.space(170)
        radius: Style.space(10)
        color: Util.alpha(root.fg, 0.05)
        clip: true
        Image {
          anchors.fill: parent
          source: root.ev.image || ""
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          cache: false
        }
      }
      Item {
        width: parent.width - Style.space(100)
        height: parent.height
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          text: "Looked at the screen (inspection only)"
          color: Util.alpha(root.fg, 0.5)
          font.family: root.fontFamily; font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  Component {
    id: approvalC
    Rectangle {
      id: appr
      property bool pending: !root.ev.decision
      property bool editable: root.ev.dialog === "editor"
      implicitHeight: apprCol.implicitHeight + Style.space(22)
      radius: Style.space(10)
      color: Util.alpha(root.urgent, pending ? 0.1 : 0.04)
      border.width: 1
      border.color: Util.alpha(root.urgent, pending ? 0.5 : 0.2)
      opacity: root.ev.decision === "deny" ? 0.6 : 1
      Column {
        id: apprCol
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        anchors.margins: Style.space(12)
        spacing: Style.space(8)
        Text {
          width: parent.width
          text: appr.pending ? (appr.editable ? "REVIEW & EDIT THE POST" : "WAITING FOR YOU") : (root.ev.decision === "approve" ? "APPROVED" : "DENIED")
          color: root.urgent
          font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.weight: Font.Bold; font.letterSpacing: 0.9
        }
        Body { width: parent.width; text: Api.oneLine(root.ev.title, 240); font.pixelSize: Style.font.subtitle; font.weight: Font.DemiBold }
        QQC.TextArea {
          id: editArea
          visible: appr.editable
          width: parent.width
          height: visible ? Math.min(Math.max(contentHeight + Style.space(24), Style.space(70)), Style.space(200)) : 0
          text: root.ev.prefill || root.ev.message || ""
          readOnly: !appr.pending
          wrapMode: TextEdit.Wrap
          color: root.fg
          font.family: root.fontFamily; font.pixelSize: Style.font.subtitle
          selectByMouse: true; selectionColor: Util.alpha(root.accent, 0.35)
          padding: Style.space(10)
          background: Rectangle {
            radius: Style.space(8); color: Util.alpha(root.bg, 0.55)
            border.width: editArea.activeFocus ? 1 : 0; border.color: Util.alpha(root.accent, 0.7)
          }
        }
        Rectangle {
          visible: !appr.editable && !!root.ev.message
          width: parent.width
          height: Math.min(msgText.implicitHeight + Style.space(16), Style.space(180))
          radius: Style.space(8)
          color: Util.alpha(root.bg, 0.55)
          Body {
            id: msgText
            anchors.fill: parent; anchors.margins: Style.space(10)
            text: Api.clean(root.ev.message, 2000)
            font.pixelSize: Style.font.bodySmall
            clip: true
          }
        }
        Row {
          visible: appr.pending
          spacing: Style.space(8)
          Button {
            text: root.isPlan ? "Approve plan" : (appr.editable ? "Approve & send" : "Approve")
            bordered: true; selected: true; accent: root.accent; fontFamily: root.fontFamily
            onClicked: root.decide(String(root.ev.id), appr.editable ? editArea.text : true)
          }
          Button {
            text: "Deny"
            bordered: true; accent: root.urgent; foreground: root.urgent; fontFamily: root.fontFamily
            onClicked: root.decide(String(root.ev.id), appr.editable ? null : false)
          }
          Button {
            visible: appr.editable && !root.isPlan && !!root.postParts()
            text: "Approve all like this · 30m"
            bordered: true; fontFamily: root.fontFamily; accent: root.accent
            tooltipText: "Auto-approve posts to the same app and place for 30 minutes"
            onClicked: { var pp = root.postParts(); if (pp) root.grant(pp.app, pp.where); root.decide(String(root.ev.id), editArea.text) }
          }
        }
      }
    }
  }

  Component {
    id: pendingNoteC
    Text {
      text: "⏳ Waiting for your approval — see the card below"
      color: root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }

  Component {
    id: statusC
    Item {
      implicitHeight: statusText.implicitHeight + Style.space(10)
      Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 1; color: Util.alpha(root.fg, 0.08) }
      Rectangle {
        anchors.centerIn: parent
        width: statusText.implicitWidth + Style.space(16); height: statusText.implicitHeight + Style.space(4)
        color: root.bg
        Text {
          id: statusText
          anchors.centerIn: parent
          text: Api.oneLine(root.ev.text, 200).toUpperCase()
          color: Util.alpha(root.fg, 0.45)
          font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1
        }
      }
    }
  }

  Component {
    id: errorC
    Row {
      spacing: Style.space(8)
      Text { text: "⚠"; color: root.urgent; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
      Body { width: parent.width - Style.space(24); text: Api.clean(root.ev.text, 800); color: root.urgent; font.pixelSize: Style.font.bodySmall }
    }
  }

  Component {
    id: resultC
    Rectangle {
      implicitHeight: resText.implicitHeight + Style.space(24)
      radius: Style.space(10)
      color: Util.alpha(root.accent, 0.08)
      border.width: 1; border.color: Util.alpha(root.accent, 0.35)
      Column {
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        anchors.margins: Style.space(12)
        spacing: Style.space(6)
        Text { text: "RESULT"; color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.weight: Font.Bold; font.letterSpacing: 1 }
        Body { id: resText; width: parent.width; text: Api.clean(root.ev.text, 6000); font.pixelSize: Style.font.subtitle }
      }
    }
  }
}
