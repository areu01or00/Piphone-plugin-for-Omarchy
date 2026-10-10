// BoundedClipboard — paste into a text input WITHOUT the shared Quickshell
// shell ever doing Qt's native Wayland clipboard read. Qt's reader appends the
// data offer until EOF with no size limit, so a malicious/streaming clipboard
// source could exhaust memory and hang the whole shell on paste.
//
// Instead we read through an external reader whose byte count is hard-capped:
//   wl-paste … | head -c <limit>
// head stops after <limit> bytes and closes the pipe; wl-paste then gets
// SIGPIPE and exits, so only a short-lived helper ever touches the stream and
// at most <limit> bytes reach the shell. Intercept Ctrl+V / Shift+Insert on the
// target (calling paste(false)); middle-click (primary selection) is handled
// here. Place as a child of the input; `target` defaults to the parent.
import QtQuick
import Quickshell.Io

Item {
  id: root
  property Item target: parent
  property int limit: 8000
  anchors.fill: parent

  function paste(primary) {
    if (!target || target.readOnly) return;
    proc.command = ["bash", "-c",
      "wl-paste " + (primary ? "-p " : "") + "--no-newline 2>/dev/null | head -c " + root.limit];
    proc.running = true;
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.MiddleButton   // let left/right reach the text input
    cursorShape: Qt.IBeamCursor
    onClicked: root.paste(true)
  }

  Process {
    id: proc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.target && text && text.length) root.target.insert(root.target.cursorPosition, text);
      }
    }
  }
}
