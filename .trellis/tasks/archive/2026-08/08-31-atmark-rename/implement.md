# Implement — Atmark rename

Ordered checklist. Each gate must pass before the next step. All paths are
repo-relative. Work happens on a new branch `feat/atmark-rename` created from
current HEAD.

## Step 0 — Branch and safety

- [x] `git switch -c feat/atmark-rename`
  - Deviation (user-directed): the old feat branch was merged to main first (`7632b9e`),
    so this branch starts from that main, not from "main + stranded chore commit"
- [x] Baseline: `swift build && swift test` pass before any change (record failures if any pre-existing; do not fix here)

## Step 1 — Filesystem renames (git mv)

- [x] `git mv Sources/PippinCore Sources/AtmarkCore` (same for `PippinModules→AtmarkModules`, `PippinServer→AtmarkServer`, `PippinApp→AtmarkApp`, `PippinShim→AtmarkShim`, `pippin-shim→atmark-shim`)
- [x] `git mv Tests/PippinCoreTests Tests/AtmarkCoreTests` (same for `PippinServerTests→AtmarkServerTests`, `PippinAppTests→AtmarkAppTests`, `PippinShimTests→AtmarkShimTests`)
- [x] `git mv` each file whose name contains pippin (e.g. `Sources/AtmarkCore/Pippin.swift→Atmark.swift`, `PippinError.swift→AtmarkError.swift`, `Sources/AtmarkApp/App/PippinApp.swift→AtmarkApp.swift`, `PippinWindow.swift`, `PippinMenuView.swift`, `PippinPresentationModel.swift`, `PippinSettingsView.swift`, `PippinSettingsButton.swift`, `Tests/AtmarkAppTests/PippinPresentationModelTests.swift`, `Tests/AtmarkCoreTests/PippinErrorTests.swift`, …) — enumerate with: `git ls-files | grep -i pippin | grep -v '^\.trellis/'`

## Step 2 — Content sweep

- [x] Build the file list excluding history: `git grep -ilz pippin -- . ':(exclude).trellis/tasks/**' | xargs -0` (must include Sources, Tests, Scripts, Package.swift, version.env, notice.md, .gitignore, .trellis/spec/**)
- [x] Apply `Pippin→Atmark`, `pippin→atmark` (case-sensitive, two passes; add `PIPPIN→ATMARK` if present)
- [x] `.gitignore`: add `Refer/` under a comment marking it permanently untracked
- [x] Sanity-grep for accidental hits: `git grep -n 'ippin' -- . ':(exclude).trellis/tasks/**'` → expect only `notice.md` rename-history lines (added in Step 5)

## Step 3 — Identity and remotes (machine-local, no commit)

- [x] `Scripts/setup_dev_signing.sh` → creates `Atmark Local Signing` (old identity untouched; script must NOT be forced)
- [x] `git remote rename origin pinnin-archived 2>/dev/null || git remote rename origin pippin-archived`
- [x] `git remote add origin https://github.com/atmarkhq/atmark.git`
- [x] `rm -rf iMCP/`

## Step 4 — Verify (gate: all must pass)

- [x] `swift build`
- [x] `swift test`
- [x] `Scripts/package_app.sh` → `build/Atmark.app`; check `defaults read build/Atmark.app/Contents/Info CFBundleIdentifier` == `io.github.atmarkhq.atmark`; `codesign -dv build/Atmark.app` shows the new identity
- [x] AC1: `git grep -il pippin -- . ':(exclude).trellis/tasks/**'` → only `notice.md`
- [x] AC2: `git grep -il imcp -- . ':(exclude).trellis/tasks/**'` → only `notice.md`
- [x] AC5: `git remote -v`
- [x] AC6: `ls iMCP` fails; `git check-ignore Refer` succeeds; `git status --short` no longer lists `Refer/`

## Step 5 — Rename record

- [x] `notice.md`: add "Rename history" section (iMCP → Pippin → Atmark, 2026-08-31, pointer to this task); update signing facts (new identity name, new bundle ID, note that old grants died and were re-granted)
- [x] `.trellis/spec/**` sweep already done in Step 2; re-read one spec file to confirm naming coherence

## Step 6 — Commit

- [ ] Inspect `git status` — only this task's changes; the pre-existing dirty `.trellis/.template-hashes.json` (trellis form update, belongs to commit `6a4855a`'s lineage) must NOT be swept in unless the user says so
- [ ] Commit: `refactor!: rename project Pippin to Atmark` with body covering package/targets/bundle ID/identity/remotes/specs and the TCC consequence; reference the task path
- [x] Do NOT push (enforced)

## Rollback points

- After Step 1/2: `git checkout -- . && git clean -fd Sources Tests` (or reset to branch point)
- Step 3 operations invert individually: `git remote rename` back, re-add old origin, identity is additive (leave or delete via Keychain Access)
- Step 4 failure with obvious cause: fix forward; with structural cause: reset to branch point and re-plan

## Wrap-up notes for the user (manual, post-merge)

- Re-grant TCC: Full Disk Access (Mail data), Mail Automation, Reminders full access — first launch of `Atmark.app` will re-prompt or need System Settings
- Old `Pippin Local Signing` identity may be deleted from Keychain Access once the new app is verified (optional)
- Push `feat/atmark-rename` and set `main` upstream to the new origin when ready
- `.codegraph/` index is stale after the rename; rebuild it with your CodeGraph tooling
