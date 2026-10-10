# iphone-wdad

One static Go binary that supervises WebDriverAgent on a USB iPhone. It watches usbmux for a device,
starts a **rootless userspace tunnel** with the [go-ios](https://github.com/danielpaulus/go-ios)
library, runs WebDriverAgent over testmanagerd, forwards `127.0.0.1:8100` (WDA) and `:9100` (MJPEG),
and publishes state under `$XDG_RUNTIME_DIR/iphone-agent/`. It is the project's WDA supervisor
(superseding the `wda/wda_up.py` pymobiledevice3 path, which is kept as an alternative).

## Build

```bash
cd go/iphone-wdad
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o iphone-wdad .
```

go-ios is pinned to upstream commit `77873fe` (`v1.3.3-0.20260924075417-77873fe353fc`); `go build`
fetches it from the module proxy — no local checkout needed.

## Run

```bash
./iphone-wdad                                   # uses $IPHONE_WDA_RUNNER if set
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
- Forwarding is a small localhost-bound proxy over usbmux, so WDA HTTP is only exposed on loopback.

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
