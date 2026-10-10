// phone — one action per call against WebDriverAgent on 127.0.0.1:8100.
// Pure C (libc only). Same verbs and outline format as bin/phone; state (WDA session,
// bundle, generation, latest refs) persists in $XDG_RUNTIME_DIR/iphone-agent/cphone.state.
//
//   phone screen | tap REF | type REF TEXT | scroll up|down | open APP|BUNDLE | home | look
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define EXCLUDED "visible,accessible,enabled,index,focused,placeholderValue,hittable"
#define LABEL_CAP 1000

typedef struct { char *p; size_t n, cap; } buf;
typedef struct { int ref; char type[48]; double x, y, w, h; char *label, *value; int off; } elem;

static char session[128], bundle[256], state_path[512], dir[480];
static int generation, screen_w = 393, screen_h = 852;
static elem *els; static int nels;

static void die(const char *fmt, ...) {
  va_list ap; va_start(ap, fmt); fputs("error: ", stderr); vfprintf(stderr, fmt, ap); fputc('\n', stderr); exit(1);
}
static void bput(buf *b, const char *s, size_t n) {
  if (b->n + n + 1 > b->cap) { b->cap = (b->n + n + 1) * 2; b->p = realloc(b->p, b->cap); }
  memcpy(b->p + b->n, s, n); b->n += n; b->p[b->n] = 0;
}
static void bputs(buf *b, const char *s) { bput(b, s, strlen(s)); }
static void bprintf(buf *b, const char *fmt, ...) {
  char *s; va_list ap; va_start(ap, fmt); int n = vasprintf(&s, fmt, ap); va_end(ap); bput(b, s, n); free(s);
}
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
static void sleep_ms(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }

// ── HTTP (plain, over the owner-only WDA Unix socket) ─────────────────────
static int http(const char *method, const char *path, const char *body, buf *out) {
  char sp[512];
  const char *env = getenv("IPHONE_WDA_SOCK");
  const char *rt = getenv("XDG_RUNTIME_DIR");
  if (env) snprintf(sp, sizeof sp, "%s", env);
  else if (rt) snprintf(sp, sizeof sp, "%s/iphone-agent/wda.sock", rt);
  else snprintf(sp, sizeof sp, "/run/user/%d/iphone-agent/wda.sock", getuid());
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un a = { .sun_family = AF_UNIX };
  strncpy(a.sun_path, sp, sizeof a.sun_path - 1);
  struct timeval tv = { 30, 0 }; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  if (connect(fd, (void *)&a, sizeof a)) die("WDA not reachable at %s (is the phone plugged in?)", sp);
  buf req = {0}; size_t bl = body ? strlen(body) : 0;
  bprintf(&req, "%s %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n", method, path);
  if (body) bprintf(&req, "Content-Type: application/json\r\nContent-Length: %zu\r\n", bl);
  bputs(&req, "\r\n"); if (body) bput(&req, body, bl);
  for (size_t off = 0; off < req.n;) { ssize_t w = write(fd, req.p + off, req.n - off); if (w <= 0) die("write failed"); off += w; }
  free(req.p);
  // WDA may keep the socket open despite Connection: close, so stop at Content-Length.
  buf raw = {0}; char chunk[65536]; ssize_t r; long want = -1; size_t hdr = 0;
  while ((r = read(fd, chunk, sizeof chunk)) > 0) {
    bput(&raw, chunk, r);
    if (!hdr) { char *e = strstr(raw.p, "\r\n\r\n"); if (e) { hdr = e + 4 - raw.p;
      char *cl = strcasestr(raw.p, "\r\nContent-Length:"); if (cl && cl < e) want = atol(cl + 17); } }
    if (hdr && want >= 0 && raw.n >= hdr + (size_t)want) break;
  }
  close(fd);
  if (!raw.p) die("empty reply from WDA for %s", path);
  int status = atoi(strchr(raw.p, ' ') ? strchr(raw.p, ' ') + 1 : "0");
  char *hdr_end = strstr(raw.p, "\r\n\r\n"); char *b = hdr_end ? hdr_end + 4 : raw.p + raw.n;
  out->n = 0;
  if (hdr_end && memmem(raw.p, hdr_end - raw.p, "chunked", 7)) {   // de-chunk
    while (*b) { long len = strtol(b, &b, 16); b = strstr(b, "\r\n"); if (!b || len <= 0) break; b += 2; bput(out, b, len); b += len + 2; }
  } else bput(out, b, raw.p + raw.n - b);
  if (!out->p) bput(out, "", 0);
  free(raw.p); return status;
}

