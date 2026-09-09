#!/bin/bash
# VPN Plus — a native macOS VPN client.
# Copyright (C) 2026 BossaGroove
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along
# with this program. If not, see <https://www.gnu.org/licenses/>.
#
# Cleans up after the development loop.
#
#   Scripts/dev-clean.sh                 # report, and remove this project's DerivedData
#   Scripts/dev-clean.sh --dry-run       # report only
#   Scripts/dev-clean.sh --uninstall     # also uninstall the system extension (resets approval)
#
# Every signed development build stages a copy of the system extension under
# /Library/SystemExtensions, and macOS keeps each one "waiting to uninstall on
# reboot" — after a day's iterations that is a hundred copies and hundreds of
# megabytes. Nothing but a reboot removes those, and this script says so rather
# than pretending. What it can remove is this project's DerivedData, which
# grows the same way.
#
# --uninstall runs `systemextensionsctl uninstall` for the extension, which
# needs developer mode (`systemextensionsctl developer on`) or SIP off, and
# **resets the one-time approval**: the next Connect walks the setup sequence
# again. That is the point when the sequence is what you want to test.
set -euo pipefail

BUNDLE_ID="com.bossagroove.VPNPlus.tunnel"
APP="/Applications/VPN Plus.app"
DRY_RUN=0
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "== Staged system extensions"
LIST=$(systemextensionsctl list 2>/dev/null || true)
TOTAL=$(printf '%s\n' "$LIST" | grep -c "$BUNDLE_ID" || true)
WAITING=$(printf '%s\n' "$LIST" | grep "$BUNDLE_ID" | grep -c "waiting to uninstall" || true)
ACTIVE=$(printf '%s\n' "$LIST" | grep "$BUNDLE_ID" | grep -c "activated enabled" || true)
echo "   $TOTAL copies of $BUNDLE_ID: $ACTIVE active, $WAITING waiting to uninstall on reboot"
if [ "$WAITING" -gt 0 ]; then
  echo "   A reboot removes the $WAITING waiting copies; nothing else does."
fi

echo "== DerivedData"
shopt -s nullglob
DIRS=("$HOME"/Library/Developer/Xcode/DerivedData/VPNPlus-*)
if [ ${#DIRS[@]} -eq 0 ]; then
  echo "   nothing to remove"
else
  du -sh "${DIRS[@]}" | sed 's/^/   /'
  if [ "$DRY_RUN" -eq 0 ]; then
    rm -rf "${DIRS[@]}"
    echo "   removed; the next build is a full one"
  fi
fi

if [ "$UNINSTALL" -eq 1 ]; then
  echo "== Uninstalling the system extension"
  if [ ! -d "$APP" ]; then
    echo "   $APP is not installed; nothing to uninstall" >&2
    exit 1
  fi
  # The team identifier from the installed app's own signature, so the script
  # carries none.
  TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  if [ -z "$TEAM" ] || [ "$TEAM" = "not set" ]; then
    echo "   the installed app is not signed with a team; cannot uninstall by team" >&2
    exit 1
  fi
  echo "   this resets the one-time approval: the next Connect asks again"
  if [ "$DRY_RUN" -eq 0 ]; then
    pkill -x "VPN Plus" || true
    sudo systemextensionsctl uninstall "$TEAM" "$BUNDLE_ID"
  else
    echo "   would run: sudo systemextensionsctl uninstall $TEAM $BUNDLE_ID"
  fi
fi
