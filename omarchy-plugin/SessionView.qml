import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Api.js" as Api

// One session: header, timeline, pinned approvals, composer.
Item {
  id: root

  property var service: null
  property var session: null
  property color fg: Color.foreground
  property color bg: Color.background
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.menuFamily

  readonly property var s: session || ({})
  readonly property string sid: s.id || ""
  readonly property bool running: s.state === "running"
  readonly property bool queued: s.state === "queued"
  readonly property bool ended: s.state === "ended" || s.state === "failed" || s.state === "budget"
  readonly property var info: Api.sessionInfo(s.state)

  readonly property var pending: {
    if (!service || service.revision < 0) return []
    return service.eventsFor(sid).filter(function(e) { return e.kind === "approval" && !e.decision })
  }

  // ── Timeline model: applied incrementally so the list never resets/jumps ──
  ListModel { id: evModel }
  property string modelFor: ""
  function syncEvents() {
    if (!service) return
    var arr = service.eventsFor(sid)
    var reset = modelFor !== sid || arr.length < evModel.count
    if (!reset && evModel.count > 0 && arr.length > 0 && evModel.get(0).j !== JSON.stringify(arr[0])) reset = true
    if (reset) { evModel.clear(); modelFor = sid }
    // Re-check the tail (streaming text/step results update in place), then append the rest.
    for (var i = Math.max(0, evModel.count - 3); i < evModel.count; i++) {
      var j = JSON.stringify(arr[i]); if (evModel.get(i).j !== j) evModel.set(i, { j: j })
    }
    for (var k = evModel.count; k < arr.length; k++) evModel.append({ j: JSON.stringify(arr[k]) })
  }
  onSidChanged: syncEvents()
  Connections { target: root.service; function onRevisionChanged() { root.syncEvents() } }
  Component.onCompleted: syncEvents()

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: Style.space(16)
    spacing: Style.space(10)

    // Header: title + state, then controls
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)
      Text {
        Layout.fillWidth: true
        text: Api.oneLine(root.s.name || root.s.title || "Session", 200)
        color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.subtitle; font.weight: Font.DemiBold
        elide: Text.ElideRight
      }
      Rectangle {
        Layout.preferredHeight: Style.space(22); Layout.preferredWidth: pill.implicitWidth + Style.space(16)
        radius: height / 2
        color: Util.alpha(root.info.tone === "urgent" ? root.urgent : root.info.tone === "live" ? root.accent : root.fg, 0.14)
        Text { id: pill; anchors.centerIn: parent; text: root.info.label; color: root.info.tone === "urgent" ? root.urgent : root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.weight: Font.DemiBold }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)
      ButtonGroup {
        options: [{ value: "ask", label: "Ask me" }, { value: "auto", label: "Autopilot" }]
        value: root.s.mode || "ask"
        fontFamily: root.fontFamily; fontSize: Style.font.bodySmall; accent: root.accent
        onChanged: function(v) { root.service.setMode(v) }
      }
      Item { Layout.fillWidth: true }
      Button { visible: root.running; text: "Stop"; bordered: true; accent: root.urgent; foreground: root.urgent; fontFamily: root.fontFamily; onClicked: root.service.abort() }
      Button { visible: root.ended; text: "Retry"; bordered: true; fontFamily: root.fontFamily; onClicked: root.service.retry() }
      Button { visible: root.queued; text: "Cancel"; bordered: true; fontFamily: root.fontFamily; onClicked: root.service.cancelQueued(root.sid) }
      Button { text: "Archive"; bordered: true; fontFamily: root.fontFamily; onClicked: { root.service.archiveSession(root.sid); root.service.select("") } }
    }

    Text {
      Layout.fillWidth: true
      text: Api.oneLine((root.s.model || "").split("/").pop(), 60) + "  ·  " + (root.s.thinking || "medium") + " thinking  ·  "
          + (root.s.steps || 0) + " steps  ·  " + Api.money(root.s.cost)
          + ((root.s.scope && root.s.scope.length) ? "  ·  " + root.s.scope.join(", ") : "")
      color: Util.alpha(root.fg, 0.5); font.family: root.fontFamily; font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Util.alpha(root.fg, 0.08) }

    // Timeline
    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true

      ListView {
        id: timeline
        anchors.fill: parent
        clip: true
        spacing: Style.space(6)
        model: evModel
        boundsBehavior: Flickable.StopAtBounds
        // Stick to the bottom unless the user scrolled up.
        property bool follow: true
        onMovementEnded: follow = atYEnd
        onCountChanged: if (follow) Qt.callLater(positionViewAtEnd)
        onContentHeightChanged: if (follow) Qt.callLater(positionViewAtEnd)
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
        delegate: EventItem {
          required property string j
          width: timeline.width - Style.space(10)
          ev: JSON.parse(j)
          fg: root.fg; bg: root.bg; accent: root.accent; urgent: root.urgent; fontFamily: root.fontFamily
          inTimeline: true
          onDecide: function(id, value) { root.service.answer(id, value) }
          onGrant: function(app, where) { root.service.grant(root.sid, app, where) }
        }
        Text {
          visible: timeline.count === 0
          anchors.centerIn: parent
          text: root.running ? "Working…" : "Nothing here yet."
          color: Util.alpha(root.fg, 0.4); font.family: root.fontFamily; font.pixelSize: Style.font.body
        }
      }
      Button {
        visible: !timeline.follow && timeline.count > 0
        anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: Style.space(8)
        text: "↓ Latest"; bordered: true; fontFamily: root.fontFamily
        onClicked: { timeline.follow = true; timeline.positionViewAtEnd() }
      }
    }

    // Pending approvals: always visible, never scroll away.
    ColumnLayout {
      Layout.fillWidth: true
      visible: root.pending.length > 0
      spacing: Style.space(6)
      Repeater {
        model: root.pending
        delegate: EventItem {
          required property var modelData
          Layout.fillWidth: true
          ev: modelData
          fg: root.fg; bg: root.bg; accent: root.accent; urgent: root.urgent; fontFamily: root.fontFamily
          onDecide: function(id, value) { root.service.answer(id, value) }
          onGrant: function(app, where) { root.service.grant(root.sid, app, where) }
        }
      }
    }

    // Composer
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)
      TextField {
        id: composer
        Layout.fillWidth: true
        placeholderText: root.running ? "Steer — \"be more chill\", \"stop after 3 posts\"…"
                       : root.queued ? "Queued — your message runs when it gets the phone"
                       : "Message — continues this session"
        font.family: root.fontFamily
        onAccepted: { var t = text.trim(); if (!t) return; root.service.send(t); text = ""; timeline.follow = true }
      }
      Button { text: "Send"; bordered: true; accent: root.accent; fontFamily: root.fontFamily; onClicked: composer.accepted() }
    }
  }
}