// ── JSON: just enough to read WDA replies and write requests ──────────────
static void utf8(buf *o, unsigned cp) {
  char s[4]; int n;
  if (cp < 0x80) { s[0] = cp; n = 1; }
  else if (cp < 0x800) { s[0] = 0xC0 | cp >> 6; s[1] = 0x80 | (cp & 63); n = 2; }
  else if (cp < 0x10000) { s[0] = 0xE0 | cp >> 12; s[1] = 0x80 | (cp >> 6 & 63); s[2] = 0x80 | (cp & 63); n = 3; }
  else { s[0] = 0xF0 | cp >> 18; s[1] = 0x80 | (cp >> 12 & 63); s[2] = 0x80 | (cp >> 6 & 63); s[3] = 0x80 | (cp & 63); n = 4; }
  bput(o, s, n);
}
// Returns malloc'd unescaped string value of the first "key", or NULL.
static char *jstr(const char *json, const char *key) {
  char pat[64]; snprintf(pat, sizeof pat, "\"%s\"", key);
  const char *p = strstr(json, pat); if (!p) return 0;
  p += strlen(pat); while (*p == ' ' || *p == ':' || *p == '\n' || *p == '\t') p++;
  if (*p != '"') return 0;
  buf o = {0}; bputs(&o, "");
  for (p++; *p && *p != '"'; p++) {
    if (*p != '\\') { bput(&o, p, 1); continue; }
    switch (*++p) {
      case 'n': bputs(&o, "\n"); break; case 't': bputs(&o, "\t"); break;
      case 'r': break; case 'b': case 'f': break;
      case 'u': { unsigned cp = strtoul((char[5]){p[1], p[2], p[3], p[4], 0}, 0, 16); p += 4;
        if (cp >= 0xD800 && cp < 0xDC00 && p[1] == '\\' && p[2] == 'u') {
          unsigned lo = strtoul((char[5]){p[3], p[4], p[5], p[6], 0}, 0, 16); p += 6;
          cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); }
        utf8(&o, cp); break; }
      default: bput(&o, p, 1);
    }
  }
  return o.p;
}
static void jesc(buf *b, const char *s) {
  bput(b, "\"", 1);
  for (; *s; s++) {
    if (*s == '"' || *s == '\\') { bput(b, "\\", 1); bput(b, s, 1); }
    else if ((unsigned char)*s < 0x20) bprintf(b, "\\u%04x", *s);
    else bput(b, s, 1);
  }
  bput(b, "\"", 1);
}
static void wda_check(int status, buf *r, const char *what) {
  char *err = strstr(r->p, "\"error\"") ? jstr(r->p, "message") : 0;
  if (status >= 300 || err) die("%s: %s", what, err ? err : r->p);
}

