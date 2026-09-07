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
# Captures VPN Plus's own windows, and nothing else on the screen.
#
#   Scripts/dev-capture.sh [output-directory]
#
# A development tool: it exists so a change to a window can be *seen* rather
# than reasoned about, which is how M5.4 shipped an empty window. It captures
# by window id, so nothing outside the app is ever in the image — deliberately,
# because the machine this runs on is somebody's own.
#
# macOS asks for Screen Recording permission the first time. That prompt is
# expected; nothing here works around it.
set -euo pipefail

OUT="${1:-.}"
APP="VPN Plus"

PID=$(pgrep -x "$APP" | head -1 || true)
if [ -z "$PID" ]; then
  echo "$APP is not running" >&2
  exit 1
fi

# The window ids this process owns, on-screen. The size floor is low on
# purpose: the **status item** and an **open menu** are windows this process
# owns too, and they are the only way to see S1 at all.
IDS=$(/usr/bin/swift - "$PID" <<'SWIFT'
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1]) ?? -1
guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}
for window in windows {
    guard let owner = window[kCGWindowOwnerPID as String] as? Int32, owner == pid,
          let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
          width > 20, height > 20
    else { continue }
    print(id)
}
SWIFT
)

if [ -z "$IDS" ]; then
  echo "$APP has no capturable window on screen" >&2
  exit 1
fi

n=0
for id in $IDS; do
  file="$OUT/vpnplus-window-$n.png"
  screencapture -x -o -l"$id" "$file"
  echo "$file"
  n=$((n + 1))
done
