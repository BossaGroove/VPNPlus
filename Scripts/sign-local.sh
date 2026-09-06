#!/bin/bash
# Sign a locally built VPN Plus for testing on this machine.
#
# The release pipeline does this too, from secrets. This script exists because
# a system extension cannot be activated unsigned, so any hands-on test of the
# extension needs a real signature before it can start.
#
# Both provisioning profiles are required and are not in this repository.
#
#   Scripts/sign-local.sh <app.provisionprofile> <tunnel.provisionprofile> [built-app]
#
set -euo pipefail

# No apostrophes in these messages: inside ${var:?word} bash performs quote
# removal on word, so a lone ' opens a quoted string that swallows the
# following lines.
PROFILE_APP="${1:?path to the Developer ID provisioning profile for the app}"
PROFILE_EXT="${2:?path to the Developer ID provisioning profile for the extension}"

APP="${3:-}"
if [ -z "$APP" ]; then
  DERIVED=$(xcodebuild -project VPNPlus.xcodeproj -scheme VPNPlus \
    -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')
  APP="$DERIVED/VPN Plus.app"
fi
EXT="$APP/Contents/Library/SystemExtensions/VPNPlusTunnel.systemextension"

[ -d "$APP" ] || { echo "No app at: $APP" >&2; exit 1; }
[ -d "$EXT" ] || { echo "No extension inside: $APP" >&2; exit 1; }

IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application}"

echo "── embedding provisioning profiles"
# A restricted entitlement is only honoured when a profile embedded in that
# bundle allow-lists it, and each signing subject needs its own.
cp "$PROFILE_APP" "$APP/Contents/embedded.provisionprofile"
cp "$PROFILE_EXT" "$EXT/Contents/embedded.provisionprofile"

echo "── signing inside out"
# Order matters: an outer signature covers the inner ones, so re-signing
# anything inner afterwards invalidates the outer.
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
  --entitlements VPNPlusTunnel/VPNPlusTunnel.release.entitlements "$EXT"
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
  --entitlements VPNPlus/VPNPlus.release.entitlements "$APP"

echo "── verifying"
codesign --verify --deep --strict --verbose=2 "$APP"

for subject in "$APP" "$EXT"; do
  if codesign -d --entitlements - "$subject" 2>/dev/null | grep -q get-task-allow; then
    echo "get-task-allow present on $subject — notarization would reject this" >&2
    exit 1
  fi
  codesign -d --entitlements - "$subject" 2>/dev/null \
    | grep -q "packet-tunnel-provider-systemextension" \
    || { echo "$subject is missing the -systemextension entitlement" >&2; exit 1; }
done

echo
echo "Signed: $APP"
echo
echo "A system extension can only be activated from /Applications:"
echo "  cp -R \"$APP\" /Applications/"
echo "  open \"/Applications/VPN Plus.app\""
