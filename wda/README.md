# WebDriverAgent signing

The agent drives the phone through a **signed WebDriverAgent** runner. The Go
supervisor (`go/iphone-wdad/`) launches it and serves it to the owner over the
private Unix socket `$XDG_RUNTIME_DIR/iphone-agent/wda.sock` — nothing is exposed
on a network port.

A **free Apple ID** can sign it, but the provisioning profile lasts only **7 days**,
so you re-sign weekly.

## Signing with xtool (recommended)

[xtool](https://github.com/xtool-org/xtool) signs and installs the runner on Linux
using Apple Developer Services directly, so it does not depend on the GSA/anisette
login path that Apple's 2026 change broke for Impactor / AltStore / Sideloadly.

One-time — log in with your Apple ID (you get a 2FA code; the token lasts ~1 year):

```bash
xtool auth login
```

Each time the profile expires, re-install the IPA (`xtool devices` lists the UDID;
answer yes if it offers to revoke an old certificate):

```bash
xtool install --udid <YOUR_DEVICE_UDID> WDA.ipa
```

### Gotchas

- **xtool namespaces the bundle id.** The installed runner becomes
  `XTL-<YOUR_TEAM_ID>.com.facebook.WebDriverAgentRunner.xctrunner` (not the plain
  `com.facebook.WebDriverAgentRunner.xctrunner.<TEAM_ID>`). Set `IPHONE_WDA_RUNNER`
  in the systemd drop-in to that exact id, or the supervisor reports *"Did not find
  test app … Is it installed?"*. Confirm the id with
  `pymobiledevice3 apps list | grep -i webdriveragent`.
- **Free profile = max 3 apps.** If install fails with *"maximum number of installed
  apps"*, uninstall one first: `pymobiledevice3 apps uninstall <bundle-id>`.
- **Trust the developer certificate.** After a fresh signature WDA won't launch (the
  XCTest session times out) until you trust it on the phone: *Settings → General →
  VPN & Device Management → your Apple ID → Trust*.
- **Developer Disk Image.** Every iOS update or reboot unmounts the DDI; the
  supervisor then reports `testmanagerd … not available in RSD`. Re-mount it with
  `pymobiledevice3 mounter auto-mount` (no sudo; Developer Mode must be on).

Then restart the supervisor and it should go ready:

```bash
systemctl --user restart iphone-wdad.service
```

## Legacy: resign.sh (Impactor)

`resign.sh` is the original flow — renew the profile interactively in Impactor, then
re-sign with a local key. Apple's 2026 anisette change (`-80045`) broke Impactor's
login, so this path no longer works on its own; it is kept for reference in case that
path is restored. It never prints or copies the private key into this repository.
