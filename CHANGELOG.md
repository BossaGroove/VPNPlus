# Changelog

All notable changes to VPN Plus are recorded here.

Each release's entry is shown inside the app (Settings → Software Update) and
in the update notification, so keep the entries user-facing: what changed for
someone using VPN Plus, not how it was implemented.

Version headings are `## <version> — <date>`; the release workflow reads the
version from the heading, so it must match the tag exactly.

## Unreleased

### Added

- Project scaffold: `project.yml` (XcodeGen), the `VPNPlusCore` local package,
  the app target, and a NetworkExtension system extension target.
- CI builds both configurations and fails if the committed Xcode project is
  stale relative to `project.yml`.
- The OpenVPN engine: VPN Plus connects to an OpenVPN server, carries your
  traffic, and applies the DNS the server asks for.
- The connection survives what a laptop actually does: sleeping and waking,
  changing Wi-Fi network, and losing the network entirely. Reconnecting never
  takes your internet away while it works.

**Not ready to use yet.** There is no way to save a profile or a password: a
profile is chosen from disk each time and kept only while the app runs.

Nothing released yet. The first version's entry goes here, and the release
workflow refuses to build a tag that has no matching section.
