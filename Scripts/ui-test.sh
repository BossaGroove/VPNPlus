#!/bin/zsh
# Runs the hosted UI suite (M8.4). **Do not start it while the owner is
# working without telling them first** — it shows the app's window (behind
# everything, never focused) and a status item for the length of the run.
#
#   Scripts/ui-test.sh <shots-dir> [language ...] [-- <extra xcodebuild args>]
#
# The suite runs inside the app, which the VPNPlusAppTests scheme launches in
# rehearsal: a stand-in tunnel, fixture profiles in a throwaway store, no
# extension, no Keychain, no notifications, no activation. Each language is
# one xcodebuild run (-testLanguage); captures land in <shots-dir>/<lang>/.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -lt 1 ]]; then
  echo "usage: Scripts/ui-test.sh <shots-dir> [language ...] [-- xcodebuild args]" >&2
  exit 2
fi
shots="$(mkdir -p "$1" && cd "$1" && pwd)"; shift

languages=()
while [[ $# -gt 0 && "$1" != "--" ]]; do languages+=("$1"); shift; done
[[ $# -gt 0 ]] && shift
[[ ${#languages[@]} -eq 0 ]] && languages=(en)

if scutil --nc list 2>/dev/null | grep -q "(Connected)"; then
  echo "A tunnel is connected; the suite launches and quits the app. Disconnect first." >&2
  exit 1
fi

for language in "${languages[@]}"; do
  xcodebuild \
    -project VPNPlus.xcodeproj \
    -scheme VPNPlusAppTests \
    -configuration Debug \
    -destination 'platform=macOS' \
    -testLanguage "$language" \
    CODE_SIGNING_ALLOWED=NO \
    VPNPLUS_SHOTS="$shots" \
    test "$@"
done