// ── State ────────────────────────────────────────────────────────────────
static void clean(char *s) {   // collapse whitespace runs (incl. newlines/tabs) to one space, trim
  char *w = s; int sp = 1;
  for (char *r = s; *r; r++) { int ws = *r == ' ' || *r == '\t' || *r == '\n' || *r == '\r';
    if (ws) { if (!sp) *w++ = ' '; sp = 1; } else { *w++ = *r; sp = 0; } }
  if (w > s && w[-1] == ' ') { w--; }
  *w = 0;
}
static void load_state(void) {
  FILE *f = fopen(state_path, "r"); if (!f) return;
  char *line = 0; size_t cap = 0;
  if (getline(&line, &cap, f) > 0) sscanf(line, "%127[^\t]\t%255[^\t]\t%d\t%d\t%d", session, bundle, &generation, &screen_w, &screen_h);
  if (!strcmp(session, "-")) session[0] = 0;
  while (getline(&line, &cap, f) > 0) {
    els = realloc(els, sizeof *els * (nels + 1)); elem *e = &els[nels]; memset(e, 0, sizeof *e);
    char *t = line; e->ref = atoi(strsep(&t, "\t")); snprintf(e->type, sizeof e->type, "%s", strsep(&t, "\t"));
    e->x = atof(strsep(&t, "\t")); e->y = atof(strsep(&t, "\t")); e->w = atof(strsep(&t, "\t")); e->h = atof(strsep(&t, "\t"));
    e->off = atoi(strsep(&t, "\t")); char *l = strsep(&t, "\t"), *v = strsep(&t, "\n");
    e->label = strdup(l ? l : ""); e->value = strdup(v ? v : ""); nels++;
  }
  free(line); fclose(f);
}
static void save_state(void) {
  char tmp[600]; snprintf(tmp, sizeof tmp, "%s.tmp", state_path);
  int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600); if (fd < 0) die("cannot write %s", tmp);
  FILE *f = fdopen(fd, "w");
  fprintf(f, "%s\t%s\t%d\t%d\t%d\n", session[0] ? session : "-", bundle[0] ? bundle : "-", generation, screen_w, screen_h);
  for (int i = 0; i < nels; i++) { elem *e = &els[i];
    fprintf(f, "%d\t%s\t%g\t%g\t%g\t%g\t%d\t%s\t%s\n", e->ref, e->type, e->x, e->y, e->w, e->h, e->off, e->label, e->value); }
  fclose(f); rename(tmp, state_path);
}

// ── WDA session bound to the foreground app ───────────────────────────────
static void active_app(char *out, size_t n) {
  buf r = {0}; wda_check(http("GET", "/wda/activeAppInfo", 0, &r), &r, "activeAppInfo");
  char *b = jstr(r.p, "bundleId"); snprintf(out, n, "%s", b ? b : "unknown"); free(b); free(r.p);
}
static void new_session(const char *want) {
  buf r = {0}, body = {0};
  if (session[0]) { char p[200]; snprintf(p, sizeof p, "/session/%s", session); http("DELETE", p, 0, &r); }
  bputs(&body, "{\"capabilities\":{\"alwaysMatch\":{");
  if (strcmp(want, "com.apple.springboard")) { bputs(&body, "\"bundleId\":"); jesc(&body, want); bputs(&body, ","); }
  bputs(&body, "\"shouldWaitForQuiescence\":false,\"waitForIdleTimeout\":0,\"forceAppLaunch\":false,\"shouldTerminateApp\":false}}}");
  wda_check(http("POST", "/session", body.p, &r), &r, "create session");
  char *id = jstr(r.p, "sessionId"); if (!id) die("WDA returned no session id");
  snprintf(session, sizeof session, "%s", id); snprintf(bundle, sizeof bundle, "%s", want); free(id);
  char p[200]; snprintf(p, sizeof p, "/session/%s/appium/settings", session);
  http("POST", p, "{\"settings\":{\"waitForIdleTimeout\":0,\"animationCoolOffTimeout\":0,\"snapshotMaxDepth\":200}}", &r);
  free(r.p); free(body.p);
}
static void ensure(void) {
  char fg[256]; active_app(fg, sizeof fg);
  if (!session[0] || strcmp(fg, bundle)) new_session(fg);
}
// Session-scoped request with one transparent re-create on an invalid session.
static int sreq(const char *method, const char *suffix, const char *body, buf *out) {
  for (int attempt = 0; attempt < 2; attempt++) {
    char p[2048]; snprintf(p, sizeof p, "/session/%s%s", session, suffix);
    int s = http(method, p, body, out);
    if (!(s == 404 && strstr(out->p, "invalid session")) || attempt) return s;
    session[0] = 0; ensure();
  }
  return 0;
}

