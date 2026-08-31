# Design — Atmark rename

## Naming map (case-preserving)

| Old | New |
|-----|-----|
| `Pippin` (package name, `enum Pippin`, prose) | `Atmark` |
| `PippinCore` / `PippinModules` / `PippinServer` / `PippinApp` / `PippinShim` | `AtmarkCore` / `AtmarkModules` / `AtmarkServer` / `AtmarkApp` / `AtmarkShim` |
| `pippin-shim` (executable, dir) | `atmark-shim` |
| `PippinError`, `PippinPresentationModel`, `PippinMenuView`, `PippinWindow`, `PippinSettingsView`, `PippinSettingsButton`, `PippinBearerValidator`, `PippinHTTPHandler`, `PippinShimRuntime`, `PippinApp.swift`, … | same with `Atmark` prefix |
| `pippin_status`, `pippin_reminders_*`, `pippin_mail_*` (MCP wire names) | `atmark_*` |
| `pippin-fixture`, `pippin-runtime-tests-`, `pippin-mail-probe-` (fixture/temp prefixes) | `atmark-*` |
| `APP_NAME=Pippin` | `APP_NAME=Atmark` |
| `BUNDLE_ID=io.github.is52hertz.pippin` | `BUNDLE_ID=io.github.atmarkhq.atmark` |
| `SIGNING_IDENTITY="Pippin Local Signing"` | `SIGNING_IDENTITY="Atmark Local Signing"` |
| `Pippin.app`, `build/Pippin.app` | `Atmark.app` |

The sweep is a pure token substitution `Pippin→Atmark`, `pippin→atmark`
(`PIPPIN→ATMARK` if any) applied to **tracked files outside `.trellis/tasks/`**.
No semantic edits, no reformats. Longest-first ordering is unnecessary because
`Pippin`/`pippin` have no suffix collisions with other words in the tree
(verified: all identifiers containing the token start with it or embed it
verbatim; substitution preserves each casing class).

## Surfaces and order

1. **Filesystem renames via `git mv`** — `Sources/{PippinCore,PippinModules,
   PippinServer,PippinApp,PippinShim,pippin-shim}`, `Tests/{PippinCoreTests,
   PippinServerTests,PippinAppTests,PippinShimTests}`, and files named
   `Pippin*.swift` inside them. `git mv` keeps history linkage.
2. **Content sweep** — sed over the tracked-file set from
   `git grep -il pippin -- . ':(exclude).trellis/tasks/**'`
   (plus `.gitignore`, `notice.md` handled explicitly). Sources, Tests,
   Scripts, `Package.swift`, `version.env`, `notice.md`,
   `.trellis/spec/**` are included. `Package.resolved` contains no pippin.
3. **Config** — `version.env` values per the map; `.gitignore` gains `Refer/`.
4. **Signing** — after the sweep, run `Scripts/setup_dev_signing.sh` once: it
   reads the new `SIGNING_IDENTITY` from `version.env` and creates the fresh
   `Atmark Local Signing` identity. The old identity is not found by that name,
   so the script's no-overwrite guard is naturally satisfied; nothing to force.
5. **Remotes** — `git remote rename origin pippin-archived` then
   `git remote add origin https://github.com/atmarkhq/atmark.git`. Branch
   tracking of `main` stays on `pinnin-archived/main` until the user pushes
   (push is explicitly out of scope); note this in the wrap-up.
6. **Leftovers** — `rm -rf iMCP/` (untracked duplicate of the pre-migration
   tree; `Refer/` stays).
7. **Record** — add the rename-history note to `notice.md` and update the
   signing section's identity/bundle facts.

## Risks and mitigations

- **TCC invalidation (accepted, D1)**: new bundle ID + new identity ⇒ every
  existing grant dies. Mitigation: this is a deliberate, user-accepted,
  one-time re-grant; the wrap-up lists the grants to redo (Full Disk Access for
  Mail data, Mail Automation, Reminders full access).
- **Sweep over-reach**: sed could touch `.trellis/tasks/` history. Mitigation:
  the file list is generated with pathspec exclusion, and AC1/AC2 greps gate
  the result. `Refer/`, `iMCP/`, `build/`, `.codegraph/` are never in the list
  because only tracked files are swept.
- **Shim bundle-ID allowlist**: `EndpointResolver` hard-codes the literal
  `io.github.is52hertz.pippin` and its tests assert it; both are swept
  mechanically. Verify via `swift test` (shim tests cover the allowlist).
- **Spec drift**: 15 spec files under `.trellis/spec/` are living docs; they
  are swept in the same commit so spec and code never disagree.
- **Branch base**: current HEAD = main + 1 chore commit (`6a4855a` trellis form
  update). Branch from HEAD, not main, so that commit is not stranded.

## Rollback shape

Single squashed-able commit unit on `feat/atmark-rename`; `git reset` to the
branch point restores everything. Remote rename/add and `rm -rf iMCP/` are
machine-local operations with their own inverse (`git remote rename` back,
re-copy from the parent directory's `iMCP` if ever needed). The new keychain
identity is additive; the old one is untouched.
