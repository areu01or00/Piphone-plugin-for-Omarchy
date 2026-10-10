import QtQuick
import Quickshell
import Quickshell.Io
import "Api.js" as Api

// One live Pi session: owns a `pi --mode rpc` process and translates its
// JSONL events into normalized records for Service.
Item {
  id: root
  visible: false

  required property var service
  required property string runtimeId
  property string file: ""
  property string rpcSessionId: ""
  property bool streaming: false
  property string mode: "ask"
  property string model: ""
  property string thinking: "medium"
  property var startCommands: []
  property real cost: 0
  property int tokens: 0
  property int steps: 0
  property string lastAssistant: ""
  property int pending: 0

  readonly property string piBin: Quickshell.env("PI_BIN") || (Quickshell.env("HOME") + "/.local/share/mise/installs/pi/latest/pi/pi")
  readonly property string agentRepo: Quickshell.env("IPHONE_AGENT_REPO") || (Quickshell.env("HOME") + "/.config/omarchy/plugins/areu01or00.piphone")
  readonly property string sessionDir: Quickshell.env("HOME") + "/.local/share/iphone-agent/pi-sessions"

  signal failed(string message)

  function emit(rec) { root.service.ingest(root.runtimeId, rec) }

  function send(obj) {
    if (!proc.running) return
    proc.write(JSON.stringify(obj) + "\n")
  }

  function command() {
    var base = [root.piBin, "--mode", "rpc", "-ne", "-ns", "-e", root.agentRepo + "/pi-extension/phone.ts", "--session-dir", root.sessionDir]
    if (root.model) base.push("--model", root.model)
    if (root.thinking) base.push("--thinking", root.thinking)
    if (root.file) base.push("--session", root.file)
    return base
  }

  function applyModel(model, thinking) {
    root.model = model; root.thinking = thinking
    if (model) {
      var parts = model.split("/")
      root.send({ type: "set_model", provider: parts[0], modelId: parts.slice(1).join("/") })
    }
    root.send({ type: "set_thinking_level", level: thinking || "medium" })
    root.emit({ t: "model", model: model, thinking: thinking })
  }

  function start(promptText) {
    if (proc.running) { if (promptText) prompt(promptText); return }
    root.startPrompt = promptText || ""
    proc.command = command()
    proc.running = true
  }

  property string startPrompt: ""

  function prompt(text) {
    if (root.streaming) send({ type: "prompt", message: text, streamingBehavior: "steer" })
    else send({ type: "prompt", message: text })
  }

  function steer(text) { send({ type: "steer", message: text }) }
  function abort() { send({ type: "abort" }) }
  function setMode(m) { root.mode = m; send({ type: "prompt", message: "/phone-mode " + m, streamingBehavior: "steer" }) }
  function kill() { if (proc.running) proc.running = false }

  function answer(id, approved) {
    send({ type: "extension_ui_response", id: id, confirmed: approved === true })
    root.pending = Math.max(0, root.pending - 1)
    root.emit({ t: "approval-done", id: id, decision: approved ? "approve" : "deny" })
  }
  function answerEditor(id, value) {
    if (value === null || value === undefined) send({ type: "extension_ui_response", id: id, cancelled: true })
    else send({ type: "extension_ui_response", id: id, value: String(value) })
    root.pending = Math.max(0, root.pending - 1)
    root.emit({ t: "approval-done", id: id, decision: (value === null || value === undefined) ? "deny" : "approve" })
  }

  property var toolArgs: ({})
  property var toolStart: ({})
  property string currentAssistantId: ""

  function usage(u) {
    if (!u) return
    root.cost += Number(((u.cost || {}).total) || 0)
    root.tokens += Number(u.input || 0) + Number(u.output || 0)
    root.emit({ t: "usage", cost: root.cost, tokens: root.tokens, steps: root.steps })
  }

  function assistantText(message) {
    var out = ""
    var c = message && message.content
    if (typeof c === "string") return c
    if (Array.isArray(c)) for (var i = 0; i < c.length; i++) if (c[i] && c[i].type === "text") out += (out ? "\n\n" : "") + c[i].text
    return out
  }

  function handle(rec) {
    if (!rec || typeof rec !== "object") return
    switch (rec.type) {
      case "response":
        if (rec.command === "get_state" && rec.success && rec.data && rec.data.sessionFile) {
          root.rpcSessionId = rec.data.sessionId || ""
          root.emit({ t: "session", file: rec.data.sessionFile, sessionId: rec.data.sessionId || "", name: rec.data.sessionName || "" })
          var cmds = root.startCommands; root.startCommands = []
          for (var ci = 0; ci < cmds.length; ci++) root.send({ type: "prompt", message: cmds[ci] })
          if (root.startPrompt) { var p = root.startPrompt; root.startPrompt = ""; root.prompt(p) }
        }
        break
      case "agent_start":
        root.streaming = true; root.emit({ t: "streaming", value: true }); break
      case "agent_end":
        break
      case "agent_settled":
        root.streaming = false; root.emit({ t: "streaming", value: false })
        if (root.lastAssistant) root.emit({ t: "result", text: root.lastAssistant })
        break
      case "message_start":
        if (rec.message && rec.message.role === "assistant") {
          root.lastAssistant = ""
          root.currentAssistantId = "a" + (Date.now()) + Math.round(Math.random() * 1000)
          root.emit({ t: "assistant", id: root.currentAssistantId, text: "", final: false })
        }
        break
      case "message_update":
        if (rec.assistantMessageEvent && rec.assistantMessageEvent.type === "text_delta" && root.currentAssistantId) {
          root.lastAssistant += rec.assistantMessageEvent.delta
          root.emit({ t: "assistant", id: root.currentAssistantId, text: root.lastAssistant, final: false })
        }
        break
      case "message_end":
        if (rec.message && rec.message.role === "user") {
          var ut = typeof rec.message.content === "string" ? rec.message.content : root.assistantText(rec.message)
          if (ut) root.emit({ t: "user", text: ut })
        } else if (rec.message && rec.message.role === "assistant") {
          var text = root.assistantText(rec.message)
          if (text) root.lastAssistant = text
          root.emit({ t: "assistant", id: root.currentAssistantId || ("a" + Date.now()), text: text, final: true })
          root.currentAssistantId = ""
          root.usage(rec.message.usage)
        }
        break
      case "tool_execution_start":
        root.toolArgs[rec.toolCallId] = rec.args || {}
        root.toolStart[rec.toolCallId] = Date.now()
        root.emit({ t: "step", id: rec.toolCallId, text: Api.toolLabel(rec.toolName, rec.args), ok: null, ms: 0 })
        break
      case "tool_execution_end":
        var args = root.toolArgs[rec.toolCallId] || {}
        var started = root.toolStart[rec.toolCallId] || Date.now()
        var ms = Date.now() - started
        var result = rec.result || {}
        var content = result.content || []
        var image = ""
        for (var i = 0; i < content.length; i++) {
          if (content[i] && content[i].type === "image" && content[i].data) image = "data:" + (content[i].mimeType || "image/png") + ";base64," + content[i].data
        }
        root.steps += 1
        if (rec.toolName === "phone_look" && image) {
          root.emit({ t: "look", id: rec.toolCallId, text: Api.toolLabel(rec.toolName, args), image: image })
        } else {
          var txt = Api.toolLabel(rec.toolName, args) + (result.details && result.details.app ? " · " + result.details.app : "")
          root.emit({ t: "step", id: rec.toolCallId, text: txt, ok: rec.isError !== true, ms: ms })
        }
        root.emit({ t: "usage", cost: root.cost, tokens: root.tokens, steps: root.steps })
        break
      case "extension_ui_request":
        if (rec.method === "confirm" || rec.method === "editor") {
          root.pending += 1
          root.emit({ t: "approval", kind: rec.method === "editor" ? "editor" : "confirm", id: rec.id, title: rec.title || "Approve?", message: rec.message || rec.prefill || "", prefill: rec.prefill || "" })
        } else if (rec.method === "select" || rec.method === "input") {
          // The panel surfaces confirm/editor dialogs; auto-cancel anything else so Pi never blocks.
          root.send({ type: "extension_ui_response", id: rec.id, cancelled: true })
          root.emit({ t: "status", text: (rec.title || "Prompt") + " — dismissed in the panel" })
        } else if (rec.method === "notify") {
          root.emit({ t: "status", text: rec.message || "" })
        }
        break
      case "extension_error":
        root.emit({ t: "error", text: rec.error || "extensions error" }); break
      case "entry_appended":
        if (rec.entry && rec.entry.customType === "phone-grant" && rec.entry.data && Array.isArray(rec.entry.data.grants))
          root.emit({ t: "grants", grants: rec.entry.data.grants })
        if (rec.entry && rec.entry.customType === "phone-post-audit") {
          var d = rec.entry.data || {}
          root.emit({ t: "receipt", at: d.at || "", app: d.app || "", where: d.where || "", text: d.text || "", outcome: d.outcome || "" })
          root.emit({ t: "status", text: (d.outcome === "posted_verified" ? "Posted to " : "Denied ") + (d.where || d.app || "post") })
        }
        break
      case "queue_update":
        root.emit({ t: "queued", count: (rec.steering || []).length + (rec.followUp || []).length }); break
      case "auto_retry_end":
        if (rec.success === false) root.emit({ t: "error", text: rec.finalError || "request failed" })
        break
      case "session_info_changed":
        root.emit({ t: "name", name: rec.name || "" }); break
    }
  }

  Process {
    id: proc
    stdinEnabled: true
    workingDirectory: root.agentRepo
    stdout: SplitParser {
      onRead: function(line) {
        var rec = null
        try { rec = JSON.parse(line) } catch (e) { return }
        root.handle(rec)
      }
    }
    // stderr is diagnostics only; keep it out of the timeline.
    stderr: SplitParser { onRead: function(line) { console.warn("pi[" + root.runtimeId + "]:", String(line)) } }
    onStarted: root.send({ id: "state", type: "get_state" })
    onExited: function(code) {
      root.streaming = false
      root.emit({ t: "exited", code: code })
    }
  }
}