// ── Source → compact outline ──────────────────────────────────────────────
static char *xml_unescape(const char *s, size_t n) {
  buf o = {0}; bputs(&o, "");
  for (size_t i = 0; i < n; i++) {
    if (s[i] != '&') { bput(&o, s + i, 1); continue; }
    const char *semi = memchr(s + i, ';', n - i); if (!semi) { bput(&o, s + i, 1); continue; }
    size_t len = semi - (s + i) + 1; const char *e = s + i;
    if (!strncmp(e, "&amp;", 5)) bputs(&o, "&"); else if (!strncmp(e, "&quot;", 6)) bputs(&o, "\"");
    else if (!strncmp(e, "&apos;", 6)) bputs(&o, "'"); else if (!strncmp(e, "&lt;", 4)) bputs(&o, "<");
    else if (!strncmp(e, "&gt;", 4)) bputs(&o, ">");
    else if (e[1] == '#') utf8(&o, e[2] == 'x' ? strtoul(e + 3, 0, 16) : strtoul(e + 2, 0, 10));
    else { bput(&o, e, len); }
    i += len - 1;
  }
  return o.p;
}
static char *attr(const char *tag, const char *end, const char *name) {
  char pat[32]; int pl = snprintf(pat, sizeof pat, " %s=\"", name);
  const char *p = memmem(tag, end - tag, pat, pl); if (!p) return 0;
  p += pl; const char *q = memchr(p, '"', end - p); if (!q) return 0;
  return xml_unescape(p, q - p);
}
static int asset_noise(const char *l) {
  if (!strncmp(l, "system-icons_", 13)) return 1;
  const char *u = strrchr(l, '_'); if (!u) return 0;           // …_24x24
  const char *x = strchr(u, 'x'); if (!x || x == u + 1 || !x[1]) return 0;
  for (const char *c = u + 1; *c; c++) if (!isdigit((unsigned char)*c) && c != x) return 0;
  return 1;
}
static void cap_utf8(char *s) {
  size_t n = strlen(s); if (n <= LABEL_CAP) return;
  n = LABEL_CAP; while (n && ((unsigned char)s[n] & 0xC0) == 0x80) n--; s[n] = 0;
}
static void compress(const char *xml) {
  for (int i = 0; i < nels; i++) { free(els[i].label); free(els[i].value); }
  nels = 0; generation++;
  int first = 1;
  for (const char *p = xml; (p = strstr(p, "<XCUIElementType")); ) {
    const char *end = strchr(p, '>'); if (!end) break;
    const char *tn = p + 16; size_t tl = strcspn(tn, " />");
    char *label = attr(p, end, "label"), *name = attr(p, end, "name"), *value = attr(p, end, "value");
    char *xs = attr(p, end, "x"), *ys = attr(p, end, "y"), *ws = attr(p, end, "width"), *hs = attr(p, end, "height");
    double x = xs ? atof(xs) : 0, y = ys ? atof(ys) : 0, w = ws ? atof(ws) : 0, h = hs ? atof(hs) : 0;
    if (first) { if (w > 0 && h > 0) { screen_w = w; screen_h = h; } first = 0; }
    char *l = label && *label ? label : (name && *name ? name : "");
    char *v = value ? value : "";
    int keep = (*l || *v) && w > 0 && h > 0 && !(*l && asset_noise(l));
    if (keep && nels && !strcmp(els[nels - 1].label, l) && !strcmp(els[nels - 1].value, v)) keep = 0;  // parent/child repeat
    if (keep) {
      els = realloc(els, sizeof *els * (nels + 1)); elem *e = &els[nels];
      e->ref = generation * 10000 + nels + 1; snprintf(e->type, sizeof e->type, "%.*s", (int)tl, tn);
      e->x = x; e->y = y; e->w = w; e->h = h;
      e->off = x + w <= 0 || y + h <= 0 || x >= screen_w || y >= screen_h;
      e->label = strdup(l); e->value = strdup(!strcmp(v, l) ? "" : v);
      clean(e->label); clean(e->value); cap_utf8(e->label); cap_utf8(e->value); nels++;
    }
    free(label); free(name); free(value); free(xs); free(ys); free(ws); free(hs);
    p = end;
  }
}
static void q(buf *o, const char *s) { for (; *s; s++) bput(o, *s == '"' ? "'" : s, 1); }
static void print_outline(void) {
  uint64_t h = 1469598103934665603ULL; buf o = {0};
  for (int i = 0; i < nels; i++) { elem *e = &els[i];
    bprintf(&o, "[%d] %s", e->ref, e->type);
    if (*e->label) { bputs(&o, " \""); q(&o, e->label); bputs(&o, "\""); }
    if (*e->value) { bputs(&o, " = \""); q(&o, e->value); bputs(&o, "\""); }
    if (e->off) bputs(&o, " (offscreen)");
    bputs(&o, "\n");
  }
  for (size_t i = 0; i < o.n; i++) h = (h ^ (unsigned char)o.p[i]) * 1099511628211ULL;
  printf("App: %s\nFingerprint: %016llx\n%s", bundle, (unsigned long long)h, o.p ? o.p : "(no useful elements)\n");
  free(o.p);
}
static void screen(void) {
  ensure(); buf r = {0};
  wda_check(sreq("GET", "/source?excluded_attributes=" EXCLUDED, 0, &r), &r, "source");
  char *xml = jstr(r.p, "value"); if (!xml) die("no source in reply");
  compress(xml); free(xml); free(r.p);
}

