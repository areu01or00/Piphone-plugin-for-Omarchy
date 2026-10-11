import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

// BoundedLineField — a short text input that never makes the shared shell
// read foreign clipboard data natively. Styled like Omarchy's qs.Ui.TextField.
//
// Why not TextField: every editable QQuickTextInput (TextField) subscribes to
// QClipboard::dataChanged at creation, and on Qt 6.11 its q_canPasteChanged
// calls mimeData->text() — a full Wayland read until EOF with no byte bound —
// on every clipboard change, before any paste. TextArea (QQuickTextEdit) only
// checks the offered formats (hasText()), so it never reads the data.
//
// Paste goes through BoundedClipboard (wl-paste | head -c limit); the default
// right-click menu (whose Paste does a native read) is disabled. Return/Enter
// emits accepted() instead of inserting a newline; pasted newlines are folded.
QQC.TextArea {
  id: root

  signal accepted()

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color selectionTint: Style.selectionFillFor(foreground, accent)
  property int maxLength: 8000
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.inputPaddingY

  readonly property bool _focused: activeFocus
  readonly property var _borderSpec: Border.controlSpec(_focused ? "focus" : (hovered ? "hover-cursor" : "normal"), root.foreground, root.accent)

  wrapMode: TextEdit.Wrap
  clip: true
  font.family: Style.font.family
  font.pixelSize: Style.font.body
  color: foreground
  selectByMouse: true
  selectionColor: selectionTint
  selectedTextColor: foreground
  placeholderTextColor: Qt.darker(foreground, 1.6)

  leftPadding: horizontalPadding + Border.left(_borderSpec)
  rightPadding: horizontalPadding + Border.right(_borderSpec)
  topPadding: verticalPadding + Border.top(_borderSpec)
  bottomPadding: verticalPadding + Border.bottom(_borderSpec)

  background: BorderSurface {
    color: Style.controlFill(root._focused, root.hovered, root.foreground, root.accent)
    borderSpec: root._borderSpec
    radius: Style.cornerRadius
  }

  // No native context menu: its Paste action reads the clipboard unbounded.
  QQC.ContextMenu.menu: null

  Keys.onPressed: function(e) {
    if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { root.accepted(); e.accepted = true }
    // Route every paste binding (Ctrl+V, Shift/Ctrl+Shift+Insert, F18, Paste key) through the bounded reader.
    else if (e.matches(StandardKey.Paste)) { clip.paste(false); e.accepted = true }
  }

  onTextChanged: {
    if (/[\r\n]/.test(text)) { var p = cursorPosition; text = text.replace(/[\r\n]+/g, " "); cursorPosition = Math.min(p, length) }
    // Backstop: clamp retained length (bounded paste already caps the read).
    if (length > maxLength) remove(maxLength, length)
  }

  BoundedClipboard { id: clip; limit: root.maxLength }
}
