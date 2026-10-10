#!/usr/bin/env bash
# Re-sign WDA after Impactor has renewed the provisioning profile.
set -euo pipefail
umask 077

runner=${IPHONE_WDA_RUNNER:-com.facebook.WebDriverAgentRunner.xctrunner.YOURTEAMID}
team=${IPHONE_WDA_TEAM:-YOURTEAMID}
work=${IPHONE_WDA_DIR:-$HOME/.local/share/iphone-agent/wda}
py=${PYMOBILEDEVICE3:-pymobiledevice3}
zsign=${ZSIGN:-$work/zsign-src/bin/zsign}
key=${IPHONE_WDA_KEY:-$HOME/.config/PlumeImpactor/keys/$team/key.pem}
ipa=${IPHONE_WDA_IPA:-$work/WDA.ipa}
out=$work/WDA-signed.ipa
profiles=$(mktemp -d)
trap 'rm -rf "$profiles"' EXIT

for file in "$py" "$zsign" "$key" "$ipa"; do [[ -e $file ]] || { echo "missing required file: $file" >&2; exit 1; }; done
cat <<'NOTE'
Impactor must first renew the free provisioning profile (normally every 7 days).
This script dumps that renewed profile, extracts its public certificate, signs WDA, and installs it.
NOTE
"$py" provision dump "$profiles" >/dev/null
profile=$(grep -l "$runner" "$profiles"/* 2>/dev/null | head -1 || true)
[[ -n $profile ]] || { echo "renewed WDA profile not found on phone" >&2; exit 1; }
cp "$profile" "$work/wda.mobileprovision"
openssl smime -inform der -verify -noverify -in "$profile" -out "$profiles/profile.plist" 2>/dev/null
python - "$profiles/profile.plist" "$work/cert.pem" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
open(sys.argv[2], "wb").write(p["DeveloperCertificates"][0])
PY
openssl x509 -inform der -in "$work/cert.pem" -out "$profiles/cert.pem" 2>/dev/null
mv "$profiles/cert.pem" "$work/cert.pem"
"$zsign" -k "$key" -c "$work/cert.pem" -m "$work/wda.mobileprovision" -b "$runner" -o "$out" "$ipa" >/dev/null
"$py" apps install "$out"
echo "WDA re-signed and installed. Private key material was not copied or logged."