// ── Actions ──────────────────────────────────────────────────────────────
static elem *ref(int n) {
  for (int i = 0; i < nels; i++) if (els[i].ref == n) return &els[i];
  die("stale or unknown ref %d; run `phone screen` and use its latest refs", n); return 0;
}
static int word(const char *hay, const char *w) {
  size_t n = strlen(w);
  for (const char *p = hay; (p = strcasestr(p, w)); p++)
    if ((p == hay || !isalnum((unsigned char)p[-1])) && !isalnum((unsigned char)p[n])) return 1;
  return 0;
}
static void refuse_outward(elem *e) {
  static const char *w[] = {"send","post","publish","reply","tweet","buy","pay","order","checkout","delete","remove",
    "subscribe","follow","unfollow","block","transfer","confirm","accept","install","join","leave",0};
  for (int i = 0; w[i]; i++) if (word(e->label, w[i]) || word(e->value, w[i]))
    die("outward/destructive control \"%s\" refused; posting goes through phone_post with approval", e->label);
}
static void tap_xy(double x, double y) {
  buf r = {0}; char b[96]; snprintf(b, sizeof b, "{\"x\":%.1f,\"y\":%.1f}", x, y);
  wda_check(sreq("POST", "/wda/tap", b, &r), &r, "tap"); free(r.p);
}
static void tap(elem *e) {
  int dup = 0; for (int i = 0; i < nels; i++) dup += !strcmp(els[i].label, e->label);
  if (*e->label && dup == 1) {   // unique label: element click (fast on busy screens)
    buf q = {0}, r = {0}; char lab[LABEL_CAP * 2 + 64];
    size_t k = 0; for (const char *s = e->label; *s && k < sizeof lab - 4; s++) { if (*s == '\'' || *s == '\\') lab[k++] = '\\'; lab[k++] = *s; } lab[k] = 0;
    char pred[sizeof lab + 96]; snprintf(pred, sizeof pred, "type == 'XCUIElementType%s' AND label == '%s'", e->type, lab);
    bputs(&q, "{\"using\":\"predicate string\",\"value\":"); jesc(&q, pred); bputs(&q, "}");
    if (sreq("POST", "/element", q.p, &r) < 300) {
      char *id = jstr(r.p, "ELEMENT");
      if (id) { char s[200]; snprintf(s, sizeof s, "/element/%s/click", id); buf c = {0};
        int st = sreq("POST", s, "{}", &c); free(c.p); free(id); free(q.p); free(r.p); if (st < 300) return; }
    }
    free(q.p); free(r.p);
  }
  tap_xy(e->x + e->w / 2, e->y + e->h / 2);   // duplicate/empty label or click failed
}
static size_t b64dec(unsigned char *o, const char *s) {
  size_t n = 0; unsigned v = 0; int bits = 0;
  for (; *s; s++) { const char *t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const char *c = strchr(t, *s); if (!c || *s == '=') continue;
    v = v << 6 | (c - t); bits += 6; if (bits >= 8) { bits -= 8; o[n++] = v >> bits & 0xFF; } }
  return n;
}
static char *focused_id(void) { buf r = {0}; char *id = sreq("GET", "/element/active", 0, &r) < 300 ? jstr(r.p, "ELEMENT") : 0; free(r.p); return id; }
static void type(elem *e, const char *text) {
  if (e->off) die("field is offscreen; scroll it into view first");
  char before[256], after[256]; active_app(before, sizeof before);
  tap_xy(e->x + e->w / 2, e->y + e->h / 2 < 70 ? 70 : e->y + e->h / 2);
  active_app(after, sizeof after); if (strcmp(before, after)) die("tap moved focus from %s to %s; nothing typed", before, after);
  char *id = 0; for (double t0 = now_ms(); !id && now_ms() - t0 < 2000; ) { id = focused_id(); if (!id) sleep_ms(150); }
  if (!id) die("no keyboard focus after tapping the field; nothing typed");
  char p[256]; buf r = {0}, body = {0}; snprintf(p, sizeof p, "/element/%s/clear", id); sreq("POST", p, "{}", &r);
  // /wda/keys is the real-device path: WDA's setPasteboard writes nothing on a real iPhone.
  const char *via = "keys"; bputs(&body, "{\"value\":[");
  for (const unsigned char *s = (const unsigned char *)text; *s; ) {   // one code point per item
    int l = *s < 0x80 ? 1 : *s < 0xE0 ? 2 : *s < 0xF0 ? 3 : 4; char cp[5] = {0}; memcpy(cp, s, l);
    if (s != (const unsigned char *)text) { bputs(&body, ","); }
    jesc(&body, cp); s += l; }
  bputs(&body, "]}"); sreq("POST", "/wda/keys", body.p, &r);
  sleep_ms(300);
  snprintf(p, sizeof p, "/element/%s/attribute/value", id); sreq("GET", p, 0, &r);
  char *got = jstr(r.p, "value");
  active_app(after, sizeof after); if (strcmp(before, after)) die("typing escaped %s into %s", before, after);
  printf("exact=%s via=%s value=\"%s\"\n", got && !strcmp(got, text) ? "true" : "false", via, got ? got : "");
  free(got); free(id); free(r.p); free(body.p);
}
static const char *app_bundle(const char *name) {
  static const char *m[][2] = {{"x","com.atebits.Tweetie2"},{"twitter","com.atebits.Tweetie2"},{"discord","com.hammerandchisel.discord"},
    {"linkedin","com.linkedin.LinkedIn"},{"settings","com.apple.Preferences"},{"messages","com.apple.MobileSMS"},
    {"safari","com.apple.mobilesafari"},{"mail","com.apple.mobilemail"},{"files","com.apple.DocumentsApp"},
    {"whatsapp","net.whatsapp.WhatsApp"},{"photos","com.apple.mobileslideshow"},{0,0}};
  for (int i = 0; m[i][0]; i++) if (!strcasecmp(m[i][0], name)) return m[i][1];
  if (strchr(name, '.')) return name;   // raw bundle id
  die("unknown app %s (pass a bundle id)", name); return 0;
}

