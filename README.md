# VPN Plus

A native macOS VPN client, designed interface-first.

> **Status: early development.** There is no release yet — this repository is
> scaffolding and design work. The sections below describe where it is going,
> not what you can install today.

## Why

OpenVPN on the Mac is a solved problem technically and an unsolved one
experientially. Two clients cover it, and they miss in opposite directions.

**Tunnelblick** is capable, open source, and has kept a lot of people
connected for a long time — but its interface is from another era: small
text, several windows, and a great deal on screen that competes with the two
things most people actually came to do.

**OpenVPN Connect** goes the other way: a small window that shows very
little, and almost nothing when a connection fails. A tunnel that cannot
establish can sit on "connecting" indefinitely — no step, no error, no
timeout. Switching to a different saved profile takes a menu, a list, and a
button labelled something other than what it does.

VPN Plus is a third answer, built on the premise that the interface is the
hard part:

- **One window.** Everything routine happens in it.
- **Switching profiles is one click**, from the main screen.
- **State is never a lie.** "Connecting" names the step it is on, and times
  out with a reason.
- **Failures are legible** — what failed, and what to do about it, in plain
  language, without opening a log viewer. The log is there when the plain
  answer isn't enough, and it is readable.
- **A menu bar item you can trust at a glance**, always agreeing with the
  window.

Underneath: **Swift 6** + AppKit, async/await, strict concurrency; a
universal binary (Apple Silicon + Intel), Developer ID-signed and notarized.

## Planned scope

The first release aims at the everyday path, done properly:

- Import `.ovpn` profiles (including inline certificates) and keep them
  organized
- Connect, disconnect, reconnect — and auto-reconnect that behaves
- Credentials, private keys, and passphrases in the **macOS Keychain**
- A readable connection log, and a failure message a human can act on
- DNS handled correctly, including not leaking
- Localized in English, 日本語, 繁體中文, 简体中文, Deutsch, and Français

VPN Plus speaks OpenVPN first. The architecture keeps the protocol behind a
single boundary so that others — WireGuard next — are an addition rather than
a rewrite.

Details are still being worked out; this list will tighten as the design
settles.

## Building from source

Not yet applicable — the app target does not exist. Build instructions land
with the first milestone.

## License

**GPL-3.0-or-later.** See [LICENSE](LICENSE).

VPN Plus is built on the OpenVPN 3 core library, which is dual-licensed
AGPL-3.0-only or MPL-2.0; we use it under the **MPL-2.0** arm, combined into
this GPL-3.0 work as MPL-2.0 §3.3 permits. Other dependencies — asio
(BSL-1.0), lz4 (BSD-2-Clause), fmt (MIT) and OpenSSL 3 (Apache-2.0) — are all
compatible with GPL-3.0.

## Credits

VPN Plus is a from-scratch implementation, but it owes its understanding of
the problem to the projects that got there first — most of all
[Tunnelblick](https://tunnelblick.net) and
[OpenVPN](https://openvpn.net). Thank you.

"OpenVPN" is a trademark of OpenVPN Inc. VPN Plus is an independent project,
not affiliated with or endorsed by OpenVPN Inc.
