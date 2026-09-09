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
# Checks that every key in the String Catalog reached the built app.
#
#   Scripts/check-catalog.sh [path/to/VPN Plus.app] [language]   # default: the Debug product, en
#
# A key can sit in the catalog and never reach the app: the compiler skips an
# entry whose state is not "translated", and Xcode's export leaves the source
# language's multi-specifier entries as "new". In English the app then falls
# back to the key and looks right; in every other language the sentence stays
# English. Fails when the difference is not zero, and names the keys.
set -euo pipefail
shopt -s nullglob
built=("$HOME"/Library/Developer/Xcode/DerivedData/VPNPlus-*/Build/Products/Debug/"VPN Plus.app")
APP="${1:-${built[0]:-}}"
LANG_CODE="${2:-en}"
[ -n "$APP" ] && [ -d "$APP" ] || { echo "no built app found; pass its path" >&2; exit 2; }
python3 - "$APP" "$LANG_CODE" <<'PY'
import json, subprocess, sys, os
app, lang = sys.argv[1], sys.argv[2]
cat = json.load(open("VPNPlus/Localizable.xcstrings"))["strings"]
def plist(path):
    if not os.path.exists(path): return {}
    return json.loads(subprocess.run(["plutil","-convert","json","-o","-",path],capture_output=True,text=True).stdout or "{}")
base = f"{app}/Contents/Resources/{lang}.lproj/"
strings = plist(base + "Localizable.strings"); dicts = plist(base + "Localizable.stringsdict")
missing = [k for k in cat if k not in strings and k not in dicts]
print(f"{lang}: {len(cat)} catalog keys; {len(strings)} in .strings, {len(dicts)} in .stringsdict; {len(missing)} missing")
for k in missing: print("  missing:", k[:120])
sys.exit(1 if missing else 0)
PY
