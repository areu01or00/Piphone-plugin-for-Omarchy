#!/usr/bin/env bash
#
# install.sh — build and wire up the Piphone backend.
#
# The Omarchy shell plugin (bar widget + panel) is installed by
# `omarchy plugin add`. This script sets up the half Omarchy does not:
# the Go WebDriverAgent supervisor, the C diagnostic tools, the systemd
# user service, and the runtime data directory.
#
# Safe to re-run. It never touches credentials and never signs anything.

set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$repo"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. Dependency check -----------------------------------------------------
say "Checking dependencies"
missing=()
for bin in go cc make tmux jq systemctl wl-paste; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
command -v pi >/dev/null 2>&1 || warn "pi (the agent runtime) not found on PATH — the panel needs it to run sessions."
if ((${#missing[@]})); then
  die "missing required tools: ${missing[*]}  (install them, then re-run)"
fi

# --- 2. Build the Go WDA supervisor -----------------------------------------
say "Building go/iphone-wdad (static, no cgo)"
( cd go/iphone-wdad && CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags="-s -w" -o iphone-wdad . )
test -x go/iphone-wdad/iphone-wdad || die "go build did not produce the binary"

# --- 3. Build the C diagnostic tools ----------------------------------------
say "Building c/ tools (phone, mjpeg-tap)"
make -C c >/dev/null

# --- 4. Runtime data directory ----------------------------------------------
say "Creating runtime data directory"
mkdir -p "$HOME/.local/share/iphone-agent/pi-sessions"

# --- 5. systemd user service for the supervisor -----------------------------
# The unit's ExecStart points at this plugin's install location
# (~/.config/omarchy/plugins/areu01or00.piphone/...). Linking works only
# when the repo lives there, i.e. it was installed via `omarchy plugin add`.
unit="$repo/go/iphone-wdad/iphone-wdad.service"
expected="$HOME/.config/omarchy/plugins/areu01or00.piphone"
if [[ "$repo" == "$expected" ]]; then
  say "Linking and enabling the systemd user service"
  systemctl --user link "$unit"
  systemctl --user daemon-reload
  systemctl --user enable --now iphone-wdad.service
  say "Service status: $(systemctl --user is-active iphone-wdad.service || true)"
else
  warn "Repo is not at the plugin install path, so the systemd unit is not linked."
  warn "For development, run it in a private network namespace (as the unit does),"
  warn "so the go-ios tunnel's localhost listener isn't exposed to other local users:"
  warn "    systemd-run --user -p PrivateNetwork=yes --pty ./go/iphone-wdad/iphone-wdad"
fi

cat <<EOF

$(say "Backend ready.")

Still to do (one-time, on the iPhone side — cannot be automated):
  1. Sign WebDriverAgent with a free Apple ID and sideload it. See wda/README.md.
  2. A free provisioning profile expires after 7 days; re-sign with wda/resign.sh.
  3. Plug the iPhone in over USB and trust the computer.

Then open the Piphone panel from the Omarchy bar and give it a task.
EOF
