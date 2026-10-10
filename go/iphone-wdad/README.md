# iphone-wdad

One static Go binary that supervises WebDriverAgent on a USB iPhone. It watches usbmux for a device,
starts a **rootless userspace tunnel** with the [go-ios](https://github.com/danielpaulus/go-ios)
library, runs WebDriverAgent over testmanagerd, and serves WDA and MJPEG to the owner over the
private Unix sockets `wda.sock` / `mjpeg.sock` in `$XDG_RUNTIME_DIR/iphone-agent/` (0600), publishing
state there too. The unit runs with `PrivateNetwork=yes`, so the userspace tunnel's internal
localhost listener is isolated in its own network namespace and unreachable by other local users.

## Build

```bash
cd go/iphone-wdad
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o iphone-wdad .
```

go-ios is pinned to upstream commit `77873fe` (`v1.3.3-0.20260924075417-77873fe353fc`); `go build`
fetches it from the module proxy — no local checkout needed.

## Run

The supervisor must run inside a private network namespace (`PrivateNetwork=yes`) so the userspace
tunnel's internal localhost listener is not exposed to other local users. Run it through the user
service, or — for development — via `systemd-run`, never as a bare `./iphone-wdad`:

```bash
# Normal use: the installed user service (already PrivateNetwork=yes). See ## systemd below.
systemctl --user start iphone-wdad.service

# Development, without installing the unit — still isolated:
systemd-run --user -p PrivateNetwork=yes --pty \
  ./iphone-wdad -runner com.facebook.WebDriverAgentRunner.xctrunner.<YOUR_TEAM_ID>
```

The runner bundle id ends in **your** Apple Team ID — the one the WDA IPA was signed with. Pass it with
`-runner` or set `IPHONE_WDA_RUNNER`. State is written to `$XDG_RUNTIME_DIR/iphone-agent/`:

- `wda.json` — `{state: no_phone|starting|ready|error, message, since}` (atomic, 0600)
- `apps.json` — `[{name, bundle}]`, User + System, non-hidden, sorted (atomic, 0600)

Logs go to stderr and never contain screen content.

## Design

- **No root, no TUN.** `tunnel.ConnectUserSpaceTunnelLockdown` runs a gVisor userspace stack in-process;
  clients reach the device through a localhost listener, not a system interface.
- **Existing pairing only.** The binary calls `ios.ReadPairRecord` and fails with a clear error if the
  device is not paired; it never creates a pair record.
- **WDA via testmanagerd** (`testmanagerd.RunTestWithConfig`), runner
  `com.facebook.WebDriverAgentRunner.xctrunner.<YOUR_TEAM_ID>`, xctestconfig `WebDriverAgentRunner.xctest`.
- **Self-healing loop:** no device → `no_phone`; attach failure → `error`; an unplug watchdog cancels the
  run and the loop waits for the next device.
- Forwarding is a small proxy over usbmux that serves WDA/MJPEG on the owner-only Unix sockets above;
  with `PrivateNetwork=yes` the tunnel's internal localhost listener stays inside the unit's namespace.

## systemd

`iphone-wdad.service` runs it as a user service; its `ExecStart` points at the installed plugin path. To use it:

```bash
systemctl --user link ~/.config/omarchy/plugins/areu01or00.piphone/go/iphone-wdad/iphone-wdad.service
systemctl --user enable --now iphone-wdad.service
```

## Device notes

Developed against iPhone on iOS 27 (non-jailbroken, free-Apple-ID signed WDA) over USB. On a different
iOS/Xcode combination, re-check the testmanagerd launch path (iOS 17+ Xcode 15 route) and `/status`
readiness before relying on it.
