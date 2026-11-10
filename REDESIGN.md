# Redesign build — what changed

This fork keeps the original worse_query access layer intact and changes two
things: the reachable scope and the interface.

## Access

- `All App Data` is now a first-class root at
  `/private/var/mobile/Containers/Data`. The per-type folders stay as shortcuts.
  `WQDirViewController` already accepts any absolute path, so the whole tree is
  browsable, readable, writable and creatable through the existing
  `wq_read / wq_write / wq_patch / wq_create_*` APIs.
- `wq_delete_tree` (new, `WQAccess.m` / `WQAccess.h`) empties a folder through
  the existing `wq_purge_contents` fd-relative walker — child symbolic links are
  never followed — and only then removes the folder. Backup storage is refused.
  It makes **no** file-by-file backup. Enable it with
  `Settings → File Operations → Delete non-empty folders`; the confirmation
  states explicitly that nothing is kept and the action cannot be undone.
- `Go to Path` is now a real form page instead of an alert, defaulting to the
  all-data root.
- iOS 26 still hides System Data and system groups: `wq_system_areas_reachable()`
  reflects the worse_query grant scope, and no toggle pretends otherwise.
  Root-owned files stay read-only because a sandbox token does not change Unix
  permissions.

## Interface

`WQDesignTokens.h` is the single source for colours, spacing steps, radii, type
and icons. Everything else references it.

- Neutral palette only; emphasis comes from light/dark contrast. No gradients,
  glows, shadows or coloured accent. All `systemBlue/Red/Orange/Green/...`
  usages across `main.m`, `WQUI.m`, `WQCache.m`, `WQHexViewer.m` and
  `WQSQLiteViewer.m` were replaced.
- Removed the nine-colour service tiles, the emoji keyword rule, filled symbol
  variants, capsule link buttons, the 40 pt hero icon and the `!`-style warning
  glyphs. One 1.5 pt outline symbol set in one neutral colour is used instead.
- Root and browsers use plain grouped lists rather than inset cards; group
  titles are left aligned, rows share one left edge, and the credits footer is
  plain text.
- New `Settings` page: one row per setting, label left / control right, titled
  groups, generous space between groups, and a single isolated `Reset` action.
  Only switches that actually change behaviour are present.
- `Go to Path` form: label above a full-width field, with a fixed 18 pt hint
  slot reserved for validation messages.

Both `Show all app data` and `Delete non-empty folders` are persisted in
`NSUserDefaults` and take effect immediately; the read-only rows describe values
fixed by the design tokens rather than pretending to be adjustable.

## Build

`./tests/run_all_tests.sh` and `./build.sh` are unchanged. The `build.yml`
workflow selects an Xcode carrying an iOS 26 SDK, runs the host regression suite
(which includes a strict arm64 syntax/link check), builds and validates the IPA,
then uploads it as an artifact. `probe.yml` only reports the runner's SDK
inventory.

The output is ad-hoc signed with an App Group entitlement. Re-sign with
AltStore / SideStore / Sideloadly while keeping an App Group, then validate on a
supported device: token issuance, navigation timing, power-loss recovery and
concurrent target-app writes cannot be verified in CI.
