#!/bin/bash
# Build + sign + notarize icloud-secret into a universal signed .app and a
# release zip. Run on a Mac with Xcode (or the Swift toolchain) and your Apple
# Developer signing identity. Used both locally and by CI (.github/workflows).
#
# Required:
#   TEAM_ID         10-char Apple Team ID
#   SIGN_IDENTITY   e.g. "Developer ID Application: Your Name (TEAM_ID)"
#   PROFILE         path to the Developer ID provisioning profile
# Notarization (one of):
#   NOTARY_API_KEY + NOTARY_KEY_ID + NOTARY_ISSUER   (App Store Connect .p8; CI)
#   NOTARY_PROFILE                                    (xcrun notarytool store-credentials; local)
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

TEAM_ID="${TEAM_ID:-GA9R7U8CJG}"   # Carter's Apple Team ID; override for forks
SIGN_IDENTITY="${SIGN_IDENTITY:?set SIGN_IDENTITY}"
PROFILE="${PROFILE:?set PROFILE (path to .provisionprofile)}"
MIN_MACOS="${MIN_MACOS:-12.0}"
[ -f "$PROFILE" ] || { echo "profile not found: $PROFILE" >&2; exit 1; }

BUILD="build"; APP="$BUILD/iCloudSecret.app"
rm -rf "$BUILD"; mkdir -p "$BUILD/arm64" "$BUILD/x86_64" "$APP/Contents/MacOS"

# Inject the real Team ID into build copies of the source + entitlements.
sed "s/TEAMID/$TEAM_ID/g" Sources/main.swift          > "$BUILD/main.swift"
sed "s/TEAMID/$TEAM_ID/g" icloud-secret.entitlements  > "$BUILD/entitlements.plist"

echo "==> Compiling universal (arm64 + x86_64)…"
xcrun swiftc -O -target "arm64-apple-macos$MIN_MACOS"  "$BUILD/main.swift" -o "$BUILD/arm64/icloud-secret"
xcrun swiftc -O -target "x86_64-apple-macos$MIN_MACOS" "$BUILD/main.swift" -o "$BUILD/x86_64/icloud-secret"
lipo -create "$BUILD/arm64/icloud-secret" "$BUILD/x86_64/icloud-secret" -output "$APP/Contents/MacOS/icloud-secret"

echo "==> Assembling bundle…"
cp Info.plist "$APP/Contents/Info.plist"
cp "$PROFILE"  "$APP/Contents/embedded.provisionprofile"

echo "==> Signing…"
codesign --force --timestamp --options runtime \
  --entitlements "$BUILD/entitlements.plist" \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

ZIP="$BUILD/icloud-secret-macos-universal.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${NOTARY_API_KEY:-}" ]; then
  echo "==> Notarizing (App Store Connect key)…"
  xcrun notarytool submit "$ZIP" \
    --key "$NOTARY_API_KEY" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip with the stapled ticket
elif [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarizing (stored notarytool profile)…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
else
  echo "==> Notarization SKIPPED (no NOTARY_API_KEY / NOTARY_PROFILE set)."
  echo "    The signed app works on THIS machine for testing. Other Macs will"
  echo "    Gatekeeper-block it until notarized — set creds and re-run before shipping."
fi

echo ""
echo "Built: $ZIP"
echo "  sha256: $(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "  team:   $TEAM_ID"
