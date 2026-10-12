#!/bin/bash
# verify-sync.sh — install icloud-secret (latest notarized release) on this Mac
# and verify a secret has synced via iCloud Keychain. Safe to re-run.
#
# Run it straight from GitHub (no clone, no typing commands):
#   curl -fsSL https://raw.githubusercontent.com/carterscode/icloud-secret/main/scripts/verify-sync.sh | bash
#
# Modes:
#   (default)  install + poll until the shared item syncs here
#   store      install + store a token HERE from the clipboard (seed the sync)
#              curl -fsSL .../verify-sync.sh | bash -s store
#
# Env: SECRET_NAME (default github-dotfiles)
set -uo pipefail

SECRET_NAME="${SECRET_NAME:-github-dotfiles}"
URL="https://github.com/carterscode/icloud-secret/releases/latest/download/icloud-secret-macos-universal.zip"
APP_DIR="$HOME/.local/share/icloud-secret"
APP="$APP_DIR/iCloudSecret.app"
BIN="$APP/Contents/MacOS/icloud-secret"
MODE="${1:-verify}"

log(){ printf '==> %s\n' "$*"; }

[ "$(uname -s)" = "Darwin" ] || { echo "macOS only."; exit 1; }

# 1. Install — keep the .app bundle intact (a bare binary gets SIGKILLed because
#    the provisioning profile that authorizes Keychain access lives in the bundle).
if [ ! -x "$BIN" ]; then
  log "Installing icloud-secret (latest release)…"
  t="$(mktemp -d)"
  curl -fsSL "$URL" -o "$t/ics.zip" || { echo "download failed"; exit 1; }
  ditto -xk "$t/ics.zip" "$t"
  mkdir -p "$APP_DIR" "$HOME/.local/bin"
  rm -rf "$APP"; ditto "$t/iCloudSecret.app" "$APP"
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  ln -sfn "$BIN" "$HOME/.local/bin/icloud-secret"
  rm -rf "$t"
  log "Installed -> ~/.local/bin/icloud-secret"
else
  log "icloud-secret already installed."
fi

# 2. store mode: seed the secret here from the clipboard, then exit.
if [ "$MODE" = "store" ]; then
  log "Storing '$SECRET_NAME' from the clipboard (copy your token first)…"
  if pbpaste | "$BIN" set "$SECRET_NAME"; then
    echo "✅ stored ($("$BIN" get "$SECRET_NAME" | wc -c | tr -d ' ') bytes). It will now sync to your other Macs."
  else
    echo "❌ store failed (see error above)."; exit 1
  fi
  exit 0
fi

# 3. verify mode: poll for the synced item (iCloud Keychain is eventually-consistent).
log "Looking for '$SECRET_NAME' (polling up to 5 min for iCloud Keychain to sync)…"
for i in $(seq 1 30); do
  out="$("$BIN" get "$SECRET_NAME" 2>/tmp/ics-verify.err)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    echo "✅ SYNCED — '$SECRET_NAME' is here (${#out} bytes). iCloud Keychain works end to end."
    exit 0
  fi
  err="$(cat /tmp/ics-verify.err 2>/dev/null)"
  if [ "$rc" -ge 128 ]; then
    echo "❌ binary was killed (signature/bundle problem). Reinstall keeping the .app intact."; exit 1
  fi
  case "$err" in
    *-25300*) printf '    [%2d/30] not synced yet… waiting 10s\n' "$i" ;;
    *-34018*) echo "❌ -34018 missing entitlement — not the signed/profiled binary. Reinstall."; exit 1 ;;
    *)        printf '    [%2d/30] %s\n' "$i" "${err:-no output}" ;;
  esac
  sleep 10
done

echo ""
echo "⏳ Not synced after 5 min. Check both Macs:"
echo "   System Settings → [your name] → iCloud → Passwords & Keychain = ON, same Apple ID."
echo "   Seed it on the Mac that has the token:  curl -fsSL .../verify-sync.sh | bash -s store"
echo "   Then re-run this on the other Mac."
exit 2
