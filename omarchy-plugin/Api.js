.pragma library

// Presentation helpers for the Pi-driven iPhone agent panel.

function clean(value, limit) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\r\t]+/g, " ").slice(0, limit || 6000)
}

function oneLine(value, limit) {
  return clean(value, limit).replace(/\n+/g, " ")
}

function relTime(ms) {
  if (!ms) return ""
  var s = Math.max(0, Math.round((Date.now() - Number(ms)) / 1000))
  if (s < 45) return "just now"
  var m = Math.round(s / 60)
  if (m < 60) return m + "m ago"
  var h = Math.round(m / 60)
  if (h < 24) return h + "h ago"
  return Math.round(h / 24) + "d ago"
}

function duration(startMs, endMs) {
  if (!startMs) return ""
  var s = Math.max(0, Math.round(((endMs || Date.now()) - Number(startMs)) / 1000))
  var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60)
  if (h > 0) return h + "h " + m + "m"
  if (m > 0) return m + "m"
  return s + "s"
}

function money(value) {
  var n = Number(value || 0)
  if (!isFinite(n)) n = 0
  return "$" + n.toFixed(4)
}

// wda.json states -> panel presentation.
function phoneInfo(state) {
  switch (state) {
    case "ready":     return { tone: "good",   label: "iPhone ready",            hint: "Plugged in and listening" }
    case "starting":  return { tone: "idle",   label: "Connecting…",             hint: "Starting WebDriverAgent" }
    case "error":     return { tone: "urgent", label: "Phone link error",        hint: "Check the WDA service" }
    case "no_phone":  return { tone: "idle",   label: "Waiting for your iPhone", hint: "Plug it in — that is the whole setup" }
    default:          return { tone: "idle",   label: "Checking…",               hint: "" }
  }
}

function sessionInfo(state) {
  switch (state) {
    case "running":   return { tone: "live",   label: "Live" }
    case "waiting":   return { tone: "urgent", label: "Needs you" }
    case "queued":    return { tone: "idle",   label: "Queued" }
    case "idle":      return { tone: "idle",   label: "Idle" }
    case "ended":     return { tone: "off",    label: "Ended" }
    case "failed":    return { tone: "urgent", label: "Failed" }
    default:          return { tone: "idle",   label: state || "…" }
  }
}

// Friendly one-line label for a phone/other tool step.
function toolLabel(name, args) {
  args = args || {}
  switch (name) {
    case "phone_screen":  return "Read the screen"
    case "phone_tap":     return "Tapped ref " + (args.ref === undefined ? "?" : args.ref)
    case "phone_type":    return "Typed “" + oneLine(args.text, 70) + "”"
    case "phone_scroll":  return "Scrolled " + (args.direction || "")
    case "phone_open_app":return "Opened " + (args.name || "an app")
    case "phone_home":    return "Went Home"
    case "phone_back":    return "Went back"
    case "phone_look":    return "Looked at the screen"
    case "phone_post":    return "Posted to " + (args.where || args.app || "?")
    case "phone_watch":   return "Started watching " + (args.app || "")
    case "phone_unwatch": return "Stopped watching"
    default:              return (name || "step") + (args.command ? " · " + oneLine(args.command, 60) : "")
  }
}
