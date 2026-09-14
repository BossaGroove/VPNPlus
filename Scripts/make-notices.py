#!/usr/bin/env python3
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

"""Writes the third-party notices, in both the forms we ship.

    Scripts/make-notices.py

    THIRD_PARTY_NOTICES.md      the repository's copy, for anyone reading here
    VPNPlus/Credits.html        what the About panel shows, in the app

**Both are generated from the licence texts in the source tree we actually
build**, not from memory, so what we publish is what we ship. It needs
`Scripts/build-deps.sh` to have run, because that is what puts the sources on
disk, and Sparkle to have been fetched by SPM.

Run it when a pinned version changes. Nothing enforces that.
"""

import html
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# --------------------------------------------------------------- what ships

SPARKLE_LICENSE = next(
    pathlib.Path.home().glob(
        "Library/Developer/Xcode/DerivedData/VPNPlus-*/SourcePackages/checkouts/Sparkle/LICENSE"
    ),
    None,
)

COMPONENTS = [
    {
        "name": "OpenVPN 3 Core",
        "url": "https://github.com/OpenVPN/openvpn3",
        "version": "release/3.11.7",
        "ships": "Compiled into the system extension",
        "licence": "MPL-2.0 (elected), plus two GPL-3.0-only files",
        "licence_md": "**MPL-2.0** (elected), plus two GPL-3.0-only files — see below",
        "heading": "Mozilla Public License 2.0 — OpenVPN 3 Core",
        "text": ROOT / "ThirdParty/openvpn3/LICENSES/MPL-2.0.txt",
    },
    {
        "name": "OpenSSL",
        "url": "https://www.openssl.org",
        "version": "3.6.4",
        "ships": "Static, in the system extension",
        "licence": "Apache-2.0",
        "heading": "Apache License 2.0 — OpenSSL",
        "text": ROOT / "ThirdParty/build/openssl-arm64/LICENSE.txt",
    },
    {
        "name": "asio",
        "url": "https://think-async.com/Asio/",
        "version": "1.24.0, with OpenVPN 3's patches",
        "ships": "Header-only, in the system extension",
        "licence": "BSL-1.0",
        "heading": "Boost Software License 1.0 — asio",
        "text": ROOT / "ThirdParty/build/asio/asio/LICENSE_1_0.txt",
    },
    {
        "name": "lz4",
        "url": "https://github.com/lz4/lz4",
        "version": "1.10.0",
        "ships": "Static, in the system extension",
        "licence": "BSD-2-Clause",
        "heading": "BSD 2-Clause — lz4",
        "text": ROOT / "ThirdParty/build/lz4/lib/LICENSE",
    },
    {
        "name": "{fmt}",
        "url": "https://github.com/fmtlib/fmt",
        "version": "12.2.0",
        "ships": "Static, in the system extension",
        "licence": "MIT",
        "heading": "MIT — {fmt}",
        "text": ROOT / "ThirdParty/build/fmt/LICENSE",
    },
    {
        "name": "Sparkle",
        "url": "https://sparkle-project.org",
        "version": "2.9.6",
        "ships": "Sparkle.framework, in the app",
        "ships_md": "`Sparkle.framework`, in the app",
        "licence": "MIT, with vendored bsdiff and Ed25519",
        "licence_md": "MIT, with vendored bsdiff and Ed25519 — see its text",
        "heading": "MIT — Sparkle",
        "note": "Sparkle's own notice, which also covers the bsdiff and Ed25519 code it vendors.",
        "text": SPARKLE_LICENSE,
    },
]

ELECTION = """OpenVPN 3 Core is dual-licensed **AGPL-3.0-only OR MPL-2.0**. VPN Plus takes
the **MPL-2.0** arm and combines it into this GPL-3.0-or-later work, which
MPL-2.0 §3.3 permits: no OpenVPN 3 file is marked "Incompatible With Secondary
Licenses".

**The AGPL arm is not elected, and never will be.** AGPL-3.0 §13 adds a
network-use obligation this project does not want.

Two headers in the compiled set predate OpenVPN 3's 2024 relicensing and still
carry a plain **GPL-3.0-only** notice:

- `openvpn/crypto/tls_crypt_v2.hpp`, reached through the protocol core
- `openvpn/openssl/util/pem.hpp`, reached through the SSL backend

Neither is avoidable, and the mbedTLS backend carries the same notice on its
own `pem.hpp`. This is one reason VPN Plus is GPL-3.0-**or-later** rather than
anything more permissive: under GPLv3 the question simply does not arise.

OpenVPN 3 also ships an OpenSSL linking exception. **VPN Plus does not rely on
it** — OpenSSL 3 is Apache-2.0, which is compatible with GPLv3 on its own."""

SOURCE = """Every component above is published by its own project at the version named,
and VPN Plus's own source is at <https://github.com/BossaGroove/VPNPlus>,
which carries the pinned versions, the build script, and the patches applied.
Nothing shipped here is modified beyond the patches OpenVPN 3 itself supplies
for asio."""


