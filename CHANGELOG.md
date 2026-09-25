# Changelog

All notable changes to VPN Plus are recorded here.

Each release's entry is shown inside the app (Settings → Software Update) and
in the update notification, so keep the entries user-facing: what changed for
someone using VPN Plus, not how it was implemented.

Version headings are `## <version> — <date>`; the release workflow reads the
version from the heading, so it must match the tag exactly.

## 1.0.0 — 2026-09-25

First public release. VPN Plus is a native Mac client for OpenVPN servers,
written from scratch because the existing ones work but are unpleasant to use:
connecting, switching and finding out what went wrong should each be obvious.

### Added

- **One window, one click** — every profile is a card in the main window.
  Connect on any card connects it; connecting to another profile while one is
  up switches in a single step — no need to disconnect first.
- **Profiles** — import a `.ovpn` by dragging it into the window, from File ›
  Import Profile…, or by double-clicking it in the Finder. It is checked there
  and then, so a problem — a file it refers to that isn't there, a setting VPN
  Plus doesn't use — is explained at import, not at connect. Rename, remove,
  or replace a profile's file with a newer one and keep your settings.
- **Your settings, marked as yours** — choose the server, set the username,
  use a different certificate, and every value says whether it came from the
  profile or from you, with a one-click revert.
- **Passwords in your Keychain** — remember a password once and it is kept in
  the macOS Keychain with the profile's certificate and key, never in a file.
  Removing a profile removes them too.
- **Connecting says what it is doing** — finding the server, contacting it,
  signing in, setting up your connection. Every step has a time limit, and
  when one runs out VPN Plus stops and says which step didn't finish, rather
  than spinning.
- **Failures in plain language** — a wrong password, a server that doesn't
  answer, an expired server certificate, a Mac clock that's wrong, another VPN
  already carrying your traffic: the main window says what failed and what to
  do about it, never a raw error code.
- **Stays connected through what a laptop does** — sleep and wake, changing
  Wi-Fi, losing the network and getting it back. Reconnecting is automatic,
  retries with growing pauses, and says so plainly if it has to give up.
- **Diagnostics you can send** — for each profile, what changed on this Mac
  since it last connected, a timeline of every attempt and each step's timing,
  and Copy or Export, with passwords and keys removed. It also tells you when
  macOS is using a private Wi-Fi address that a server may not recognise.
- **A menu bar icon you can trust** — not connected, connecting or connected
  at a glance, always agreeing with the window, and optionally the connected
  profile's name beside it. Its menu connects, switches, disconnects and quits.
- **First run, explained** — VPN Plus offers to move itself into Applications,
  explains macOS's one-time approval before asking for it, and notices when
  you have given it.
- **Automatic updates** — signed and notarized updates via Sparkle, with an
  optional beta channel.
- **Localization** — English, 日本語, 繁體中文, 简体中文, Deutsch and Français,
  switchable in Settings.

Requires macOS 14 (Sonoma) or later, on Apple silicon or Intel. Profiles that
keep their certificate in a PKCS#12 keystore, or that download their settings
from the server after you sign in, aren't supported yet; VPN Plus says so
when you import one.
