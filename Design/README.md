# Design assets (inventory)

Nothing here yet. This directory holds the app's artwork sources — the icon
document and any original vector assets — with one row per file below.

| File | What it is |
|---|---|
| _(none yet)_ | |

## Rules for anything added here

- **Record the provenance and license of every third-party asset** in the
  table above: where it came from, under what license, and what that license
  does and does not permit for an app icon. An asset with no recorded license
  does not get committed.
- **Nothing is committed pre-rendered.** The icon builds from its source at
  build time (a build phase runs `actool` over an Icon Composer document), so
  edits happen in the source, not in an exported `.icns`.