def read(path):
    if path is None or not pathlib.Path(path).exists():
        sys.exit(f"missing licence text: {path}\nRun Scripts/build-deps.sh first.")
    return pathlib.Path(path).read_text(encoding="utf-8").strip("\n")


def paragraphs(text):
    """Licence texts are hard-wrapped for a terminal. The About panel is narrow,
    so each paragraph is rejoined and left to reflow; indented or numbered
    lines keep their breaks, because there the shape carries meaning."""
    out = []
    for block in re.split(r"\n\s*\n", text):
        lines = [l.rstrip() for l in block.split("\n")]
        shaped = any(re.match(r"\s+\S|\s*\d+\.\d|\s*\([a-z0-9]\)", l) for l in lines)
        out.append("\n".join(lines) if shaped else " ".join(l.strip() for l in lines))
    return out


def markdown():
    sha = subprocess.check_output(
        ["git", "-C", str(ROOT / "ThirdParty/openvpn3"), "rev-parse", "HEAD"]
    ).decode().strip()[:12]

    rows = []
    for c in COMPONENTS:
        version = c["version"]
        if c["name"] == "OpenVPN 3 Core":
            version = f"`{version}` (`{sha}`)"
        rows.append(
            f"| [{c['name']}]({c['url']}) | {version} | {c.get('ships_md', c['ships'])} "
            f"| {c.get('licence_md', c['licence'])} |"
        )

    parts = [
        "# Third-party notices",
        "",
        "VPN Plus is free software under the **GNU General Public License, version 3 or",
        "later** — the full text is in [LICENSE](LICENSE). It ships with the libraries",
        "below, and this file carries their notices and licence texts, as their terms",
        "require.",
        "",
        "Everything here is compiled into the app or its system extension; there are no",
        "other third-party components, and nothing is downloaded at runtime.",
        "",
        "| Component | Version | Ships as | Licence |",
        "|---|---|---|---|",
        *rows,
        "",
        "Versions are pinned in `Scripts/build-deps.sh` and `project.yml`. **Changing a",
        "pin means re-running `Scripts/make-notices.py`.**",
        "",
        "## OpenVPN 3 Core: we elect MPL-2.0, never AGPL-3.0",
        "",
        ELECTION,
        "",
        "### Getting the source",
        "",
        SOURCE,
        "",
    ]
    for c in COMPONENTS:
        parts += ["---", "", f"## {c['heading']}", ""]
        if c.get("note"):
            parts += [c["note"], ""]
        parts += ["```", read(c["text"]), "```", ""]
    return "\n".join(parts).rstrip() + "\n"


def credits():
    """What the About panel renders. NSAboutPanel loads Credits.html as an
    attributed string in a narrow, scrolling text view: no external
    stylesheets, no scripts, and nothing that depends on a base URL."""
    def esc(s):
        return html.escape(s, quote=False)

    items = "\n".join(
        f"      <p class=c><b>{esc(c['name'])}</b> {esc(c['version'].split(',')[0])}"
        f" — {esc(c['licence'])}</p>"
        for c in COMPONENTS
    )

    sections = []
    for c in COMPONENTS:
        body = "\n".join(
            f"      <p class=l>{esc(p)}</p>" for p in paragraphs(read(c["text"]))
        )
        sections.append(f"      <p class=h>{esc(c['heading'])}</p>\n{body}")

    election = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", esc(ELECTION), flags=re.S)
    election = re.sub(r"`(.+?)`", r"<tt>\1</tt>", election)
    blocks = []
    for block in re.split(r"\n\s*\n", election):
        if block.lstrip().startswith("- "):
            for line in block.strip().split("\n"):
                blocks.append(f'      <p class="l b">{line.lstrip("- ")}</p>')
        else:
            blocks.append(f"      <p class=l>{block.replace(chr(10), ' ')}</p>")
    election = "\n".join(blocks)

    return f"""<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <style>
      body {{ font: 11px -apple-system, "Helvetica Neue", sans-serif; margin: 0; }}
      p {{ margin: 0 0 6px 0; }}
      p.i {{ margin-bottom: 10px; }}
      p.c {{ margin: 0 0 2px 0; }}
      p.h {{ font-weight: bold; margin: 14px 0 4px 0; }}
      p.l {{ font-size: 9px; color: #555; margin: 0 0 5px 0; }}
      p.b {{ margin: 0 0 2px 14px; }}
      b {{ font-weight: 600; }}
      tt {{ font-family: ui-monospace, Menlo, monospace; font-size: 9px; }}
    </style>
  </head>
  <body>
    <p class=i>VPN Plus is free software under the GNU General Public License,
      version 3 or later. It comes with no warranty.</p>

    <p class=h>Built with</p>
{items}

    <p class=h>OpenVPN 3 Core: we elect MPL-2.0, never AGPL-3.0</p>
{election}

{chr(10).join(sections)}
  </body>
</html>
"""


if __name__ == "__main__":
    (ROOT / "THIRD_PARTY_NOTICES.md").write_text(markdown(), encoding="utf-8")
    (ROOT / "VPNPlus/Credits.html").write_text(credits(), encoding="utf-8")
    print("wrote THIRD_PARTY_NOTICES.md and VPNPlus/Credits.html")
