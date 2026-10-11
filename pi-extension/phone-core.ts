import { createHash } from "node:crypto";
import { request as httpRequest } from "node:http";

export type Rect = { x: number; y: number; width: number; height: number };
export type Element = { ref: number; type: string; label: string; value: string; rect: Rect; offscreen?: boolean };
export type Snapshot = { app: string; fingerprint: string; outline: string; elements: Element[]; screen: { w: number; h: number } };

const excluded = "visible,accessible,enabled,index,focused,placeholderValue,hittable";
const labelCap = 1000;
// Whole-outline cap: a huge page can't flood the model or the panel (which buffers each event line).
const outlineCap = 200_000;
// Full snapshot every read. 200 is the practical WDA maximum; override only for debugging.
const snapshotDepth = () => +(process.env.IPHONE_SNAPSHOT_DEPTH || 200);
// Pure icon asset identifiers carry no usable content.
const assetNoise = /^system-icons_|_\d+x\d+$/;
const entities: Record<string, string> = { amp: "&", quot: '"', apos: "'", lt: "<", gt: ">" };
function unescape(s = "") { return s.replace(/&(amp|quot|apos|lt|gt|#\d+|#x[\da-f]+);/gi, (_, n) => n[0] === "#" ? String.fromCodePoint(parseInt(n.slice(n[1]?.toLowerCase() === "x" ? 2 : 1), n[1]?.toLowerCase() === "x" ? 16 : 10)) : entities[n]); }
function attrs(tag: string) { const out: Record<string, string> = {}; for (const m of tag.matchAll(/([\w-]+)="([^"]*)"/g)) out[m[1]] = unescape(m[2]); return out; }
function short(s: string) { return s.replace(/\s+/g, " ").trim().slice(0, labelCap); }
const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

function contains(a: Rect, b: Rect) { return a.x <= b.x && a.y <= b.y && a.x + a.width >= b.x + b.width && a.y + a.height >= b.y + b.height; }
/** Suppress only exact-duplicate label/value repeats nested inside (or equal to) an accepted element. */
function duplicate(accepted: Element[], e: Element) {
  return accepted.some(a => a.label === e.label && a.value === e.value && contains(a.rect, e.rect));
}

export function compressSource(xml: string, app: string, generation = 0): Snapshot {
  const raw: Element[] = [];
  for (const match of xml.matchAll(/<([A-Za-z][\w.]*)\b([^>]*)>/g)) {
    const a = attrs(match[2]);
    const type = (a.type || match[1]).replace(/^XCUIElementType/, "");
    const label = short(a.label || a.name || "");
    const value = short(a.value || "");
    const rect = { x: +a.x, y: +a.y, width: +a.width, height: +a.height };
    if (rect.width <= 0 || rect.height <= 0 || (!label && !value)) continue;
    raw.push({ ref: 0, type, label, value, rect });
  }
  let screen = { w: 0, h: 0 };
  for (const e of raw) if ((e.type === "Application" || e.type === "Window") && e.rect.width * e.rect.height > screen.w * screen.h) screen = { w: e.rect.width, h: e.rect.height };
  const elements: Element[] = [];
  for (const e of raw) {
    if (e.label && assetNoise.test(e.label)) continue;
    if (duplicate(elements, e)) continue;
    const offscreen = screen.w > 0 && (e.rect.x + e.rect.width <= 0 || e.rect.y + e.rect.height <= 0 || e.rect.x >= screen.w || e.rect.y >= screen.h);
    elements.push({ ref: generation * 100000 + elements.length + 1, type: e.type, label: e.label, value: e.value, rect: e.rect, offscreen });
  }
  const lines = elements.map(e => `[${e.ref}] ${e.type}${e.label ? ` "${e.label.replaceAll('"', "'")}"` : ""}${e.value && e.value !== e.label ? ` = "${e.value.replaceAll('"', "'")}"` : ""}${e.offscreen ? " (offscreen)" : ""}`);
  let used = 0, keep = lines.length;
  for (let i = 0; i < lines.length; i++) if ((used += lines[i].length + 1) > outlineCap) { keep = i; break; }
  const omitted = lines.length - keep;
  elements.length = keep; lines.length = keep;
  if (omitted) lines.push(`(${omitted} more elements omitted: screen too large; scroll to reach them)`);
  const semantic = elements.map(e => `${e.type}\0${e.label}\0${e.value}`).join("\n");
  const fingerprint = createHash("sha256").update(app + "\0" + semantic).digest("hex").slice(0, 16);
  return { app, fingerprint, outline: `App: ${app}\nFingerprint: ${fingerprint}\n${lines.join("\n") || "(no useful elements)"}`, elements, screen };
}

export class WdaClient {
  private session = "";
  private bundle = "";
  private generation = 0;
  latest?: Snapshot;
  sock: string;
  // WDA is reached over an owner-only Unix socket (0600 in $XDG_RUNTIME_DIR),
  // not a loopback TCP port any local user could connect to.
  constructor(sock = process.env.IPHONE_WDA_SOCK || `${process.env.XDG_RUNTIME_DIR || `/run/user/${process.getuid()}`}/iphone-agent/wda.sock`) { this.sock = sock; }
  restore(state: { sessionId?: string; bundle?: string; generation?: number; latest?: Snapshot }) {
    this.session = state.sessionId || ""; this.bundle = state.bundle || ""; this.generation = state.generation || 0; this.latest = state.latest;
  }
  state() { return { sessionId: this.session, bundle: this.bundle, generation: this.generation, latest: this.latest }; }
  async request(path: string, body?: unknown, method?: string): Promise<any> {
    return this.fetchOnce(path, body, method, true);
  }
  private httpOverSocket(path: string, body: unknown, method: string | undefined): Promise<{ status: number; json: any }> {
    const payload = body === undefined ? undefined : JSON.stringify(body);
    return new Promise((resolve, reject) => {
      const req = httpRequest({
        socketPath: this.sock, path, method: method || (body === undefined ? "GET" : "POST"),
        headers: payload === undefined ? {} : { "content-type": "application/json", "content-length": Buffer.byteLength(payload) },
        timeout: 20000,
      }, (res) => {
        let data = ""; res.setEncoding("utf8");
        res.on("data", (c) => { data += c; });
        res.on("end", () => { let json: any = {}; try { json = JSON.parse(data); } catch { /* non-JSON */ } resolve({ status: res.statusCode || 0, json }); });
      });
      req.on("error", reject);
      req.on("timeout", () => req.destroy(new Error(`WDA timeout ${path}`)));
      if (payload !== undefined) req.write(payload);
      req.end();
    });
  }
  private async fetchOnce(path: string, body: unknown, method: string | undefined, recover: boolean): Promise<any> {
    const { status, json: j } = await this.httpOverSocket(path, body, method);
    const ok = status >= 200 && status < 300;
    const message: string = j.value?.message || `WDA ${status} ${path}`;
    if (!ok || j.value?.error) {
      // Stale-session recovery: drop the session once and retry transparently.
      if (recover && this.session && /invalid session|session.*(not found|does not exist|unknown)|no such session/i.test(message)) {
        this.session = ""; this.bundle = ""; await sleep(150);
        return this.fetchOnce(path, body, method, false);
      }
      throw new Error(message);
    }
    return j.value;
  }
  async activeApp() { const v = await this.request("/wda/activeAppInfo"); return v.bundleId || v.bundle || "unknown"; }
  async ensure(bundle?: string) {
    const settings = { waitForIdleTimeout: 0, animationCoolOffTimeout: 0, snapshotMaxDepth: snapshotDepth() };
    if (bundle && this.session && this.bundle === bundle) {
      await this.request(`/session/${this.session}/appium/settings`, { settings });
      return;
    }
    const foreground = await this.activeApp();
    const wanted = bundle || foreground;
    if (wanted !== foreground && wanted !== "com.apple.springboard") throw new Error(`app ${wanted} is not foreground; use phone_open_app`);
    if (this.session && this.bundle === wanted) {
      await this.request(`/session/${this.session}/appium/settings`, { settings });
      return;
    }
    if (this.session) await this.request(`/session/${this.session}`, undefined, "DELETE").catch(() => {});
    const alwaysMatch: Record<string, unknown> = { shouldWaitForQuiescence: false, waitForIdleTimeout: 0, forceAppLaunch: false, shouldTerminateApp: false };
    // SpringBoard cannot be launched by bundle id; an unbound session still snapshots Home in ~0.5 s.
    if (wanted !== "com.apple.springboard") alwaysMatch.bundleId = wanted;
    const value = await this.request("/session", { capabilities: { alwaysMatch } });
    this.session = value.sessionId || value.id;
    this.bundle = wanted;
    if (!this.session) throw new Error("WDA did not return a session id");
    await this.request(`/session/${this.session}/appium/settings`, { settings });
  }
  async screen(bundle?: string) {
    const wanted = bundle || await this.activeApp();
    await this.ensure(wanted);
    const xml = await this.request(`/session/${this.session}/source?excluded_attributes=${excluded}`);
    this.latest = compressSource(typeof xml === "string" ? xml : xml.source, this.bundle, ++this.generation);
    return this.latest;
  }
  ref(n: number) { const e = this.latest?.elements.find(x => x.ref === n); if (!e) throw new Error("stale or unknown ref; call phone_screen and use its latest refs"); return e; }
  private quoted(s: string) { return `'${s.replaceAll("\\", "\\\\").replaceAll("'", "\\'")}'`; }
  private uniqueLabel(e: Element) { return !!e.label && this.latest?.elements.filter(x => x.label === e.label).length === 1; }
  async elementId(e: Element, predicate = `type == ${this.quoted(`XCUIElementType${e.type}`)} AND label == ${this.quoted(e.label)}`) {
    const v = await this.request(`/session/${this.session}/element`, { using: "predicate string", value: predicate });
    const id = v?.["element-6066-11e4-a52e-4f735466cecf"] || v?.ELEMENT;
    if (!id) throw new Error(`element no longer found: ${e.label}`);
    return id;
  }
  private async focusedFieldId(e: Element) {
    try { return await this.elementId(e, "hasKeyboardFocus == 1"); }
    catch {
      try { return await this.elementId(e, "focused == 1 AND (type == 'XCUIElementTypeTextField' OR type == 'XCUIElementTypeSearchField')"); }
      catch { return this.elementId(e, `(type == 'XCUIElementTypeTextField' OR type == 'XCUIElementTypeSearchField') AND placeholderValue == ${this.quoted(e.label || e.value)}`); }
    }
  }
  private async coordinateTap(e: Element) { await this.request(`/session/${this.session}/wda/tap`, { x: e.rect.x + e.rect.width / 2, y: e.rect.y + e.rect.height / 2 }); }
  private async waitForKeyboard(ms: number) {
    const deadline = Date.now() + ms;
    while (Date.now() < deadline) {
      try {
        const xml = await this.request(`/session/${this.session}/source?excluded_attributes=${excluded}`);
        const src = typeof xml === "string" ? xml : xml.source;
        if (src.includes("XCUIElementTypeKeyboard")) return true;
      } catch { /* ignore */ }
      await sleep(150);
    }
    return false;
  }
  private async pasteViaBoard(text: string) {
    const content = Buffer.from(text, "utf8").toString("base64");
    await this.request(`/session/${this.session}/wda/setPasteboard`, { content, contentType: "plaintext" });
    // uuid 0 = active app; XCUIKeyModifierCommand = 1 << 4 = 16 (typeKey, iOS 17+/Xcode 15+).
    await this.request(`/session/${this.session}/wda/element/0/keyboardInput`, { keys: [{ key: "v", modifierFlags: 16 }] });
    return true;
  }
  private async readFocusedValue(text: string, id: string | null) {
    let screen = this.latest as Snapshot;
    for (let i = 0; i < 6; i++) {
      await sleep(250);
      let got = "";
      try { if (id) got = await this.request(`/session/${this.session}/element/${id}/attribute/value`); } catch { /* ignore */ }
      screen = await this.screen(this.bundle);
      const field = screen.elements.find(x => /(TextField|SearchField|TextView)/.test(x.type) && (x.value === text || x.label === text));
      if (field) return { value: field.value || field.label || got, screen };
      if (got === text) return { value: got, screen };
    }
    const field = screen.elements.find(x => /(TextField|SearchField)/.test(x.type));
    return { value: field ? (field.value || field.label || "") : "", screen };
  }
  async tapElement(e: Element) {
    if (e.offscreen) throw new Error("element is offscreen; scroll it into view first");
    if (!this.uniqueLabel(e)) await this.coordinateTap(e);
    else try { await this.request(`/session/${this.session}/element/${await this.elementId(e)}/click`, {}); }
    catch { await this.coordinateTap(e); }
    return this.screen(this.bundle);
  }
  async tap(ref: number) { return this.tapElement(this.ref(ref)); }
  // phone_type v2: tap, wait for the keyboard, clear, insert, read back, verify foreground.
  async type(ref: number, text: string) {
    const e = this.ref(ref);
    if (e.offscreen) throw new Error("field is offscreen; scroll it into view first");
    const before = await this.activeApp();
    await this.coordinateTap({ ...e, rect: { ...e.rect, y: Math.max(e.rect.y, 70) } });
    const afterTap = await this.activeApp();
    if (afterTap !== before) throw new Error(`tap moved from ${before} to ${afterTap}; nothing typed`);
    const keyboard = await this.waitForKeyboard(2000);
    if (!keyboard) throw new Error("no keyboard appeared after tapping the field; nothing typed");
    // Fields can transform on focus (X swaps its SearchField for a TextField), so act on the focused element.
    let id: string | null = null;
    try { const v = await this.request(`/session/${this.session}/element/active`); id = v?.["element-6066-11e4-a52e-4f735466cecf"] || v?.ELEMENT || null; } catch { id = null; }
    if (!id) { try { id = this.uniqueLabel(e) ? await this.elementId(e) : await this.focusedFieldId(e); } catch { id = null; } }
    if (id) { try { await this.request(`/session/${this.session}/element/${id}/clear`, {}); } catch { /* best effort */ } }
    // /wda/keys is the real-device path (exact Unicode incl. emoji/Devanagari, ~0.5 s measured on iOS 27).
    // WDA's setPasteboard is a no-op on real devices, so the old paste route silently inserted nothing.
    await this.request(`/session/${this.session}/wda/keys`, { value: [...text] });
    const pasted = false;
    await sleep(300);
    const { value: got, screen } = await this.readFocusedValue(text, id);
    const after = await this.activeApp();
    if (after !== before) throw new Error(`typing escaped ${before} into ${after}; nothing was reported as typed`);
    if (got !== text) return { exact: false, value: got, screen, path: pasted ? "pasteboard" : "keys", error: `exact text mismatch (read back ${JSON.stringify(got)}); nothing more typed` };
    return { exact: true, value: got, screen, path: pasted ? "pasteboard" : "keys" };
  }
  async scroll(direction: "up" | "down") {
    const h = this.latest?.screen?.h || 852;
    const w = this.latest?.screen?.w || 393;
    const x = Math.round(w / 2);
    const top = Math.round(h * 0.30), bottom = Math.round(h * 0.70);
    const fromY = direction === "up" ? bottom : top;
    const toY = direction === "up" ? top : bottom;
    await this.request(`/session/${this.session}/wda/dragfromtoforduration`, { fromX: x, fromY, toX: x, toY, duration: .25 });
    return this.screen(this.bundle);
  }
  // Launch first, then bind. Prefer launchUnattached (no session needed), then bind.
  async open(bundle: string) {
    const foreground = await this.activeApp();
    if (foreground === bundle) return this.screen(bundle);
    let launched = false;
    try { await this.request(`/wda/apps/launchUnattached`, { bundleId: bundle }); launched = true; }
    catch { launched = false; }
    if (!launched) {
      await this.ensure(foreground === "unknown" ? "com.apple.springboard" : foreground);
      await this.request(`/session/${this.session}/wda/apps/launch`, { bundleId: bundle });
    }
    for (let i = 0; i < 25; i++) { if (await this.activeApp() === bundle) break; await sleep(100); }
    return this.screen(bundle);
  }
  async home() {
    await this.request("/wda/homescreen", {});
    for (let i = 0; i < 10 && await this.activeApp() !== "com.apple.springboard"; i++) await sleep(100);
    if (this.session) await this.request(`/session/${this.session}`, undefined, "DELETE").catch(() => {});
    this.session = this.bundle = ""; return this.screen("com.apple.springboard");
  }
  async screenshot() { return await this.request("/screenshot") as string; }
}

export const outward = /\b(send|post|publish|reply|tweet|buy|pay|order|checkout|delete|remove|subscribe|follow|unfollow|block|transfer|confirm|accept|install|join|leave)\b/i;
export function assertSafeTap(e: Element) { if (outward.test(`${e.label} ${e.value}`)) throw new Error("outward/destructive ref refused; use phone_post for outward text (other destructive actions are forbidden)"); }
export function hardPolicy(p: { where: string; intent?: string; control?: string; is_dm?: boolean; recipient_known?: boolean }) {
  if (p.is_dm && !p.recipient_known) throw new Error("policy denies DMs to strangers");
  if (/\b(buy|purchase|pay|payment|checkout|transfer|subscribe|follow|unfollow|block|join|leave)\b/i.test(`${p.where} ${p.intent || ""} ${p.control || ""}`)) throw new Error("policy denies money, purchases, follows, blocks, joins, and leaves");
}

export function checkAutoLimits(hourly: number[], sessionCount: number, now: number, maxHour: number, maxSession: number) {
  while (hourly[0] && hourly[0] < now - 3600_000) hourly.shift();
  if (hourly.length >= maxHour || sessionCount >= maxSession) throw new Error("automatic post limit reached; switch to ask mode or start a new session");
}

// `review` returns the exact text to post (possibly edited) or null to deny.
export async function guardedPost(client: WdaClient, p: any, review: (p: any) => Promise<string | null | undefined>) {
  const send = client.ref(p.send_ref); // capture both refs from the same caller-visible snapshot.
  hardPolicy({ ...p, control: `${send.label} ${send.value}` });
  const chosen = await review(p);
  if (chosen === null || chosen === undefined || chosen.trim() === "") return { posted: false, reason: "user denied" };
  const typed = await client.type(p.field_ref, chosen);
  if (!typed.exact) throw new Error(`exact text verification failed; nothing sent (read back ${JSON.stringify(typed.value)})`);
  const after = await client.tapElement(send); // guarded post intentionally permits Send/Post.
  const present = after.elements.some(e => !/(TextField|TextView|SearchField)/.test(e.type) && (e.label.includes(chosen) || e.value.includes(chosen)));
  if (!present) throw new Error("send was tapped but the posted text was not found in the fresh screen; outcome uncertain");
  return { posted: true, exact: true, text: chosen, screen: after };
}

export function newLabels(before: Snapshot, after: Snapshot) {
  const old = new Set(before.elements.map(e => e.label).filter(Boolean));
  return [...new Set(after.elements.map(e => e.label).filter(x => x && !old.has(x)))];
}

export function elementKey(e: Element) { return `${e.type}\0${e.label}\0${e.value}`; }
