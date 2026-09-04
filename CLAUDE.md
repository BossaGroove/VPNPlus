# CLAUDE.md

Guidance for AI-assisted development in this repository.

## What this is

**VPN Plus** — a native macOS VPN client (Swift 6 + AppKit) built because the
existing options work and are unpleasant to use. v1 speaks **OpenVPN**;
**WireGuard is phase 2**. See [README.md](README.md).

**Status: scaffolding.** There is no app target yet. The VPN engine, the
privilege model (privileged helper vs. NetworkExtension), and the sandbox
posture are all still under investigation — nothing here locks them in, and
this file gets rewritten as those land.

## Hard rules

- **UX is the product.** This project exists because the alternatives are
  unpleasant, not because the protocol is unsolved. A technically correct
  change that makes the app harder to use is not correct. Specifically, and
  non-negotiably: one window for everything routine; switching profiles is
  one click from the main screen; "connecting" names its step and times out
  rather than spinning forever; a failure says what failed and what to do
  about it, in the main window, in plain language and never as a raw error
  code; default text sizes and
  real spacing; the menu bar and the window always agree.
- **The core is protocol-agnostic from the first commit.** Profiles,
  credentials, the connection state machine, the menu bar, logs, and
  diagnostics know about *a tunnel*, not about OpenVPN. Protocol specifics
  live behind one boundary, so adding WireGuard is an addition and not a
  rewrite. An OpenVPN concept leaking into the UI layer is a defect to fix
  now, not later.
- **Everything committed here is publishable.** This repository goes public
  at the first release. Internal notes, working docs, vendor references, and
  anything owner-specific belong in the private repo cloned at `internal/`
  (gitignored). Never move content the other way without a deliberate check.
- **Reference implementations are read-only, and never copied.** VPN Plus is
  a from-scratch implementation written against our own behavioral spec.
  Tunnelblick is **GPL-2.0-only**: read it to learn *what has to be handled*,
  then implement independently — never copy, port, or translate it.
- **Every dependency's license is checked before it is added.** This app's
  license posture is fragile by nature: the surrounding OpenVPN ecosystem is
  largely copyleft. `openvpn3` is dual-licensed **AGPL-3.0-only OR MPL-2.0**
  and may only be used under the **MPL-2.0** arm; the AGPL arm would make the
  whole app copyleft. A new dependency that is GPL or AGPL-only is a blocking
  decision, not an implementation detail.
- **It is a security product.** It moves the user's entire network traffic
  and will need elevated privileges somewhere. VPN credentials, private keys,
  and passphrases live in the macOS Keychain — never in a config file, a
  preference, a log line, or a crash report. Anything that runs as root gets
  a minimal, explicitly-audited interface. This is in tension with making
  failures legible: diagnostics must be *useful* without leaking secrets.
  Solve that, rather than resolving it by hiding information.
- **The Xcode project is generated.** Once it exists: edit `project.yml`,
  never the pbxproj; run `xcodegen generate` after changing it (both are
  committed).

## Build & test

Not yet — there is nothing to build. This section lands with the first
milestone, alongside `project.yml` and the local packages.

## Conventions

- Swift 6 strict concurrency, `@MainActor` UI, programmatic AppKit (SwiftUI
  only for simple leaf surfaces such as Settings/About).
- Universal binary (arm64 + x86_64), Developer ID-signed and notarized,
  distributed via GitHub Releases with Sparkle 2 for updates. The Mac App
  Store is not a target; deployment target is decided with the first
  milestone.
- Localized from v1: English, 日本語, 繁體中文, 简体中文, Deutsch, Français —
  String Catalog plus an in-app language picker. User-facing strings are
  localized as they land, not retrofitted.
- swift-format with the committed config; match surrounding style.
- Tests use Swift Testing (`import Testing`).
- Commit style: short imperative subject; group by feature.
- Code comments may cite items like "feature-spec 3.4" — those are the
  maintainers' private working docs (see below); treat the numbers as stable
  identifiers.

## Private working docs

If an `internal/` directory exists in this checkout (a separate private
repository, gitignored here), read `internal/CLAUDE.md` before starting
work — it carries the full project context, and
`internal/docs/product-brief.md` is the design authority for anything a user
can see.
