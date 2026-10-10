# C tools (libc only)

- **`phone`** (~420 lines, 44 KB): the one-action WDA CLI (`screen | tap REF | type REF TEXT | scroll up|down |
  open APP | home | look`), with the same outline format as `bin/phone`: full-depth source, noise and
  parent/child dedupe, `(offscreen)` tags, generation refs, outward-tap refusal, and exact-readback typing
  (`/wda/keys`; WDA's setPasteboard is a no-op on a real device). State lives in `$XDG_RUNTIME_DIR/iphone-agent/cphone.state` (0600).
  Measured: 20 ms vs 390 ms per call on a 1000-element stand-in screen (process startup + parse). **On the real
  iPhone (iOS 27, 2026-10-01)**: home 1.0 s, open X 0.9 s, taps 1.1–1.4 s, typing `test 😭 नमस्ते` exact in 3.1 s;
  warm Node `bin/phone` taps 1.4–1.5 s, so the device dominates and C saves the ~0.4–0.7 s of Node startup per
  call. The agent's in-process tools don't pay that startup, so this is a CLI win, not an agent win.
- **`mjpeg-tap`** (~90 lines, 17 KB): reads WDA's MJPEG stream (127.0.0.1:9100) and atomically publishes only the
  newest frame to `$XDG_RUNTIME_DIR/iphone-agent/frame.jpg` at ≤ N fps. The panel's LiveView now reloads that
  tmpfs file instead of pulling a full-resolution PNG `/screenshot` every 0.9 s. `wda_up.py` now also forwards 9100.

Build: `make -C c`. Verified on the phone: phone CLI end to end. Not yet: the MJPEG stream from our WDA build (needs the 9100 forward).
