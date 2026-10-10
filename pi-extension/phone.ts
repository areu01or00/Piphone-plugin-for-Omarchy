import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { appendFile, chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { promisify } from "node:util";
import { WdaClient, assertSafeTap, checkAutoLimits, elementKey, guardedPost, hardPolicy, newLabels, type Snapshot } from "./phone-core.ts";

const run = promisify(execFile);
const home = process.env.HOME || "";
const runtime = () => `${process.env.XDG_RUNTIME_DIR || `/run/user/${process.getuid()}`}/iphone-agent`;
const dataDir = `${home}/.local/share/iphone-agent`;
const profilePath = `${dataDir}/profile.md`;
const builtin: Record<string, string> = {
  x: "com.atebits.Tweetie2", twitter: "com.atebits.Tweetie2", discord: "com.hammerandchisel.discord",
  linkedin: "com.linkedin.LinkedIn", settings: "com.apple.Preferences", messages: "com.apple.MobileSMS",
  safari: "com.apple.mobilesafari", mail: "com.apple.mobilemail", files: "com.apple.DocumentsApp",
  whatsapp: "net.whatsapp.WhatsApp", photos: "com.apple.mobileslideshow", camera: "com.apple.camera",
};
const playbookFor: Record<string, string> = {
  "com.hammerandchisel.discord": "discord", "com.atebits.Tweetie2": "x",
  "com.linkedin.LinkedIn": "linkedin", "com.apple.DocumentsApp": "files",
};
const client = new WdaClient();
const clean = (s: Snapshot) => ({ app: s.app, fingerprint: s.fingerprint, outline: s.outline });
const textResult = (v: any) => ({ content: [{ type: "text" as const, text: typeof v === "string" ? v : JSON.stringify(v) }], details: v });

export default function phoneExtension(pi: ExtensionAPI) {
  let mode: "ask" | "auto" = "ask", scope: string[] = [], maxHour = 6, maxSession = 20;
  let grants: { app: string; where: string; until: number }[] = [];
  const activeGrant = (app: string, where: string) => grants.find(g => g.until > Date.now() && g.app.toLowerCase() === String(app).toLowerCase() && g.where.toLowerCase() === String(where).toLowerCase());
  // A timeboxed grant auto-approves a post only when it is bound to device
  // ground truth, never to caller-supplied strings: the live foreground app
  // must BE the granted app, and the granted destination must actually appear
  // on the snapshot the send target was taken from. An agent therefore cannot
  // reuse a granted app/where name while the refs post into a different app or
  // destination — anything we cannot positively confirm falls through to the
  // normal approval card (the safe direction).
  const grantHonored = async (p: any): Promise<boolean> => {
    if (!activeGrant(p.app, p.where)) return false;
    const grantBundle = await resolveBundle(String(p.app));
    if (!grantBundle || grantBundle !== await client.activeApp()) return false;  // granted app is not foreground
    const where = String(p.where || "").trim().toLowerCase();
    if (!where) return true;                                   // empty where = any destination within the app
    const snap = client.latest;                               // the snapshot the send_ref/field_ref came from
    const hay = snap ? snap.elements.map(e => `${e.label} ${e.value}`).join("\n").toLowerCase() : "";
    return hay.includes(where);                                // the named destination must be on that live screen
  };
  const reasonFor = (p: any) => p.intent || (p.reply_to ? `replying to ${p.reply_to.author}` : `posting to ${p.where || p.app}`);
  let busy = false, timer: NodeJS.Timeout | undefined, watched: { app: string; bundle: string; previous: Snapshot } | undefined;
  const hourlyPosts: number[] = [];
  let sessionPosts = 0;
  let appIndex: { byName: Map<string, string>; byBundle: Map<string, string> } | undefined;
  const injectedPlaybooks = new Set<string>();
  let lastKeys = new Set<string>();
  let noChangeStreak = 0;

  async function loadApps() {
    if (appIndex) return appIndex;
    const byName = new Map(Object.entries(builtin));
    const byBundle = new Map(Object.entries(builtin).map(([k, v]) => [v, k]));
    try {
      const rows = JSON.parse(await readFile(`${runtime()}/apps.json`, "utf8"));
      for (const row of rows) {
        if (!row?.name || !row?.bundle) continue;
        byName.set(String(row.name).toLowerCase(), String(row.bundle));
        byBundle.set(String(row.bundle), String(row.name));
      }
    } catch { /* apps.json appears once WDA is ready */ }
    appIndex = { byName, byBundle };
    return appIndex;
  }
  async function resolveBundle(name: string) { return (await loadApps()).byName.get(name.trim().toLowerCase()); }
  async function allowedBundles() {
    if (scope.length === 0) return null;
    const { byName } = await loadApps();
    const set = new Set<string>();
    for (const n of scope) { const b = byName.get(n.toLowerCase()); if (b) set.add(b); }
    return set;
  }
  async function scopeError(bundle: string): Promise<string | undefined> {
    if (scope.length === 0 || bundle === "com.apple.springboard") return undefined;
    const allowed = await allowedBundles();
    if (allowed && allowed.has(bundle)) return undefined;
    const { byBundle } = await loadApps();
    return `left scope (now in ${byBundle.get(bundle) || bundle}); allowed apps: ${scope.join(", ")}. Use phone_open_app to return.`;
  }
  async function playbook(bundle: string): Promise<string | undefined> {
    const key = playbookFor[bundle];
    if (!key || injectedPlaybooks.has(key)) return undefined;
    try { const text = (await readFile(`${import.meta.dirname}/playbooks/${key}.md`, "utf8")).trim(); injectedPlaybooks.add(key); return text; }
    catch { return undefined; }
  }
  // Every action result: enforce app scope FIRST — an out-of-scope screen is
  // refused outright (its outline is never returned to the model), not sent
  // with a warning — then change line (loop-breaker) + optional playbook.
  async function scoped(s: Snapshot, extra: any = {}, isAction = false) {
    const err = await scopeError(s.app);
    if (err) { lastKeys = new Set(); noChangeStreak = 0; return textResult({ scope_error: err, app: s.app, outline_withheld: true }); }
    const keys = new Set(s.elements.map(elementKey));
    let added = 0, removed = 0;
    for (const k of keys) if (!lastKeys.has(k)) added++;
    for (const k of lastKeys) if (!keys.has(k)) removed++;
    const changed = added > 0 || removed > 0;
    if (isAction) { if (changed) noChangeStreak = 0; else noChangeStreak++; }
    lastKeys = keys;
    const payload: any = { changed, change_line: changed ? `Changed: yes (+${added} / −${removed} elements)` : "Changed: NO — the action had no visible effect; change approach or ask the user", ...extra, ...clean(s) };
    if (isAction && noChangeStreak >= 2) payload.loop_warning = `No visible change after ${noChangeStreak} actions. Stop retrying this goal; change approach or ask the user.`;
    const pb = await playbook(s.app); if (pb) payload.playbook = pb;
    return textResult(payload);
  }
  // Refuse to act unless the LIVE foreground app is in scope. Querying the real
  // device (not the cached snapshot) closes the window where the phone switches
  // apps after an allowed read — or during a posting-approval wait — before the
  // action lands. Unknown/undeterminable foreground is refused, not allowed.
  const assertInScope = async () => {
    if (scope.length === 0) return;                 // unrestricted session
    const err = await scopeError(await client.activeApp());
    if (err) throw new Error(err);
  };

  pi.on("agent_start", () => { busy = true; });
  pi.on("agent_end", () => { busy = false; });
  pi.on("session_shutdown", () => { if (timer) clearInterval(timer); });

  // Model-agnostic context budget. Pi only auto-compacts near the model's window (1M for
  // DeepSeek Flash), so a long delegation session otherwise re-sends 100k+ tokens every turn.
  const budget = +(process.env.IPHONE_CONTEXT_BUDGET || 60000);
  let compacting = false;
  pi.on("turn_end", (_event, ctx) => {
    const tokens = ctx.getContextUsage()?.tokens;
    if (compacting || !tokens || tokens <= budget) return;
    compacting = true;
    ctx.compact({
      customInstructions: "Keep: the user's mandate and every instruction since, profile facts, approvals/denials and grants, every post made (app, where, exact text), the current app and screen state, open to-dos and blockers. Drop old screen outlines and screenshots.",
      onComplete: () => { compacting = false; },
      onError: () => { compacting = false; },
    });
  });
  // Restore per-session settings from custom entries so a resumed session keeps them.
  pi.on("session_start", async (_event, ctx) => {
    try {
      for (const entry of ctx.sessionManager.getBranch()) {
        const e = entry as any;
        if (e.type !== "custom" || !e.data) continue;
        if (e.customType === "phone-mode" && (e.data.mode === "ask" || e.data.mode === "auto")) mode = e.data.mode;
        if (e.customType === "phone-scope" && Array.isArray(e.data.apps)) scope = e.data.apps.map(String);
        if (e.customType === "phone-limits") { maxHour = +e.data.maxHour || maxHour; maxSession = +e.data.maxSession || maxSession; }
        if (e.customType === "phone-grant" && Array.isArray(e.data.grants)) grants = e.data.grants.map((g: any) => ({ app: String(g.app), where: String(g.where), until: +g.until || 0 }));
      }
    } catch { /* no branch yet */ }
  });
  // Keep cost flat: only the newest image and the newest full outline reach the model; older screens become a stub.
  pi.on("context", event => {
    const messages = event.messages as any[];
    let newestLook = -1; const outlineIndices: number[] = [];
    messages.forEach((m, i) => {
      if (m.role !== "toolResult") return;
      if (m.toolName === "phone_look") newestLook = i;
      if (typeof m.toolName === "string" && m.toolName.startsWith("phone_") && Array.isArray(m.content)
        && m.content.some((c: any) => c.type === "text" && typeof c.text === "string" && c.text.includes('"outline"'))) outlineIndices.push(i);
    });
    const newestOutline = outlineIndices.at(-1) ?? -1;
    return { messages: messages.map((m, i) => {
      if (m.role !== "toolResult") return m;
      let content: any[] = m.content;
      if (m.toolName === "phone_look" && i < newestLook) content = content.filter((c: any) => c.type !== "image");
      if (i < newestOutline && outlineIndices.includes(i)) content = content.map((c: any) => {
        if (c.type !== "text" || typeof c.text !== "string") return c;
        try { const v = JSON.parse(c.text); if (v && typeof v === "object" && "outline" in v) return { ...c, text: JSON.stringify({ ...v, outline: `[older screen omitted; fingerprint ${v.fingerprint}]` }) }; } catch {}
        return c;
      });
      return content === m.content ? m : { ...m, content };
    }) };
  });
  pi.on("before_agent_start", async event => {
    let profile = "";
    try { profile = (await readFile(profilePath, "utf8")).trim(); } catch { /* no profile yet */ }
    const rules = `\n\nIPHONE: Observe with phone_screen, then act only by current numeric ref. Every action returns a fresh outline and a "Changed:" line: if it says NO, change approach instead of retrying. Use phone_look only when labels are insufficient. Never use phone_tap to send or perform an outward/destructive action; use phone_post for text. Call phone tools sequentially.${scope.length ? ` Stay inside your app scope: ${scope.join(", ")}.` : ""} If blocked or uncertain, ask the user.`;
    const laptop = `\n\nYou run on the user's laptop. Prefer laptop files and web search (bash/curl) over digging through the phone when the phone isn't required.`;
    const monitor = `\n\nMONITORING: for long mandates (handle my Discord, watch X, catch me up), first post a 3–5 line plan with phone_plan and wait for approval once. Then use phone_watch so you sleep between events instead of polling; never busy-loop phone_screen. Post/relay only through phone_post.`;
    const profileBlock = profile ? `\n\nUSER PROFILE (keep it accurate; add facts with the remember tool):\n${profile}` : "";
    return { systemPrompt: event.systemPrompt + rules + laptop + monitor + profileBlock };
  });

  pi.registerCommand("phone-mode", {
    description: "Set outward posting policy: ask or auto",
    handler: async (arg, ctx) => {
      const next = arg.trim();
      if (next !== "ask" && next !== "auto") return void ctx.ui.notify("usage: /phone-mode ask|auto", "error");
      mode = next; ctx.ui.notify(`Phone mode: ${mode}`, "info");
      pi.appendEntry("phone-mode", { mode, at: new Date().toISOString() });
    },
  });
  pi.registerCommand("phone-scope", {
    description: "Restrict the agent to a comma-separated list of apps (empty = unrestricted)",
    handler: async (arg, ctx) => {
      scope = arg.split(",").map(s => s.trim()).filter(Boolean);
      pi.appendEntry("phone-scope", { apps: scope });
      ctx.ui.notify(scope.length ? `Scope: ${scope.join(", ")}` : "Scope cleared (unrestricted)", "info");
    },
  });
  pi.registerCommand("phone-limits", {
    description: "Set automatic posting limits: /phone-limits <perHour> <perSession>",
    handler: async (arg, ctx) => {
      const [h, s] = arg.trim().split(/\s+/).map(Number);
      if (!Number.isFinite(h) || !Number.isFinite(s)) return void ctx.ui.notify("usage: /phone-limits <perHour> <perSession>", "error");
      maxHour = h; maxSession = s;
      pi.appendEntry("phone-limits", { maxHour, maxSession });
      ctx.ui.notify(`Limits: ${maxHour}/hour, ${maxSession}/session`, "info");
    },
  });

  pi.registerCommand("phone-grant", {
    description: "Timeboxed approval grant: /phone-grant <minutes>|<app>|<where> (empty where = any)",
    handler: async (arg, ctx) => {
      const [min, app, where] = String(arg).split("|");
      const minutes = +min;
      if (!Number.isFinite(minutes) || minutes <= 0 || !app) return void ctx.ui.notify("usage: /phone-grant <minutes>|<app>|<where>", "error");
      grants = grants.filter(g => !(g.app.toLowerCase() === app.toLowerCase() && g.where.toLowerCase() === String(where || "").toLowerCase()));
      grants.push({ app, where: where || "", until: Date.now() + minutes * 60000 });
      pi.appendEntry("phone-grant", { grants });
      ctx.ui.notify(`Auto-approve ${app}${where ? " / " + where : ""} for ${minutes} min`, "info");
    },
  });
  pi.registerCommand("phone-revoke", {
    description: "Revoke all auto-approve grants for this session",
    handler: async (_arg, ctx) => {
      grants = [];
      pi.appendEntry("phone-grant", { grants });
      ctx.ui.notify("Auto-approve grants revoked", "info");
    },
  });

  pi.registerTool(defineTool({
    name: "remember", label: "Remember a fact", description: "Append a durable fact about the user to their profile memory (profile.md).",
    parameters: Type.Object({ fact: Type.String() }),
    async execute(_id, p) {
      const fact = String(p.fact || "").trim();
      if (!fact) return textResult({ remembered: false });
      // Private memory: keep the data dir owner-only and repair perms on an
      // existing profile.md (appendFile's mode only applies on creation).
      await mkdir(dataDir, { recursive: true });
      await chmod(dataDir, 0o700).catch(() => {});
      await appendFile(profilePath, `- ${fact}\n`, { mode: 0o600 });
      await chmod(profilePath, 0o600).catch(() => {});
      return textResult({ remembered: fact });
    },
  }));

  pi.registerTool(defineTool({
    name: "phone_plan", label: "Plan checkpoint", description: "For a long or monitoring mandate, post a 3–5 line plan (what you will watch, how often, what you will post and where) and wait for the user to approve it once before you start.",
    parameters: Type.Object({ plan: Type.String() }),
    async execute(_id, p, _signal, _update, ctx) {
      const approved = await ctx.ui.editor("Plan checkpoint — approve to start", String(p.plan || ""));
      if (approved === undefined || approved === null || String(approved).trim() === "") throw new Error("plan rejected by the user; do not start");
      return textResult({ approved: true, plan: String(approved) });
    },
  }));

  pi.registerTool(defineTool({
    name: "phone_screen", label: "Read iPhone screen", description: "Read the full app-bound accessibility snapshot. Refs are replaced by every fresh outline.",
    parameters: Type.Object({}),
    async execute() { return scoped(await client.screen()); },
  }));

  pi.registerTool(defineTool({
    name: "phone_tap", label: "Tap iPhone element", description: "Tap a current ref, except outward/destructive controls, and return a fresh outline. Offscreen refs must be scrolled into view first.",
    parameters: Type.Object({ ref: Type.Integer({ minimum: 1 }) }),
    async execute(_id, p) { await assertInScope(); assertSafeTap(client.ref(p.ref)); return scoped(await client.tap(p.ref), {}, true); },
  }));

  pi.registerTool(defineTool({
    name: "phone_type", label: "Type on iPhone", description: "Focus a field, wait for the keyboard, clear, insert exact Unicode via paste/keys, verify the exact readback and the foreground app. Any mismatch is an error and nothing further is typed.",
    parameters: Type.Object({ ref: Type.Integer({ minimum: 1 }), text: Type.String() }),
    async execute(_id, p) {
      await assertInScope();
      const v = await client.type(p.ref, p.text);
      if (!v.exact) throw new Error((v as any).error || `exact text mismatch (read back ${JSON.stringify(v.value)})`);
      return scoped(v.screen, { exact: true, value: v.value, inserted_via: (v as any).path || "keys" }, true);
    },
  }));

  pi.registerTool(defineTool({
    name: "phone_scroll", label: "Scroll iPhone", description: "Swipe the current screen and return a fresh outline.",
    parameters: Type.Object({ direction: Type.Union([Type.Literal("up"), Type.Literal("down")]) }),
    async execute(_id, p) { await assertInScope(); return scoped(await client.scroll(p.direction), {}, true); },
  }));

  pi.registerTool(defineTool({
    name: "phone_open_app", label: "Open iPhone app", description: "Open an installed app by name (launch first, then bind) and return a fresh app-bound outline. Refuses apps outside the session scope.",
    parameters: Type.Object({ name: Type.String() }),
    async execute(_id, p) {
      const bundle = await resolveBundle(p.name);
      if (!bundle) throw new Error(`unknown app ${p.name}; apps.json may not be ready yet`);
      const allowed = await allowedBundles();
      if (allowed && !allowed.has(bundle)) throw new Error(`${p.name} is outside this session's scope (${scope.join(", ")}); ask the user to widen it`);
      return scoped(await client.open(bundle), {}, true);
    },
  }));

  pi.registerTool(defineTool({
    name: "phone_home", label: "iPhone Home", description: "Go to the Home screen and return a fresh outline.", parameters: Type.Object({}),
    async execute() { return scoped(await client.home(), {}, true); },
  }));

  pi.registerTool(defineTool({
    name: "phone_back", label: "iPhone Back", description: "Tap a visible Back control and return a fresh outline; errors if none exists.", parameters: Type.Object({}),
    async execute() { await assertInScope(); const s = client.latest || await client.screen(); const back = s.elements.find(e => /^(back|cancel|close)$/i.test(e.label)); if (!back) throw new Error("no feasible visible Back/Cancel/Close control; inspect the latest outline"); return scoped(await client.tap(back.ref), {}, true); },
  }));

  pi.registerTool(defineTool({
    name: "phone_look", label: "Inspect iPhone screenshot", description: "Downscaled screenshot for visual inspection only. Give a reason; continue acting by refs, never coordinates.",
    parameters: Type.Object({ reason: Type.String() }),
    async execute() {
      // A screenshot discloses whatever is foreground: refuse if it's out of scope.
      const active = await client.activeApp();
      const err = await scopeError(active);
      if (err) return textResult({ scope_error: err, app: active, screenshot_withheld: true });
      await mkdir(runtime(), { recursive: true });
      const src = `${runtime()}/look.png`, dst = `${runtime()}/look.jpg`;
      await writeFile(src, Buffer.from(await client.screenshot(), "base64"));
      await run("magick", [src, "-resize", "50%", "-quality", "72", dst]);
      const data = (await readFile(dst)).toString("base64");
      return { content: [{ type: "text" as const, text: "Latest downscaled iPhone screenshot; act only through outline refs." }, { type: "image" as const, data, mimeType: "image/jpeg" }], details: { latest: true } };
    },
  }));

  pi.registerTool(defineTool({
    name: "phone_post", label: "Post outward text", description: "The only outward text path: enforce policy, ask you to approve/edit, verify exact text, tap send, verify appearance, and audit.",
    parameters: Type.Object({ field_ref: Type.Integer(), text: Type.String(), send_ref: Type.Integer(), app: Type.String(), where: Type.String(), intent: Type.Optional(Type.String()), reply_to: Type.Optional(Type.Object({ author: Type.String(), text: Type.String() })), is_dm: Type.Optional(Type.Boolean()), recipient_known: Type.Optional(Type.Boolean()) }),
    async execute(_id, p, _signal, _update, ctx) {
      await assertInScope();
      hardPolicy(p);
      const now = Date.now();
      if (mode === "auto") checkAutoLimits(hourlyPosts, sessionPosts, now, maxHour, maxSession);
      const ask = (mode === "ask" && !(await grantHonored(p)))
        ? async (pp: any) => ctx.ui.editor(`Post to ${pp.app} / ${pp.where} — ${reasonFor(pp)}`, pp.text)
        : async () => p.text;
      // Re-assert scope after approval: the foreground could have changed while
      // the editor was open; never send into an app that is now out of scope.
      const review = async (pp: any) => {
        const text = await ask(pp);
        if (text === null || text === undefined || String(text).trim() === "") return text;
        await assertInScope();
        return text;
      };
      const out = await guardedPost(client, p, review);
      if (out.posted) { hourlyPosts.push(now); sessionPosts++; }
      pi.appendEntry("phone-post-audit", { at: new Date().toISOString(), mode, app: p.app, where: p.where, reply_to: p.reply_to, text: out.text || p.text, outcome: out.posted ? "posted_verified" : "denied" });
      return out.posted ? scoped(out.screen!, { posted: true, exact: true }, true) : textResult(out);
    },
  }));

  pi.registerTool(defineTool({
    name: "phone_watch", label: "Watch iPhone app", description: "Poll labels with plain code. New labels trigger one follow-up; unchanged ticks make no LLM calls. The watched app must remain foreground.",
    parameters: Type.Object({ app: Type.String(), every_s: Type.Integer({ minimum: 5, maximum: 3600 }) }),
    async execute(_id, p) {
      const bundle = await resolveBundle(p.app); if (!bundle) throw new Error("watch needs a known app name");
      const err = await scopeError(bundle); if (err) throw new Error(err);  // never relay out-of-scope ticks
      if (timer) clearInterval(timer); const previous = await client.screen(bundle); watched = { app: p.app, bundle, previous };
      timer = setInterval(async () => {
        if (busy || !watched) return;
        try {
          // Scope can be narrowed (/phone-scope) after the watcher starts; re-check
          // every tick and stop rather than relay now-out-of-scope labels.
          if (await scopeError(watched.bundle)) {
            const app = watched.app;
            if (timer) clearInterval(timer); timer = undefined; watched = undefined;
            pi.sendMessage({ customType: "phone-watch", content: `Stopped watching ${app}: it is no longer in the session scope.`, display: true }, { triggerTurn: true, deliverAs: "followUp" });
            return;
          }
          if (await client.activeApp() !== watched.bundle) return;
          const next = await client.screen(watched.bundle); const added = newLabels(watched.previous, next); watched.previous = next;
          if (added.length) pi.sendMessage({ customType: "phone-watch", content: `${added.length} new item(s) in ${watched.app}:\n${added.slice(0, 12).join("\n")}`, display: true }, { triggerTurn: true, deliverAs: "followUp" });
        } catch {}
      }, p.every_s * 1000);
      return textResult({ watching: p.app, every_s: p.every_s, fingerprint: previous.fingerprint });
    },
  }));

  pi.registerTool(defineTool({
    name: "phone_unwatch", label: "Stop iPhone watcher", description: "Stop the current plain-code watcher.", parameters: Type.Object({}),
    async execute() { if (timer) clearInterval(timer); timer = undefined; watched = undefined; return textResult({ watching: false }); },
  }));
}
