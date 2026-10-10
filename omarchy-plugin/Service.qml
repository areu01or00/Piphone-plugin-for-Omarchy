import QtQuick
import Quickshell
import Quickshell.Io
import "Api.js" as Api

// Owns Pi RPC sessions and the phone-link status. Lives with the shell so
// sessions survive the panel being closed. The panel binds to `revision`.
Item {
  id: root

  property var shell: null
  property bool panelOpen: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string agentRepo: Quickshell.env("IPHONE_AGENT_REPO") || (home + "/.config/omarchy/plugins/areu01or00.piphone")
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") + "/iphone-agent"
  readonly property string sessionDir: home + "/.local/share/iphone-agent/pi-sessions"
  readonly property string archiveDir: sessionDir + "/archive"
  readonly property string wdaPath: runtimeDir + "/wda.json"
  readonly property string appsPath: runtimeDir + "/apps.json"
  readonly property string uiStatePath: runtimeDir + "/ui-state.json"
  readonly property string modelPath: runtimeDir + "/model.json"
  readonly property string profilePath: home + "/.local/share/iphone-agent/profile.md"
  property string profileText: ""
  readonly property string terminalScript: agentRepo + "/bin/iphone-agent"

  property string phoneState: "no_phone"
  property string phoneMessage: "Waiting for your iPhone"
  property string provisionPath: Quickshell.env("IPHONE_AGENT_PROVISION") || (home + "/.local/share/iphone-agent/wda.mobileprovision")
  property string signatureExpiry: ""
  readonly property string expiryLabel: {
    if (!root.signatureExpiry) return ""
    var t = Date.parse(root.signatureExpiry)
    if (isNaN(t)) return ""
    var days = Math.floor((t - Date.now()) / 86400000)
    return days < 0 ? "WDA signature EXPIRED" : (days === 0 ? "WDA signature expires today" : "WDA signature expires in " + days + " day" + (days === 1 ? "" : "s"))
  }
  function renewSignature() {
    renewProc.command = ["bash", "-lc", root.agentRepo + "/wda/resign.sh >/dev/null 2>&1"]
    renewProc.running = true
    root.notify("WDA renew", "Run Impactor to renew the profile, then this will install it")
  }

  property var sessions: []
  property string selectedId: ""
  property int revision: 0
  property int needsYou: 0
  property bool showArchived: false
  readonly property bool phoneBusy: root.phoneOwner !== ""

  // Apps + models
  property var appsList: []
  property var models: []
  property var favourites: []
  property string defaultModel: "openrouter/deepseek/deepseek-v4.1-flash"
  property string lastModel: defaultModel
  property string lastThinking: "medium"
  property bool modelsLoaded: false

  readonly property var driverSession: {
    for (var i = 0; i < root.sessions.length; i++) if (root.sessions[i].runtimeId === root.phoneOwner) return root.sessions[i]
    return null
  }
  readonly property string driverName: root.driverSession ? (root.driverSession.name || root.driverSession.title || "the running session") : ""

  // ── Internal ──────────────────────────────────────────────────────────
  property var store: ({})
  property var events: ({})
  property var runtimeIds: []
  property var runtimeRefs: ({})
  property var runtimeToId: ({})
  property var pendingStart: ({})
  property var approvalOwner: ({})
  property var approvalKind: ({})
  property string phoneOwner: ""
  property int runtimeCounter: 0
  property int queueCounter: 0
  property string historyId: ""
  property string historyTarget: ""

  function now() { return Date.now() }
  function sessionFor(id) { return root.store[id] || null }
  function eventsFor(id) { return root.events[id] || [] }
  function findSessionByRuntime(rid) { for (var k in root.store) if (root.store[k].runtimeId === rid) return root.store[k]; return null }

  function blankSession(id, title, mode, opts) {
    opts = opts || {}
    return { id: id, file: "", title: title || "New session", name: "", state: "idle", mode: mode || "ask",
             model: opts.model || root.lastModel, thinking: opts.thinking || root.lastThinking,
             scope: (opts.apps || []).slice(), limits: opts.limits || ({ hour: 6, session: 20, cost: 0.5 }),
             cost: 0, tokens: 0, steps: 0, pending: 0, runtimeId: "", createdMs: now(), updatedAt: now(), order: 0 }
  }

  function commit() {
    var list = []
    for (var k in root.store) list.push(root.store[k])
    list.sort(function(a, b) { return (b.updatedAt || 0) - (a.updatedAt || 0) })
    root.sessions = list
    var n = 0
    for (var i = 0; i < list.length; i++) n += Number(list[i].pending || 0)
    root.needsYou = n
    root.revision += 1
    publish()
  }

  // ── Event ingestion ───────────────────────────────────────────────────
  function pushEvent(s, ev) {
    var arr = (root.events[s.id] || []).slice()
    var idx = -1
    if (ev.id) for (var i = arr.length - 1; i >= 0; i--) if (arr[i].id === ev.id) { idx = i; break }
    if (idx >= 0) arr[idx] = ev; else arr.push(ev)
    if (arr.length > 400) arr = arr.slice(arr.length - 400)
    root.events[s.id] = arr
  }
  function addUser(s, text) {
    var arr = root.events[s.id] || []
    var last = arr[arr.length - 1]
    if (last && last.kind === "user" && last.text === text) { s.lastUser = text; return }
    pushEvent(s, { kind: "user", text: text, at: now() }); s.lastUser = text
  }
  function recomputeState(s) {
    if (s.pending > 0) s.state = "waiting"
    else if (s.streaming) s.state = "running"
    else if (s.runtimeId) s.state = "idle"
    else s.state = s.state === "failed" || s.state === "budget" ? s.state : "ended"
  }

  function notify(title, body) {
    if (root.panelOpen) return
    notifyProc.command = ["bash", "-lc", "command -v notify-send >/dev/null && notify-send -a 'Piphone' \"$1\" \"$2\"", "_", title, body]
    notifyProc.running = true
  }

  function ingest(rid, rec) {
    var s = findSessionByRuntime(rid)
    if (!s) return
    switch (rec.t) {
      case "session": {
        if (rec.file && rec.file !== s.file) {
          var oldId = s.id
          delete root.store[oldId]
          s.file = rec.file; s.id = rec.file
          root.store[rec.file] = s
          root.runtimeToId[rid] = rec.file
          if (root.events[oldId]) { root.events[rec.file] = root.events[oldId]; delete root.events[oldId] }
          if (root.selectedId === oldId) root.selectedId = rec.file
        }
        if (rec.name) s.name = rec.name
        s.updatedAt = now(); commit(); break
      }
      case "user": addUser(s, rec.text); s.updatedAt = now(); commit(); break
      case "assistant": pushEvent(s, { kind: "agent", id: rec.id, text: rec.text, final: rec.final, at: now() }); s.updatedAt = now(); commit(); break
      case "step": pushEvent(s, { kind: "step", id: rec.id, text: rec.text, ok: rec.ok, ms: rec.ms, at: now() }); s.now = rec.text; s.updatedAt = now(); commit(); break
      case "receipt": s.receipts = (s.receipts || []).concat([{ at: rec.at, app: rec.app, where: rec.where, text: rec.text, outcome: rec.outcome }]); commit(); break
      case "grants": s.grants = rec.grants || []; s.updatedAt = now(); commit(); break
      case "look": pushEvent(s, { kind: "look", id: rec.id, text: rec.text, image: rec.image, at: now() }); s.updatedAt = now(); commit(); break
      case "approval":
        pushEvent(s, { kind: "approval", dialog: rec.kind || "confirm", id: rec.id, title: rec.title, message: rec.message, prefill: rec.prefill, decision: "", at: now() })
        root.approvalOwner[rec.id] = rid
        root.approvalKind[rec.id] = rec.kind || "confirm"
        s.pending += 1; recomputeState(s); s.updatedAt = now()
        root.notify("Needs you", (s.name || s.title || "Session") + " is waiting for approval")
        commit(); break
      case "approval-done": {
        var arr = (root.events[s.id] || []).slice()
        for (var i = 0; i < arr.length; i++) if (arr[i].id === rec.id) { var c = Object.assign({}, arr[i]); c.decision = rec.decision; arr[i] = c }
        root.events[s.id] = arr
        delete root.approvalOwner[rec.id]
        delete root.approvalKind[rec.id]
        if (s.pending > 0) s.pending -= 1
        recomputeState(s); s.updatedAt = now(); commit(); break
      }
      case "status": pushEvent(s, { kind: "status", text: rec.text, at: now() }); s.updatedAt = now(); commit(); break
      case "error": pushEvent(s, { kind: "error", text: rec.text, at: now() }); if (!s.streaming) s.state = "failed"; s.updatedAt = now(); root.notify("Session failed", (s.name || s.title || "Session")); commit(); break
      case "result": pushEvent(s, { kind: "result", text: rec.text, at: now() }); s.updatedAt = now(); commit(); break
      case "model": s.model = rec.model; s.thinking = rec.thinking; commit(); break
      case "streaming":
        s.streaming = rec.value; s.waitingForPhone = false
        if (rec.value) root.phoneOwner = rid
        else { if (root.phoneOwner === rid) root.phoneOwner = ""; root.drainQueue() }
        recomputeState(s); s.updatedAt = now()
        if (!rec.value && s.pending === 0 && s.state !== "failed") root.notify("Session finished", (s.name || s.title || "Session"))
        commit(); break
      case "usage":
        s.cost = rec.cost; s.tokens = rec.tokens; s.steps = rec.steps
        if (!s.budgetHit && s.limits && s.limits.cost > 0 && s.cost >= s.limits.cost) {
          s.budgetHit = true; s.state = "budget"
          pushEvent(s, { kind: "status", text: "Budget reached — stopped at $" + Number(s.cost).toFixed(4), at: now() })
          if (s.runtimeId && root.runtimeRefs[s.runtimeId]) root.runtimeRefs[s.runtimeId].abort()
          root.notify("Budget reached", (s.name || s.title || "Session") + " hit its cost cap")
        }
        commit(); break
      case "queued": s.queuedCount = rec.count; commit(); break
      case "name": s.name = rec.name; commit(); break
      case "exited": {
        s.runtimeId = ""
        if (root.phoneOwner === rid) root.phoneOwner = ""
        if (!s.streaming && s.state === "running") s.state = s.pending > 0 ? "waiting" : "failed"
        else recomputeState(s)
        removeRuntime(rid); s.updatedAt = now(); commit(); root.drainQueue(); break
      }
    }
  }

  function runtimeReady(rid, item) {
    root.runtimeRefs[rid] = item
    var r = {}; for (var k in root.runtimeRefs) r[k] = root.runtimeRefs[k]; root.runtimeRefs = r
    var start = root.pendingStart[rid]
    if (start) {
      delete root.pendingStart[rid]
      item.mode = start.mode
      item.model = start.model
      item.thinking = start.thinking
      item.startCommands = start.commands || []
      item.start(start.prompt)
    }
  }
  function removeRuntime(rid) {
    var next = []
    for (var i = 0; i < root.runtimeIds.length; i++) if (root.runtimeIds[i] !== rid) next.push(root.runtimeIds[i])
    root.runtimeIds = next
    var r = {}; for (var k in root.runtimeRefs) if (k !== rid) r[k] = root.runtimeRefs[k]; root.runtimeRefs = r
  }
  function spawn(rid, session, prompt, opts) {
    opts = opts || {}
    session.runtimeId = rid
    root.runtimeToId[rid] = session.id
    root.pendingStart[rid] = { prompt: prompt || "", mode: session.mode, model: session.model, thinking: session.thinking, commands: opts.commands || [] }
    root.runtimeIds = root.runtimeIds.concat([rid])
  }
  function scopeCommands(s) { return ["/phone-scope " + (s.scope || []).join(","), "/phone-limits " + ((s.limits || {}).hour || 6) + " " + ((s.limits || {}).session || 20), "/phone-mode " + (s.mode || "ask")] }

  // ── Phone gate ────────────────────────────────────────────────────────
  function startSession(s, prompt) {
    if (prompt) s.lastUser = prompt
    var rt = s.runtimeId ? root.runtimeRefs[s.runtimeId] : null
    if (!rt && root.phoneOwner && root.phoneOwner !== s.runtimeId) {
      s.state = "queued"; s.waitingForPhone = true; s.queuedPrompt = prompt || ""
      if (!s.order) s.order = ++root.queueCounter
      s.updatedAt = now(); commit(); return
    }
    if (!rt) {
      var rid = "r" + (++root.runtimeCounter)
      root.phoneOwner = rid
      spawn(rid, s, prompt || "", { commands: scopeCommands(s) })
      s.state = "running"; s.waitingForPhone = false
    } else {
      rt.mode = s.mode
      if (s.streaming) { rt.steer(prompt || "") } else { rt.prompt(prompt || "") }
      s.state = "running"; s.waitingForPhone = false
    }
    s.updatedAt = now(); commit()
  }
  function drainQueue() {
    if (root.phoneOwner) return
    var list = root.sessions.slice().filter(function(x){ return x.state === "queued" }).sort(function(a, b) { return (a.order || 0) - (b.order || 0) })
    if (list.length === 0) return
    var s = list[0]
    var p = s.queuedPrompt || ""
    s.queuedPrompt = ""; s.order = 0
    startSession(s, p)
  }
  function moveUp(id) {
    var q = root.sessions.filter(function(x){ return x.state === "queued" }).sort(function(a, b){ return (a.order||0)-(b.order||0) })
    var i = -1
    for (var k = 0; k < q.length; k++) if (q[k].id === id) { i = k; break }
    if (i > 0) { var tmp = q[i].order; q[i].order = q[i-1].order; q[i-1].order = tmp }
    commit()
  }
  function cancelQueued(id) {
    var s = root.store[id]
    if (!s || s.state !== "queued") return
    s.state = "ended"; s.waitingForPhone = false; s.order = 0; s.updatedAt = now(); commit()
  }
  function queuePosition(id) {
    var q = root.sessions.filter(function(x){ return x.state === "queued" }).sort(function(a, b){ return (a.order||0)-(b.order||0) })
    for (var k = 0; k < q.length; k++) if (q[k].id === id) return k + 1
    return 0
  }

  // ── Public API ────────────────────────────────────────────────────────
  function select(id) { root.selectedId = id; root.revision += 1; loadHistory(id) }

  function createSession(opts) {
    var id = "pending-" + (++root.runtimeCounter)
    var s = blankSession(id, opts.goal, opts.mode, opts)
    s.lastUser = opts.goal
    root.store[id] = s
    root.events[id] = []
    root.selectedId = id
    root.lastModel = s.model; root.lastThinking = s.thinking; saveModel()
    startSession(s, opts.goal)
    commit()
    return id
  }
  function send(text) {
    var s = sessionFor(root.selectedId)
    if (!s || !text) return
    addUser(s, text); s.updatedAt = now(); commit()
    var rt = s.runtimeId ? root.runtimeRefs[s.runtimeId] : null
    if (!rt) { startSession(s, text); return }
    if (root.phoneOwner && root.phoneOwner !== s.runtimeId) {
      s.state = "queued"; s.waitingForPhone = true; s.queuedPrompt = text
      if (!s.order) s.order = ++root.queueCounter
      commit(); return
    }
    rt.mode = s.mode
    if (s.streaming) { rt.steer(text) } else { rt.prompt(text) }
  }
  function abort() { var s = sessionFor(root.selectedId); if (s && s.runtimeId && root.runtimeRefs[s.runtimeId]) root.runtimeRefs[s.runtimeId].abort() }
  function retry() { var s = sessionFor(root.selectedId); if (s) startSession(s, s.lastUser || s.title || "") }
  function setMode(mode) {
    var s = sessionFor(root.selectedId); if (!s) return
    s.mode = mode
    if (s.runtimeId && root.runtimeRefs[s.runtimeId]) root.runtimeRefs[s.runtimeId].setMode(mode)
    commit()
  }
  function setModel(id, model, thinking) {
    var s = root.store[id] || sessionFor(root.selectedId); if (!s) return
    s.model = model; s.thinking = thinking
    root.lastModel = model; root.lastThinking = thinking; saveModel()
    if (s.runtimeId && root.runtimeRefs[s.runtimeId]) root.runtimeRefs[s.runtimeId].applyModel(model, thinking)
    commit()
  }
  function setScope(id, apps) {
    var s = root.store[id] || sessionFor(root.selectedId); if (!s) return
    s.scope = apps.slice()
    if (s.runtimeId && root.runtimeRefs[s.runtimeId]) root.runtimeRefs[s.runtimeId].send({ type: "prompt", message: "/phone-scope " + s.scope.join(",") })
    commit()
  }
  function setLimits(id, limits) {
    var s = root.store[id] || sessionFor(root.selectedId); if (!s) return
    s.limits = limits
    if (s.runtimeId && root.runtimeRefs[s.runtimeId]) root.runtimeRefs[s.runtimeId].send({ type: "prompt", message: "/phone-limits " + limits.hour + " " + limits.session })
    commit()
  }
  function answer(id, value) {
    var rid = root.approvalOwner[id]
    var rt = rid ? root.runtimeRefs[rid] : null
    if (!rt) {
      var s = sessionFor(root.selectedId)
      if (s && s.runtimeId) rt = root.runtimeRefs[s.runtimeId]
    }
    if (!rt) return
    if (root.approvalKind[id] === "confirm") rt.answer(id, value === true)
    else rt.answerEditor(id, value)
  }
  function grant(id, app, where) {
    var s = root.store[id] || sessionFor(root.selectedId)
    if (s && s.runtimeId && root.runtimeRefs[s.runtimeId]) root.runtimeRefs[s.runtimeId].send({ type: "prompt", message: "/phone-grant 30|" + app + "|" + (where || "") })
  }
  function revokeGrants(id) {
    var s = root.store[id] || sessionFor(root.selectedId)
    if (s && s.runtimeId && root.runtimeRefs[s.runtimeId]) root.runtimeRefs[s.runtimeId].send({ type: "prompt", message: "/phone-revoke" })
  }
  function approveAll(id) {
    var s = root.store[id] || sessionFor(root.selectedId)
    if (!s) return
    var evs = root.events[s.id] || []
    for (var i = 0; i < evs.length; i++) {
      var ev = evs[i]
      if (ev.kind !== "approval" || ev.decision) continue
      root.answer(ev.id, ev.dialog === "editor" ? (ev.prefill || ev.message || "") : true)
    }
  }
  function rename(id, name) {
    var s = root.store[id]; if (!s) return
    s.name = name
    if (s.runtimeId && root.runtimeRefs[s.runtimeId]) root.runtimeRefs[s.runtimeId].send({ type: "set_session_name", name: name })
    commit()
  }
  function archiveSession(id) {
    var s = root.store[id]; if (!s || !s.file) return
    archiveProc.command = ["bash", "-lc", 'mkdir -p "$1" && mv "$2" "$1/" 2>/dev/null || true', "_", root.archiveDir, s.file]
    archiveProc.running = true
    s.archived = true; s.updatedAt = now(); commit()
  }
  function unarchiveSession(id) {
    var s = root.store[id]; if (!s || !s.file) return
    var base = s.file.substring(s.file.lastIndexOf("/") + 1)
    archiveProc.command = ["bash", "-lc", 'mv "$1" "$2" 2>/dev/null || true', "_", s.file, root.sessionDir + "/" + base]
    archiveProc.running = true
    s.archived = false; s.updatedAt = now(); commit()
  }
  function deleteSession(id) {
    var s = root.store[id]; if (!s) return
    if (s.file) { deleteProc.command = ["bash", "-lc", 'rm -f "$1"', "_", s.file]; deleteProc.running = true }
    delete root.store[id]; delete root.events[id]
    if (root.selectedId === id) root.selectedId = ""
    commit()
  }
  function openTerminal() { Quickshell.execDetached(["uwsm-app", "--", "foot", "--app-id=TUI.float", "-e", root.terminalScript]) }

  function phoneAction(action) {
    if (root.phoneBusy || root.phoneState !== "ready") return
    if (action === "home") {
      actionProc.command = ["bash", "-lc", root.agentRepo + "/bin/phone home >/dev/null 2>&1"]
    } else if (action === "screenshot") {
      actionProc.command = ["bash", "-lc", 'mkdir -p "$1" && curl -s --max-time 10 --unix-socket "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/iphone-agent/wda.sock" http://localhost/screenshot | jq -r .value | base64 -d > "$1/iPhone-$(date +%Y%m%d-%H%M%S).png"', "_", root.home + "/Pictures"]
    } else if (action === "mirror") {
      actionProc.command = ["bash", "-lc", "systemctl --user is-active iphone-wdad.service >/dev/null || systemctl --user start iphone-wdad.service"]
    } else return
    actionProc.running = true
  }

  // ── Models ────────────────────────────────────────────────────────────
  function parseModels(txt) {
    var lines = String(txt || "").split("\n"), out = []
    for (var i = 0; i < lines.length; i++) {
      var p = lines[i].trim().split(/\s+/)
      if (p.length < 6 || p[0] === "provider") continue
      out.push({ provider: p[0], id: p[0] + "/" + p[1], label: p[1], thinking: p[4] === "yes", images: p[5] === "yes" })
    }
    root.models = out
    root.computeFavourites()
    root.modelsLoaded = out.length > 0
  }
  function computeFavourites() {
    var wants = ["deepseek-v4.1-flash", "deepseek", "claude", "gpt", "gemini", "kimi"]
    var favs = [], seen = ({})
    for (var w = 0; w < wants.length; w++) {
      for (var i = 0; i < root.models.length; i++) {
        var m = root.models[i]
        if (String(m.id).indexOf(wants[w]) >= 0 && !seen[m.id]) { favs.push(m.id); seen[m.id] = true; break }
      }
    }
    if (!seen[root.defaultModel]) for (var j = 0; j < root.models.length; j++) if (root.models[j].id === root.defaultModel) { favs.unshift(root.defaultModel); break }
    root.favourites = favs
    var known = ({})
    for (var k = 0; k < root.models.length; k++) known[root.models[k].id] = true
    if (!known[root.lastModel]) root.lastModel = root.favourites[0] || root.defaultModel
  }
  function applyModelFile(raw) {
    try {
      var d = JSON.parse(raw || "{}")
      if (d.model) root.lastModel = String(d.model)
      if (d.thinking) root.lastThinking = String(d.thinking)
    } catch (e) {}
  }
  function saveModel() {
    modelWriter.command = ["bash", "-c", "printf %s \"$1\" > \"$2\"", "_", JSON.stringify({ model: root.lastModel, thinking: root.lastThinking }), root.modelPath]
    modelWriter.running = true
  }

  // ── Session listing ───────────────────────────────────────────────────
  function refresh() { if (!listProc.running) listProc.running = true }
  function applyListing(output) {
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i]) continue
      var p = lines[i].split("\t")
      if (p.length < 6) continue
      var mt = Number(p[0]) * 1000, file = p[1], name = p[2], title = p[3], model = p[4], thinking = p[5]
      var archived = file.indexOf("/archive/") >= 0
      if (root.store[file]) {
        if (name) root.store[file].name = name
        if (model) root.store[file].model = model
        if (thinking) root.store[file].thinking = thinking
        root.store[file].updatedAt = Math.max(root.store[file].updatedAt || 0, mt)
        root.store[file].file = file; root.store[file].archived = archived
        if (!root.store[file].title || root.store[file].title === "New session") root.store[file].title = title || "Session"
      } else {
        var s = blankSession(file, title || "Session", "ask", { model: model || root.lastModel, thinking: thinking || root.lastThinking })
        s.file = file; s.name = name; s.updatedAt = mt; s.createdMs = mt; s.state = "ended"; s.archived = archived
        root.store[file] = s
      }
    }
    commit()
  }

  function applyApps(raw) {
    try { root.appsList = JSON.parse(raw || "[]") } catch (e) { root.appsList = [] }
  }

  // ── History ───────────────────────────────────────────────────────────
  function unescapeTsv(x) { return String(x === undefined ? "" : x).replace(/\\n/g, "\n").replace(/\\t/g, "\t").replace(/\\r/g, "").replace(/\\\\/g, "\\") }
  function parseArgsRaw(x) { try { return JSON.parse(x) } catch (e) { return ({}) } }
  function loadHistory(id) {
    var s = root.store[id]
    if (!s || !s.file) return
    if (s.runtimeId && root.runtimeRefs[s.runtimeId]) return
    root.historyId = id; root.historyTarget = s.file
    if (!historyProc.running) historyProc.running = true
  }
  function applyHistory(output) {
    var id = root.historyId, s = root.store[id]
    if (!s) return
    var evs = [], callIndex = ({}), cost = 0
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i]) continue
      var p = lines[i].split("\t")
      if (p[0] === "mode") { s.mode = p[1] === "auto" ? "auto" : "ask"; continue }
      if (p[0] === "scope") { s.scope = (p[1] || "").split(",").filter(function(x){return x}); continue }
      if (p[0] === "limits") { s.limits = { hour: +p[1] || 6, session: +p[2] || 20, cost: s.limits ? s.limits.cost : 0.5 }; continue }
      if (p[0] === "model") { if (p[1]) s.model = p[1]; if (p[2]) s.thinking = p[2]; continue }
      if (p[0] === "usage") { cost += Number(p[1]) || 0; continue }
      if (p[0] === "user") { evs.push({ kind: "user", text: root.unescapeTsv(p[1]), at: s.updatedAt }); continue }
      if (p[0] === "agent") { evs.push({ kind: "agent", text: root.unescapeTsv(p[1]), final: true, at: s.updatedAt }); continue }
      if (p[0] === "call") { callIndex[p[1]] = evs.length; evs.push({ kind: "step", id: p[1], text: Api.toolLabel(p[2], root.parseArgsRaw(p[3])), ok: null, ms: 0, at: s.updatedAt }); continue }
      if (p[0] === "callres") { var idx = callIndex[p[1]]; if (idx !== undefined) evs[idx] = Object.assign({}, evs[idx], { ok: p[2] === "1" }); continue }
      if (p[0] === "receipt") { s.receipts = (s.receipts || []).concat([{ at: p[1], app: p[2], where: p[3], outcome: p[4], text: root.unescapeTsv(p[5]) }]); continue }
      if (p[0] === "grants") { try { s.grants = JSON.parse(p[1] || "[]") } catch (e) { s.grants = [] } continue }
    }
    root.events[id] = evs
    var n = 0, lastStep = ""
    for (var j = 0; j < evs.length; j++) if (evs[j].kind === "step") { n++; lastStep = evs[j].text }
    if (n > 0 && !s.steps) s.steps = n
    if (lastStep) s.now = lastStep
    if (cost > (s.cost || 0)) s.cost = cost
    commit()
  }

  // ── Phone status ──────────────────────────────────────────────────────
  function applyWda(raw) {
    try {
      var d = JSON.parse(raw || "{}")
      root.phoneState = String(d.state || "no_phone")
      root.phoneMessage = Api.phoneInfo(root.phoneState).hint
    } catch (e) { root.phoneState = "no_phone"; root.phoneMessage = "connect an iPhone by USB" }
    publish()
  }

  property string pendingState: "{}"
  function publish() {
    root.pendingState = JSON.stringify({ state: root.phoneState, message: root.phoneMessage, needsYou: root.needsYou, running: root.phoneBusy, sessions: root.sessions.length })
    if (!stateWriter.running) stateWriter.running = true
  }

  // ── Processes ─────────────────────────────────────────────────────────
  FileView { id: wdaFile; path: root.wdaPath; watchChanges: true; atomicWrites: true; printErrors: false; onLoaded: root.applyWda(text()); onFileChanged: reload() }
  FileView { id: appsFile; path: root.appsPath; watchChanges: true; atomicWrites: true; printErrors: false; onLoaded: root.applyApps(text()); onFileChanged: reload() }
  FileView { id: modelFile; path: root.modelPath; watchChanges: false; printErrors: false; onLoaded: root.applyModelFile(text()) }
  FileView { id: profileFile; path: root.profilePath; watchChanges: true; atomicWrites: true; printErrors: false; onLoaded: root.profileText = text(); onFileChanged: reload() }

  function saveProfile(text) {
    root.profileText = String(text)
    // Private memory: never put the profile in argv (visible in `ps` to other
    // users). Pipe it through stdin, and keep the dir/file owner-only (0700/0600),
    // repairing perms if the file pre-existed with a looser mask.
    profileWriter.command = ["bash", "-c", 'f="$1"; d=$(dirname "$f"); mkdir -p "$d"; chmod 700 "$d" 2>/dev/null; umask 177; cat > "$f"; chmod 600 "$f"', "_", root.profilePath]
    if (!profileWriter.running) profileWriter.running = true
  }

  Process { id: stateWriter; command: ["bash", "-c", "printf %s \"$1\" > \"$2\"", "_", root.pendingState, root.uiStatePath] }
  Process { id: modelWriter; command: [] }
  Process { id: profileWriter; command: []; stdinEnabled: true; onStarted: { write(root.profileText); stdinEnabled = false } }
  Process { id: notifyProc; command: [] }
  Process { id: actionProc; command: [] }
  Process { id: archiveProc; command: [] }
  Process {
    id: expiryProc
    command: ["bash", "-lc", 'f="$1"; [ -f "$f" ] || exit 0; openssl smime -inform der -verify -noverify -in "$f" 2>/dev/null | grep -A1 -i ExpirationDate | grep -oE "<date>[^<]+" | head -1 | cut -c7-', "_", root.provisionPath]
    stdout: StdioCollector { id: expiryOut; waitForEnd: true }
    onExited: root.signatureExpiry = expiryOut.text.trim()
  }
  Process { id: renewProc; command: [] }
  Process { id: deleteProc; command: [] }

  Process {
    id: modelsProc
    command: [root.home + "/.local/share/mise/installs/pi/latest/pi/pi", "--list-models"]
    stdout: StdioCollector { id: modelsOut; waitForEnd: true }
    onExited: root.parseModels(modelsOut.text)
  }

  Process {
    id: historyProc
    command: ["bash", "-lc", 'jq -rc \'if .type=="custom" and .customType=="phone-mode" then ["mode", (.data.mode // "ask")] elif .type=="custom" and .customType=="phone-scope" then ["scope", ((.data.apps // [])|join(","))] elif .type=="custom" and .customType=="phone-limits" then ["limits", (.data.maxHour|tostring), (.data.maxSession|tostring)] elif .type=="custom" and .customType=="phone-grant" then ["grants", ((.data.grants // [])|tojson)] elif .type=="custom" and .customType=="phone-post-audit" then ["receipt", (.data.at // ""), (.data.app // ""), (.data.where // ""), (.data.outcome // ""), (.data.text // "")] elif .type=="model_change" then ["model", ((.provider // "") + "/" + (.modelId // ""))] elif .type=="message" then (.message | if .role=="user" then ["user", ((.content|if type=="string" then . else (map(.text//"")|join("\\n\\n")) end)|tostring)] elif .role=="assistant" then (["usage", ((.usage.cost.total // 0)|tostring)], ((.content // [])[] | if .type=="text" then ["agent", .text] elif .type=="toolCall" then ["call", .id, .name, (.arguments|tostring)] else empty end)) elif .role=="toolResult" then ["callres", .toolCallId, (if .isError then "0" else "1" end), ""] else empty end) else empty end | @tsv\' "$1"', "_", root.historyTarget]
    stdout: StdioCollector { id: histOut; waitForEnd: true }
    onExited: root.applyHistory(histOut.text)
  }

  Process {
    id: listProc
    command: ["bash", "-lc", 'd="$HOME/.local/share/iphone-agent/pi-sessions"; [ -d "$d" ] || exit 0; for f in "$d"/*.jsonl "$d"/archive/*.jsonl; do [ -e "$f" ] || continue; mt=$(stat -c %Y "$f"); name=$(jq -r \'select(.type=="session_info")|.name // empty\' "$f" 2>/dev/null | tail -1); title=$(jq -r \'select(.type=="message" and .message.role=="user") | (.message.content | if type=="string" then . else (map(.text//"")|join(" ")) end)\' "$f" 2>/dev/null | head -1 | head -c 140 | tr "\\n\\t" "  "); model=$(jq -r \'select(.type=="model_change")|((.provider // "") + "/" + (.modelId // ""))\' "$f" 2>/dev/null | tail -1); printf "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n" "$mt" "$f" "$name" "$title" "$model" ""; done | sort -rn | head -80']
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    onExited: root.applyListing(listOut.text)
  }

  Timer { interval: 2500; running: true; repeat: true; onTriggered: root.refresh() }
  Component.onCompleted: { root.refresh(); root.publish(); modelsProc.running = true; expiryProc.running = true }

  Repeater {
    model: root.runtimeIds
    delegate: SessionRuntime {
      required property var modelData
      runtimeId: modelData
      service: root
      file: root.runtimeToId[modelData] ? (root.store[root.runtimeToId[modelData]].file || "") : ""
      Component.onCompleted: root.runtimeReady(modelData, this)
    }
  }
}
