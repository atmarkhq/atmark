# PRD — Rename project iMCP/Pippin to Atmark

## Background

This repository was migrated out of a parent-directory project named `iMCP`,
where the product under development was named **Pippin**. The project now lives
at `Atmark` and the product is renamed to **Atmark**. This rename must be
recorded traceably (this task is the record), not performed silently.

Upstream moves to `https://github.com/atmarkhq/atmark`.

## User decisions (binding)

| # | Decision |
|---|----------|
| D1 | Full rename including bundle ID → `io.github.atmarkhq.atmark`. The user accepts one-time invalidation of all local TCC grants (Full Disk Access, Mail Automation, etc.) and will re-grant by hand. |
| D2 | Delete the untracked leftover `iMCP/` directory at repo root. Keep `Refer/` but git-isolate it — `Refer/` must never be committed. |
| D3 | `.trellis/tasks/**` historical records (136 paths with `pippin` slugs, 4 docs mentioning `iMCP`) are kept verbatim as history. This task's documents are the traceable record of the rename. |
| D4 | Git remotes: rename current `origin` (is52hertz/Pippin) to an archive name, and add the new `origin` pointing at `https://github.com/atmarkhq/atmark.git`. |

## Requirements

- **R1 Product naming sweep**: every live (non-historical) tracked surface that
  says `Pippin`/`pippin` says `Atmark`/`atmark` instead. This covers:
  - SwiftPM package name, all 8 targets, `Sources/**` and `Tests/**` directory
    and file names, all Swift identifiers (types, enums, namespaces) and
    comments/docs.
  - MCP wire tool names `pippin_*` → `atmark_*` (no external consumers exist
    yet; rename cleanly now).
  - `Scripts/*.sh` (messages, binary names, Info.plist TCC usage descriptions),
    `version.env`, `notice.md`.
  - Living spec documents under `.trellis/spec/**` (15 files) — these describe
    current code and must track the new names, unlike archived task records.
- **R2 Bundle identity**: `APP_NAME=Atmark`, `BUNDLE_ID=io.github.atmarkhq.atmark`;
  app bundle becomes `Atmark.app`. The shim's literal bundle-ID allowlist and
  its tests move with it.
- **R3 Signing identity**: new local identity `Atmark Local Signing` created
  via the existing `setup_dev_signing.sh` flow (it refuses to overwrite the old
  `Pippin Local Signing`, which stays untouched in the keychain). TCC re-grant
  is expected and accepted (D1).
- **R4 Remotes**: per D4 — old URL preserved under an archive remote name, new
  `origin` = atmarkhq/atmark. No push without explicit user request.
- **R5 Leftover removal**: delete untracked `iMCP/` (D2). Add `Refer/` to
  `.gitignore` so it can never be committed (D2).
- **R6 Rename record**: `notice.md` gains a short "Rename history" note
  (iMCP → Pippin → Atmark, date, this task as the pointer). Historical task
  directories and archives are NOT rewritten (D3).
- **R7 Branching**: work lands on `feat/atmark-rename` branched from the current
  HEAD (which contains main plus one trellis chore commit). Existing
  `feat/pippin-*` branches are kept as historical archives, never deleted.

## Out of scope

- Rewriting `.trellis/tasks/**` history, journals, or archived task slugs.
- Notarization, paid developer accounts, hardened runtime.
- Pushing to any remote.
- Deleting the old `Pippin Local Signing` identity from the keychain.

## Acceptance criteria

- **AC1** `git grep -i pippin` over tracked files returns matches ONLY under
  `.trellis/tasks/` (historical records per D3) and in `notice.md`'s rename
  history note.
- **AC2** `git grep -i imcp` over tracked files returns matches ONLY under
  `.trellis/tasks/` and the rename history note.
- **AC3** `swift build` and `swift test` pass on the renamed tree.
- **AC4** `Scripts/package_app.sh` succeeds with the new identity and produces
  `build/Atmark.app` whose `CFBundleIdentifier` is `io.github.atmarkhq.atmark`.
- **AC5** `git remote -v` shows the old URL under the archive name and
  `origin` = `https://github.com/atmarkhq/atmark.git`.
- **AC6** `iMCP/` no longer exists; `Refer/` is git-ignored
  (`git status --short` no longer lists it).
- **AC7** One coherent commit (or a small ordered set) on `feat/atmark-rename`
  containing only this task's changes; `.trellis/spec/**` updates included.
