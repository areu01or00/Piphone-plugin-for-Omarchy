// mjpeg-tap — keep only the latest frame of WDA's MJPEG stream (127.0.0.1:9100).
// Writes $XDG_RUNTIME_DIR/iphone-agent/frame.jpg atomically, at most FPS times a second
// (default 4), so a UI can show the phone live without asking WDA for PNG screenshots.
// Frames stay in tmpfs; nothing is logged. Reconnects with backoff. libc only.
//
//   mjpeg-tap [fps]        (IPHONE_MJPEG_PORT overrides 9100)
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static char out[512], tmp[520];
static volatile sig_atomic_t stop;
static void on_signal(int s) { (void)s; stop = 1; }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

static int dial(const char *sockpath) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un a = { .sun_family = AF_UNIX };
  strncpy(a.sun_path, sockpath, sizeof a.sun_path - 1);
  struct timeval tv = { 5, 0 }; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  if (connect(fd, (void *)&a, sizeof a)) { close(fd); return -1; }
  const char *req = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
  if (write(fd, req, strlen(req)) < 0) { close(fd); return -1; }
  return fd;
}

static void publish(const unsigned char *jpg, size_t n) {
  int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) return;
  if (write(fd, jpg, n) == (ssize_t)n) { close(fd); rename(tmp, out); } else close(fd);
}

int main(int argc, char **argv) {
  double fps = argc > 1 ? atof(argv[1]) : 4; if (fps <= 0) fps = 4;
  const char *rt = getenv("XDG_RUNTIME_DIR"); char dir[480];
  if (rt) snprintf(dir, sizeof dir, "%s/iphone-agent", rt); else snprintf(dir, sizeof dir, "/run/user/%d/iphone-agent", getuid());
  mkdir(dir, 0700); snprintf(out, sizeof out, "%s/frame.jpg", dir); snprintf(tmp, sizeof tmp, "%s.tmp", out);
  // MJPEG is served over the owner-only Unix socket (0600), not a loopback port.
  char sock[512];
  if (getenv("IPHONE_MJPEG_SOCK")) snprintf(sock, sizeof sock, "%s", getenv("IPHONE_MJPEG_SOCK"));
  else snprintf(sock, sizeof sock, "%s/mjpeg.sock", dir);
  signal(SIGINT, on_signal); signal(SIGTERM, on_signal);

  size_t cap = 4 << 20; unsigned char *b = malloc(cap);
  double last = 0; int backoff = 1;
  while (!stop) {
    int fd = dial(sock);
    if (fd < 0) { sleep(backoff); backoff = backoff < 8 ? backoff * 2 : 8; continue; }
    backoff = 1; size_t n = 0; ssize_t r;
    while (!stop && (r = read(fd, b + n, cap - n)) > 0) {
      n += r;
      // Scan for complete JPEGs (SOI FFD8 … EOI FFD9); keep only the newest.
      for (;;) {
        unsigned char *soi = memmem(b, n, "\xff\xd8", 2); if (!soi) { n = 0; break; }
        unsigned char *eoi = memmem(soi + 2, b + n - soi - 2, "\xff\xd9", 2);
        if (!eoi) { memmove(b, soi, n -= soi - b); break; }         // partial frame: keep it
        size_t len = eoi + 2 - soi;
        if (now() - last >= 1 / fps) { publish(soi, len); last = now(); }
        size_t used = eoi + 2 - b; memmove(b, b + used, n -= used);
      }
      if (n == cap) n = 0;                                            // garbage guard
    }
    close(fd);
  }
  unlink(tmp); free(b); return 0;
}
