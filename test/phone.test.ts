import assert from "node:assert/strict";
import { rmSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { compressSource, WdaClient, assertSafeTap, checkAutoLimits, guardedPost, hardPolicy, newLabels } from "../pi-extension/phone-core.ts";

const xml = (extra = "") => `<?xml version="1.0"?><XCUIElementTypeApplication type="XCUIElementTypeApplication" x="0" y="0" width="390" height="844"><XCUIElementTypeTextField type="XCUIElementTypeTextField" label="Message &amp; text" value="" x="10" y="700" width="280" height="40"/><XCUIElementTypeButton type="XCUIElementTypeButton" label="Send" x="300" y="700" width="70" height="40"/>${extra}</XCUIElementTypeApplication>`;
let server: Server, base = "", calls: string[] = [], bodies: string[] = [], typed = "", currentXml = xml();

before(async () => {
  server = createServer(async (req, res) => {
    let body = ""; for await (const chunk of req) body += chunk; calls.push(`${req.method} ${req.url}`); bodies.push(body);
    res.setHeader("content-type", "application/json");
    const path = req.url || ""; let value: any = null;
    if (path === "/wda/activeAppInfo") value = { bundleId: "com.test" };
    else if (path === "/session" && req.method === "POST") value = { sessionId: "s1" };
    else if (path.includes("/source")) value = currentXml;
    else if (path.endsWith("/element")) value = { "element-6066-11e4-a52e-4f735466cecf": "e1" };
    else if (path.endsWith("/attribute/value")) value = typed;
    else if (path.endsWith("/value")) { typed = [...JSON.parse(body).value].join(""); value = null; }
    else if (path.endsWith("/click")) { currentXml = xml(`<XCUIElementTypeStaticText type="XCUIElementTypeStaticText" label="${typed}" x="10" y="500" width="300" height="40"/>`); value = null; }
    res.end(JSON.stringify({ value }));
  });
  base = join(tmpdir(), `wda-test-${process.pid}-${Date.now()}.sock`);
  await new Promise<void>(resolve => server.listen(base, resolve));
});
after(() => { server.close(); rmSync(base, { force: true }); });

function reset() { calls = []; bodies = []; typed = ""; currentXml = xml(); }

test("compresses useful XML into numbered refs and decodes labels", () => {
  const s = compressSource(xml(), "com.test");
  assert.match(s.outline, /\[1\] TextField "Message & text"/);
  assert.match(s.outline, /\[2\] Button "Send"/);
  assert.equal(s.elements[0].rect.x, 10);
  assert.equal(s.fingerprint.length, 16);
});

test("unique ref resolves through typed-label predicate and element click", async () => {
  reset(); const c = new WdaClient(base); const s = await c.screen(); await c.tap(s.elements[0].ref);
  const i = calls.findIndex(x => x.endsWith("/element"));
  assert.match(bodies[i], /type == .*XCUIElementTypeTextField.* AND label == .*Message & text/);
  assert.ok(calls.some(x => x.endsWith("/element/e1/click")));
  assert.equal(calls.filter(x => x.includes("/source?")).length, 2);
});

test("every read requests the full snapshot depth", async () => {
  reset(); const c = new WdaClient(base); await c.screen();
  const depths = bodies.filter((_, i) => calls[i].includes("/appium/settings")).map(x => JSON.parse(x).settings.snapshotMaxDepth);
  assert.ok(depths.length >= 1);
  assert.ok(depths.every(d => d === 200));
});

test("full snapshot keeps every labelled type and strips asset-name noise", () => {
  const rich = `<XCUIElementTypeApplication type="XCUIElementTypeApplication" x="0" y="0" width="390" height="844">
    <XCUIElementTypeOther type="XCUIElementTypeOther" label="Custom Chart" x="0" y="0" width="100" height="100"/>
    <XCUIElementTypeMap type="XCUIElementTypeMap" label="Map" x="0" y="120" width="100" height="100"/>
    <XCUIElementTypeImage type="XCUIElementTypeImage" label="system-icons_home" x="0" y="240" width="20" height="20"/>
    <XCUIElementTypeImage type="XCUIElementTypeImage" label="avatar_40x40" x="0" y="260" width="40" height="40"/>
    <XCUIElementTypeImage type="XCUIElementTypeImage" label="account_avatar" x="0" y="280" width="40" height="40"/>
  </XCUIElementTypeApplication>`;
  const labels = compressSource(rich, "com.test").elements.map(e => e.label);
  assert.ok(labels.includes("Custom Chart"));
  assert.ok(labels.includes("Map"));
  assert.ok(labels.includes("account_avatar"));
  assert.equal(labels.includes("system-icons_home"), false);
  assert.equal(labels.includes("avatar_40x40"), false);
});

test("exact parent/child label repeats are deduped but distinct duplicates stay", () => {
  const nested = `<XCUIElementTypeApplication type="XCUIElementTypeApplication" x="0" y="0" width="390" height="844">
    <XCUIElementTypeCell type="XCUIElementTypeCell" label="Posts" x="0" y="0" width="100" height="100">
      <XCUIElementTypeStaticText type="XCUIElementTypeStaticText" label="Posts" x="10" y="10" width="50" height="20"/>
    </XCUIElementTypeCell>
    <XCUIElementTypeCell type="XCUIElementTypeCell" label="Machine Learning" x="0" y="200" width="100" height="40"/>
    <XCUIElementTypeCell type="XCUIElementTypeCell" label="Machine Learning" x="0" y="300" width="100" height="40"/>
  </XCUIElementTypeApplication>`;
  const elements = compressSource(nested, "com.test").elements;
  assert.equal(elements.filter(e => e.label === "Posts").length, 1);
  assert.equal(elements.filter(e => e.label === "Machine Learning").length, 2);
});

test("long labels cap at 1000 characters and stay whole in the outline", () => {
  const long = "x".repeat(1500);
  const s = compressSource(`<XCUIElementTypeApplication type="XCUIElementTypeApplication" x="0" y="0" width="10" height="10"><XCUIElementTypeStaticText type="XCUIElementTypeStaticText" label="${long}" x="0" y="0" width="5" height="5"/></XCUIElementTypeApplication>`, "com.test");
  assert.equal(s.elements[0].label.length, 1000);
  assert.ok(s.outline.includes(s.elements[0].label));
});

test("a newer snapshot makes an older generation ref fail clearly", async () => {
  reset(); const c = new WdaClient(base); const first = await c.screen(), old = first.elements[0].ref, next = await c.screen();
  assert.equal(first.fingerprint, next.fingerprint);
  await assert.rejects(() => c.tap(old), /stale or unknown ref; call phone_screen/);
});

test("duplicate labels tap their own rectangle without predicate lookup", async () => {
  reset(); currentXml = xml(`<XCUIElementTypeButton type="XCUIElementTypeButton" label="Send" x="10" y="100" width="40" height="20"/>`);
  const c = new WdaClient(base), s = await c.screen(), duplicate = s.elements.find(e => e.label === "Send" && e.rect.y === 100)!;
  calls = []; bodies = []; await c.tap(duplicate.ref);
  assert.equal(calls.some(x => x.endsWith("/element")), false);
  const i = calls.findIndex(x => x.includes("/wda/tap")); assert.deepEqual(JSON.parse(bodies[i]), { x: 30, y: 110 });
});

test("unique value-only field resolves by typed value instead of empty label", async () => {
  reset(); currentXml = `<XCUIElementTypeApplication type="XCUIElementTypeApplication" x="0" y="0" width="390" height="844"><XCUIElementTypeTextField type="XCUIElementTypeTextField" value="draft" x="20" y="300" width="200" height="40"/></XCUIElementTypeApplication>`;
  const c = new WdaClient(base), s = await c.screen(); calls = []; bodies = []; await c.type(s.elements[0].ref, "😭");
  const i = calls.findIndex(x => x.endsWith("/element")); assert.match(bodies[i], /type == .*XCUIElementTypeTextField.* AND value == .*draft/);
  assert.equal(calls.some(x => /label == ''/.test(x)), false);
  assert.equal(typed, "😭");
});

test("ordinary tap refuses outward labels", () => {
  const s = compressSource(xml(), "com.test");
  assert.throws(() => assertSafeTap(s.elements[1]), /phone_post/);
});

test("post ask-deny types and taps nothing", async () => {
  reset(); const c = new WdaClient(base); const s = await c.screen();
  const out = await guardedPost(c, { field_ref: s.elements[0].ref, send_ref: s.elements[1].ref, text: "hello", app: "X", where: "feed" }, async () => null);
  assert.equal(out.posted, false); assert.equal(calls.some(x => x.endsWith("/value") || x.endsWith("/click")), false);
});

test("exact Unicode value is read back before guarded send", async () => {
  reset(); const c = new WdaClient(base); const s = await c.screen();
  const out = await guardedPost(c, { field_ref: s.elements[0].ref, send_ref: s.elements[1].ref, text: "hi 😭", app: "Discord", where: "friends" }, async () => "hi 😭");
  assert.equal(out.posted, true); assert.equal(out.exact, true); assert.equal(typed, "hi 😭");
  assert.ok(calls.findIndex(x => x.endsWith("/attribute/value")) < calls.findIndex(x => x.endsWith("/click")));
});

test("session post limit survives pruning the hourly window", () => {
  const hourly = [1];
  assert.throws(() => checkAutoLimits(hourly, 2, 4_000_000, 10, 2), /session/);
  assert.deepEqual(hourly, []);
});

test("policy checks intent/target but allows ordinary message words", () => {
  assert.doesNotThrow(() => hardPolicy({ where: "friends", intent: "post reply", text: "join the call bro" } as any));
  assert.throws(() => hardPolicy({ where: "Join group", intent: "post" }), /policy denies/);
  assert.throws(() => hardPolicy({ where: "friends", is_dm: true, recipient_known: false }), /strangers/);
});

test("watcher-style diff emits a new label exactly once", () => {
  const a = compressSource(xml(), "com.test");
  const b = compressSource(xml(`<XCUIElementTypeStaticText type="XCUIElementTypeStaticText" label="new message" x="1" y="1" width="100" height="20"/>`), "com.test");
  assert.deepEqual(newLabels(a, b), ["new message"]);
  assert.deepEqual(newLabels(b, b), []);
});