int main(int argc, char **argv) {
  const char *rt = getenv("XDG_RUNTIME_DIR"); char fb[64]; snprintf(fb, sizeof fb, "/run/user/%d", getuid());
  snprintf(dir, sizeof dir, "%s/iphone-agent", rt ? rt : fb); mkdir(dir, 0700);
  snprintf(state_path, sizeof state_path, "%s/cphone.state", dir);
  if (argc < 2) die("usage: phone {screen|tap REF|type REF TEXT|scroll up|down|open APP|home|look}");
  const char *cmd = argv[1]; double t0 = now_ms(); buf r = {0};
  load_state();
  if (!strcmp(cmd, "screen")) screen();
  else if (!strcmp(cmd, "tap") && argc == 3) { elem *e = ref(atoi(argv[2])); refuse_outward(e); ensure(); tap(e); screen(); }
  else if (!strcmp(cmd, "type") && argc >= 4) {
    buf t = {0}; for (int i = 3; i < argc; i++) { if (i > 3) bputs(&t, " "); bput(&t, argv[i], strlen(argv[i])); }
    elem *e = ref(atoi(argv[2])); ensure(); type(e, t.p); screen(); free(t.p);
  } else if (!strcmp(cmd, "scroll") && argc == 3 && (!strcmp(argv[2], "up") || !strcmp(argv[2], "down"))) {
    ensure(); int up = !strcmp(argv[2], "up"); char b[160];
    snprintf(b, sizeof b, "{\"fromX\":%d,\"fromY\":%d,\"toX\":%d,\"toY\":%d,\"duration\":0.25}", screen_w / 2,
             up ? screen_h * 3 / 10 : screen_h * 7 / 10, screen_w / 2, up ? screen_h * 7 / 10 : screen_h * 3 / 10);
    wda_check(sreq("POST", "/wda/dragfromtoforduration", b, &r), &r, "scroll"); screen();
  } else if (!strcmp(cmd, "open") && argc == 3) {
    const char *b = app_bundle(argv[2]); buf body = {0}; bputs(&body, "{\"bundleId\":"); jesc(&body, b); bputs(&body, "}");
    wda_check(http("POST", "/wda/apps/launchUnattached", body.p, &r), &r, "launch"); free(body.p);
    for (int i = 0; i < 30; i++) { char fg[256]; active_app(fg, sizeof fg); if (!strcmp(fg, b)) break; sleep_ms(100); }
    screen();
  } else if (!strcmp(cmd, "home")) {
    wda_check(http("POST", "/wda/homescreen", "{}", &r), &r, "home"); session[0] = 0; bundle[0] = 0; sleep_ms(300); screen();
  } else if (!strcmp(cmd, "look")) {
    wda_check(http("GET", "/screenshot", 0, &r), &r, "screenshot");
    char *b64 = jstr(r.p, "value"); if (!b64) die("no screenshot data");
    unsigned char *png = malloc(strlen(b64)); size_t n = b64dec(png, b64);
    char path[600]; snprintf(path, sizeof path, "%s/cli-look.png", dir);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600); if (fd < 0 || write(fd, png, n) != (ssize_t)n) die("cannot write %s", path);
    close(fd); printf("screenshot=%s\n", path); free(png); free(b64); save_state(); return 0;
  } else die("usage: phone {screen|tap REF|type REF TEXT|scroll up|down|open APP|home|look}");
  save_state(); print_outline();
  if (getenv("PHONE_TIMING")) fprintf(stderr, "took %.1f ms\n", now_ms() - t0);
  free(r.p); return 0;
}
