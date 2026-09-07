#!/bin/bash
# Sign a locally built VPN Plus for testing on this machine.
#
# The release pipeline does this too, from secrets. This script exists because
# a system extension cannot be activated unsigned, so any hands-on test of the
# extension needs a real signature before it can start.
#
# Two modes, because the entitlement differs between them and a mismatch fails
# at activation rather than at build time:
#
#   --dev   Apple Development identity, the Debug build, the debug entitlements
#           (packet-tunnel-provider, no suffix), two macOS App Development
#           profiles. Not notarized, so an iteration is a build and a copy.
#   (none)  Developer ID identity, the Release build, the release entitlements
#           (…-systemextension), two Developer ID profiles. What ships; the
#           result must still be notarized before macOS will activate it.
#
# Both provisioning profiles are required and are not in this repository.
#
#   Scripts/sign-local.sh [--dev] <app.provisionprofile> <tunnel.provisionprofile> [built-app]
#
set -euo pipefail

MODE=release
if [ "${1:-}" = "--dev" ]; then MODE=dev; shift; fi

# No apostrophes in these messages: inside ${var:?word} bash performs quote
# removal on word, so a lone ' opens a quoted string that swallows the
# following lines.
PROFILE_APP="${1:?path to the provisioning profile for the app}"
PROFILE_EXT="${2:?path to the provisioning profile for the extension}"

case "$MODE" in
  dev)
    CONFIG=Debug
    IDENTITY="${CODESIGN_IDENTITY:-Apple Development}"
    ENT_APP=VPNPlus/VPNPlus.debug.entitlements
    ENT_EXT=VPNPlusTunnel/VPNPlusTunnel.debug.entitlements
    WANT=packet-tunnel-provider
    ;;
  release)
    CONFIG=Release
    IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application}"
    ENT_APP=VPNPlus/VPNPlus.release.entitlements
    ENT_EXT=VPNPlusTunnel/VPNPlusTunnel.release.entitlements
    WANT=packet-tunnel-provider-systemextension
    ;;
esac

APP="${3:-}"
if [ -z "$APP" ]; then
  DERIVED=$(xcodebuild -project VPNPlus.xcodeproj -scheme VPNPlus \
    -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')
  APP="$DERIVED/VPN Plus.app"
fi
EXT=$(ls -d "$APP"/Contents/Library/SystemExtensions/*.systemextension | head -1)

[ -d "$APP" ] || { echo "No app at: $APP" >&2; exit 1; }
[ -d "$EXT" ] || { echo "No extension inside: $APP" >&2; exit 1; }

echo "── $MODE: $CONFIG build, identity: $IDENTITY"

echo "── embedding provisioning profiles"
# A restricted entitlement is only honoured when a profile embedded in that
# bundle allow-lists it, and each signing subject needs its own.
cp "$PROFILE_APP" "$APP/Contents/embedded.provisionprofile"
cp "$PROFILE_EXT" "$EXT/Contents/embedded.provisionprofile"

echo "── signing inside out"
# Order matters: an outer signature covers the inner ones, so re-signing
# anything inner afterwards invalidates the outer.
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
  --entitlements "$ENT_EXT" "$EXT"
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
  --entitlements "$ENT_APP" "$APP"

echo "── verifying"
codesign --verify --deep --strict --verbose=2 "$APP"

for subject in "$APP" "$EXT"; do
  ENTS=$(codesign -d --entitlements - "$subject" 2>/dev/null)
  if [ "$MODE" = release ] && grep -q get-task-allow <<<"$ENTS"; then
    echo "get-task-allow present on $subject — notarization would reject this" >&2
    exit 1
  fi
  # The suffix must match the identity: a development identity cannot carry
  # the -systemextension value, and a Developer ID build must.
  if [ "$MODE" = dev ] && grep -q "packet-tunnel-provider-systemextension" <<<"$ENTS"; then
    echo "$subject carries the -systemextension entitlement, which a development build must not" >&2
    exit 1
  fi
  # Plain substring: codesign prints entitlements in a bracketed format on
  # current macOS, as XML on older ones. The dev-mode check above already
  # rejected the suffixed value, so a substring match is exact enough here.
  grep -q "$WANT" <<<"$ENTS" \
    || { echo "$subject is missing the $WANT entitlement" >&2; exit 1; }
done

echo
echo "Signed: $APP"
echo
echo "A system extension can only be activated from /Applications:"
echo "  cp -R \"$APP\" /Applications/"
echo "  open \"/Applications/VPN Plus.app\""
if [ "$MODE" = release ]; then
  echo
  echo "A Developer ID build must also be notarized before macOS will activate it."
fi
