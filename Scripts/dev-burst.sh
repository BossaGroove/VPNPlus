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
# Burst-captures VPN Plus's main window for a few seconds, as fast as
# screencapture allows (about 10 fps), into timestamped frames:
#
#   Scripts/dev-burst.sh [seconds] [output-directory]      # default: 5, $TMPDIR
#
# A development tool for looking at a *transition* rather than a state — how
# M5.11 checked that the promoted region slides in instead of appearing. It
# resolves the window id once and then only calls screencapture, which is what
# makes it fast enough to matter; dev-capture.sh re-runs the lookup per shot.
# Captures by window id, so nothing else on screen is ever in a frame.
#
# It cannot tell a snap from a slide it happened to miss — three frames of a
# 0.28 s animation is the best case. The app's own presentation-layer probes
# (DEBUG builds, `log show … | grep slide`) are the decisive instrument; this
# is the one you can look at.
set -euo pipefail

SECS="${1:-5}"
OUT="${2:-${TMPDIR:-/tmp}}"
mkdir -p "$OUT"

PID=$(pgrep -x "VPN Plus" | head -1 || true)
if [ -z "$PID" ]; then echo "VPN Plus is not running" >&2; exit 1; fi

# The largest on-screen window this process owns is the main window.
ID=$(/usr/bin/swift - "$PID" <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1]) ?? -1
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var best: (Int, Double) = (0, 0)
for w in windows {
    guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owner == pid,
          let id = w[kCGWindowNumber as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: Any],
          let width = b["Width"] as? Double, let height = b["Height"] as? Double else { continue }
    if width * height > best.1 { best = (id, width * height) }
}
print(best.0)
SWIFT
)
if [ "$ID" = "0" ]; then echo "VPN Plus has no window on screen" >&2; exit 1; fi

END=$(( $(date +%s) + SECS ))
n=0
while [ "$(date +%s)" -lt "$END" ]; do
  t=$(python3 -c 'import time; print(f"{time.time():.3f}")')
  screencapture -x -o -l"$ID" "$OUT/frame-$(printf %03d "$n")-$t.png"
  n=$((n + 1))
done
echo "$n frames in $OUT"
