import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Api.js" as Api

// New-session form: mandate, quick-starts, apps, model, posting mode, limits, start.
Item {
  id: root

  property var service: null
  property color fg: Color.foreground
  property color bg: Color.background
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.menuFamily

  property var appsSelected: []
  property string mode: "ask"
  property string model: service ? service.lastModel : ""
  property string thinking: service ? service.lastThinking : "medium"
  property int maxHour: 6
  property int maxSession: 20
  property string costCap: "0.5"

  readonly property bool phoneReady: service && service.phoneState === "ready"
  readonly property string driverName: service ? service.driverName : ""

  readonly property var templates: [
    { label: "Learn how I talk", apps: ["Discord"],
      goal: "Learn how I talk: search Discord for my own recent messages (search `from:` and my display name), scroll through them, then use the remember tool to append a 6–10 line style profile with 5 real example lines from my messages to profile.md. Show me what you wrote. Do not post anything." },
    { label: "Handle my Discord like me", apps: ["Discord"],
      goal: "For this session, keep an eye on my Discord and reply to people the way I would — short, casual, same language mix as the channel. Use the voice profile in profile.md. First post a 3–5 line plan with phone_plan and wait for approval; then use phone_watch so you sleep between events. Skip anything personal or heated." },
    { label: "Watch X for {topic} → #{channel}", apps: ["X", "Discord"],
      goal: "Watch X for {topic} and relay a grounded summary (source author + handle + link, no invented facts) to #{channel} on Discord. First post a 3–5 line plan with phone_plan and wait for approval; then use phone_watch so you sleep between events. Confirm the channel-name marker before posting." },
    { label: "Catch me up since {time}", apps: ["Discord"],
      goal: "Summarise my Discord channels since {time} as who-said-what. Scroll back until the timestamp. Don't post anything." },
    { label: "Find jobs for me", apps: ["LinkedIn"],
      goal: "Find jobs for me: run pdftotext on ~/Documents/resume.pdf (never open other files in that folder), extract roles, skills and location, ask me for location/remote if unknown, search LinkedIn Jobs with the role plus explicit geography, open job cards and capture title, company, location, Easy Apply and the hiring team, then give a ranked shortlist with reasons. Draft recruiter outreach but never send it." },
    { label: "Tweet: {text}", apps: ["X"], goal: "Post this on X from my account: {text}" }
  ]
  readonly property var commonApps: ["X", "Discord", "LinkedIn", "Safari", "Files", "Messages", "WhatsApp", "Settings"]

  function useTemplate(t) {
    goal.text = t.goal; appsSelected = t.apps.slice()
    goal.forceActiveFocus()
    var m = goal.text.match(/\{[^}]*\}/)
    if (m) goal.select(m.index, m.index + m[0].length); else goal.cursorPosition = goal.text.length
  }
  function hasApp(n) { return appsSelected.some(function(x) { return String(x).toLowerCase() === String(n).toLowerCase() }) }
  function toggleApp(n) {
    var next = appsSelected.filter(function(x) { return String(x).toLowerCase() !== String(n).toLowerCase() })
    if (next.length === appsSelected.length) next.push(n)
    appsSelected = next
  }
  readonly property bool blanksFilled: !/\{[^}]*\}/.test(goal.text)
  readonly property bool canStart: goal.text.trim().length > 0 && blanksFilled
  function submit() {
    if (!canStart || !service) return
    service.createSession({ goal: goal.text.trim(), mode: mode, apps: appsSelected.slice(), model: model, thinking: thinking,
                            limits: { hour: maxHour, session: maxSession, cost: Number(costCap) } })
    goal.text = ""; appsSelected = []
  }

  readonly property var modelOptions: {
    var out = [], ms = service ? service.models : []
    for (var i = 0; i < ms.length; i++)
      out.push({ value: ms[i].id, label: ms[i].label, description: ms[i].provider + (ms[i].images ? "" : " · text-only (no screenshots)") })
    return out
  }
  readonly property var appOptions: {
    var out = [], as = service ? service.appsList : []
    for (var i = 0; i < as.length; i++) out.push({ value: as[i].name, label: as[i].name, description: as[i].bundle })
    return out
  }

  component SectionLabel: Text {
    color: Util.alpha(root.fg, 0.5); font.family: root.fontFamily; font.pixelSize: Style.font.caption
    font.weight: Font.DemiBold; font.letterSpacing: 1
  }

  Flickable {
    id: flick
    anchors.fill: parent
    anchors.margins: Style.space(20)
    contentHeight: form.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    ColumnLayout {
      id: form
      width: flick.width
      spacing: Style.space(14)

      Text {
        Layout.fillWidth: true
        text: "What should I handle while you're away?"
        color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.weight: Font.DemiBold
        wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
      }

      QQC.TextArea {
        id: goal
        Layout.fillWidth: true
        Layout.preferredHeight: Math.max(Style.space(96), Math.min(contentHeight + Style.space(24), Style.space(180)))
        placeholderText: "e.g. Open X and tell me the name on my profile"
        placeholderTextColor: Util.alpha(root.fg, 0.35)
        wrapMode: TextEdit.Wrap
        color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.body
        selectByMouse: true; selectionColor: Util.alpha(root.accent, 0.35)
        padding: Style.space(12)
        background: Rectangle {
          radius: Style.space(10); color: Util.alpha(root.fg, 0.04)
          border.width: goal.activeFocus ? 2 : 1
          border.color: goal.activeFocus ? Util.alpha(root.accent, 0.8) : Util.alpha(root.fg, 0.12)
        }
        Keys.onPressed: function(e) {
          if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && (e.modifiers & Qt.ControlModifier)) { root.submit(); e.accepted = true; return }
          // Route paste through the bounded reader; never Qt's native unbounded read.
          if ((e.key === Qt.Key_V && (e.modifiers & Qt.ControlModifier)) || (e.key === Qt.Key_Insert && (e.modifiers & Qt.ShiftModifier))) { clip.paste(false); e.accepted = true }
        }
        // Backstop: clamp retained length (bounded paste already caps the read).
        onTextChanged: if (length > 8000) remove(8000, length)
        BoundedClipboard { id: clip }
      }

      Flow {
        Layout.fillWidth: true
        spacing: Style.space(6)
        Repeater {
          model: root.templates
          delegate: Button {
            required property var modelData
            text: modelData.label; bordered: true; fontFamily: root.fontFamily; fontSize: Style.font.bodySmall
            onClicked: root.useTemplate(modelData)
          }
        }
      }

      SectionLabel { text: "APPS  ·  " + (root.appsSelected.length ? root.appsSelected.join(", ") : "agent picks") }
      Flow {
        Layout.fillWidth: true
        spacing: Style.space(6)
        Repeater {
          model: root.commonApps.concat(root.appsSelected.filter(function(a) { return root.commonApps.indexOf(a) < 0 }))
          delegate: Button {
            required property var modelData
            text: modelData; bordered: true; selected: root.hasApp(modelData); accent: root.accent
            fontFamily: root.fontFamily; fontSize: Style.font.bodySmall
            onClicked: root.toggleApp(modelData)
          }
        }
      }
      SearchableDropdown {
        Layout.fillWidth: true
        visible: root.appOptions.length > 0
        showLabel: false
        triggerLabel: "Add another app…"
        placeholderText: "Search installed apps"
        options: root.appOptions
        fontFamily: root.fontFamily
        onChanged: function(v) { if (!root.hasApp(v)) root.toggleApp(v) }
      }

      SectionLabel { text: "MODEL" }
      SearchableDropdown {
        Layout.fillWidth: true
        showLabel: false
        value: root.model
        options: root.modelOptions
        placeholderText: "Search models"
        fontFamily: root.fontFamily
        onChanged: function(v) { root.model = v }
      }
      ButtonGroup {
        options: [{ value: "off", label: "Thinking off" }, { value: "low", label: "Low" }, { value: "medium", label: "Medium" }, { value: "high", label: "High" }]
        value: root.thinking
        fontFamily: root.fontFamily; fontSize: Style.font.bodySmall; accent: root.accent
        onChanged: function(v) { root.thinking = v }
      }

      SectionLabel { text: "WHEN IT WANTS TO POST" }
      ButtonGroup {
        options: [{ value: "ask", label: "Ask me first" }, { value: "auto", label: "Autopilot" }]
        value: root.mode
        fontFamily: root.fontFamily; fontSize: Style.font.bodySmall; accent: root.accent
        onChanged: function(v) { root.mode = v }
      }
      Text {
        Layout.fillWidth: true
        text: root.mode === "auto" ? "Posts as you without asking, within the limits below. No DMs to strangers, no money."
                                   : "Every post becomes a card you approve, edit or deny."
        color: Util.alpha(root.fg, 0.5); font.family: root.fontFamily; font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      SectionLabel { text: "LIMITS" }
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(16)
        NumberField { label: "Posts / hour"; from: 1; to: 60; value: root.maxHour; fontFamily: root.fontFamily; onModified: function(v) { root.maxHour = v } }
        NumberField { label: "Posts / session"; from: 1; to: 200; value: root.maxSession; fontFamily: root.fontFamily; onModified: function(v) { root.maxSession = v } }
      }
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        Text { text: "Cost cap"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
        ButtonGroup {
          options: [{ value: "0.25", label: "$0.25" }, { value: "0.5", label: "$0.50" }, { value: "1", label: "$1" }, { value: "2", label: "$2" }, { value: "0", label: "None" }]
          value: root.costCap
          fontFamily: root.fontFamily; fontSize: Style.font.bodySmall; accent: root.accent
          onChanged: function(v) { root.costCap = v }
        }
      }

      RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(6)
        Button {
          text: !root.blanksFilled ? "Fill in the {…} blanks"
              : !root.phoneReady ? "Queue — starts when plugged in"
              : root.driverName ? "Queue — after " + Api.oneLine(root.driverName, 30)
              : "Start session"
          enabled: root.canStart
          bordered: true; selected: root.canStart; accent: root.accent; fontFamily: root.fontFamily
          onClicked: root.submit()
        }
        Text { text: "Ctrl+Enter"; color: Util.alpha(root.fg, 0.35); font.family: root.fontFamily; font.pixelSize: Style.font.caption }
      }
      Item { Layout.preferredHeight: Style.space(8) }
    }
  }
}
