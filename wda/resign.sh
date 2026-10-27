#!/usr/bin/env bash
# Re-sign and reinstall WebDriverAgent with xtool when its free Apple
# provisioning profile expires (roughly weekly). Run `xtool auth login` once
# first; the token then lasts about a year. See wda/README.md for the gotchas
# this wraps (free 3-app limit, dev-cert trust, Developer Disk Image remount).
set -euo pipefail

xtool=${XTOOL:-xtool}
ipa=${IPHONE_WDA_IPA:-$HOME/.local/share/iphone-agent/wda/WDA.ipa}
udid=${IPHONE_WDA_UDID:-}
py=${PYMOBILEDEVICE3:-pymobiledevice3}

command -v "$xtool" >/dev/null 2>&1 || { echo "xtool not found. Install it (https://github.com/xtool-org/xtool) or set XTOOL=/path/to/xtool." >&2; exit 1; }
[[ -e $ipa ]] || { echo "WDA ipa not found: $ipa (set IPHONE_WDA_IPA)." >&2; exit 1; }

# Resolve the device UDID if not supplied. Best-effort parse of `xtool devices`,
# then pymobiledevice3; matches both modern (8-16 hex) and legacy (40 hex) forms.
udid_re='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9a-f]{40}'
if [[ -z $udid ]]; then
  udid=$("$xtool" devices 2>/dev/null | grep -oE "$udid_re" | head -1 || true)
fi
if [[ -z $udid ]] && command -v "$py" >/dev/null 2>&1; then
  udid=$("$py" usbmux list 2>/dev/null | grep -oE "$udid_re" | head -1 || true)
fi
[[ -n $udid ]] || { echo "No device UDID found. Plug in the iPhone, or set IPHONE_WDA_UDID." >&2; exit 1; }

# The free profile allows at most 3 installed apps; if that's the blocker, xtool
# prints "maximum number of installed apps" — uninstall one with
# `$py apps uninstall <bundle-id>` and re-run. xtool also offers to revoke an old
# signing certificate; answer yes.
echo "Signing + installing $ipa to $udid via xtool..."
"$xtool" install --udid "$udid" "$ipa"

cat <<'NOTE'

Installed. xtool namespaces the runner bundle id as
XTL-<YOUR_TEAM_ID>.com.facebook.WebDriverAgentRunner.xctrunner — make sure
IPHONE_WDA_RUNNER in your iphone-wdad systemd drop-in matches it.

If this was a fresh signature, TRUST the developer certificate on the phone:
Settings > General > VPN & Device Management > your Apple ID > Trust, or WDA
won't launch. After an iOS update/reboot also remount the Developer Disk Image:
  pymobiledevice3 mounter auto-mount

Then: systemctl --user restart iphone-wdad.service
NOTE
