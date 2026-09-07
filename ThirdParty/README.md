# ThirdParty/

Third-party source this project compiles. Nothing built lands in git: the
`src/`, `build/` and `out/` directories are created by `Scripts/build-deps.sh`
and are ignored.

## openvpn3 — the OpenVPN 3 core library

| | |
|---|---|
| Path | `openvpn3/` (git submodule) |
| Upstream | https://github.com/OpenVPN/openvpn3 |
| Pinned at | **`release/3.11.7`** — `git describe --tags` prints exactly that; commit `18edfae7`, 2026-07-07 |
| Licence | Dual **AGPL-3.0-only OR MPL-2.0**. **VPN Plus takes the MPL-2.0 arm** and combines it into this GPL-3.0-or-later work under MPL-2.0 §3.3. The AGPL arm is never elected |

openvpn3 is a header library with no library target: it is compiled into the
tunnel extension, which defines the engine's log macro. See the project's
`CLAUDE.md` for the licence rules and why they are strict.

Re-pin deliberately: bump the submodule to another **release tag**, never a
branch, and record what `git describe` says in the same change.

Two headers in the compile set (`openvpn/crypto/tls_crypt_v2.hpp`,
`openvpn/openssl/util/pem.hpp`) still carry a GPL-3.0-only notice from before
upstream relicensed. That is why this project is GPL-3.0-or-later and not
something more permissive.

## Built dependencies (`Scripts/build-deps.sh`)

Fetched as pinned tarballs, verified by SHA-256, built as static universal
(arm64 + x86_64) libraries for macOS 14.0, installed under `out/`.

| Dependency | Version | Licence | Note |
|---|---|---|---|
| asio | 1.24.0 | BSL-1.0 | Header-only. **Patched** with the seven OpenVPN-authored patches in `openvpn3/deps/asio/patches/` — the first adds Apple NAT64 support, which IPv6-only networks need |
| lz4 | 1.10.0 | BSD-2-Clause | Library only; the GPL-2.0 command-line tool is not built |
| fmt | 12.2.0 | MIT | |
| OpenSSL | 3.6.4 | Apache-2.0 | |

A third-party notices file collecting every attribution is produced for the
first release.
