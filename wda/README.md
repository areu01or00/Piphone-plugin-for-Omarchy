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

`wda/resign.sh` wraps that one command: it finds the attached device, runs
`xtool install`, and prints the post-install steps below. It takes `XTOOL`,
`IPHONE_WDA_IPA`, and `IPHONE_WDA_UDID` overrides:

```bash
IPHONE_WDA_IPA=/path/to/WDA.ipa ./resign.sh
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

## History: Impactor

Before Apple's 2026 anisette change (`-80045`) broke the GSA login for Impactor /
AltStore / Sideloadly, the profile was renewed interactively in Impactor and re-signed
with a local key. `resign.sh` wraps xtool now; the old local-key flow is kept in git
history. No signing key material is ever copied into this repository.
