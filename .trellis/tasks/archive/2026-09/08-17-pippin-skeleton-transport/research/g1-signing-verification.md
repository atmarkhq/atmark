# Gate G1 — Signing Identity Stability, Verified

Run 2026-08-23 on the user's machine. This gate exists because the whole project
rests on one assumption: that a rebuilt Pippin.app keeps the TCC grants the user
gave the previous build. That assumption is now measured, not believed.

## The identity

```
Name        Pippin Local Signing
SHA-1       1AB7E0BC58C427092143FBADABA7F34CD607775D
Algorithm   RSA 4096, SHA-256, EKU codeSigning (critical)
Validity    7300 days (~20 years)
Keychain    ~/Library/Keychains/login.keychain-db
Bundle ID   io.github.is52hertz.pippin
```

**Never regenerate this certificate.** Doing so raises no error; it silently
invalidates every Automation, Full Disk Access, and Reminders grant. The 20-year
validity is chosen for the same reason — expiry and rotation fail identically.

## What TCC actually keys on

```
designated => identifier "io.github.is52hertz.pippin"
              and certificate root = H"1ab7e0bc58c427092143fbadaba7f34cd607775d"
```

Two invariants, both now pinned: the bundle identifier in `version.env` and the
certificate above. The binary's CDHash is *not* part of this, which is precisely
why rebuilding is safe and re-signing with a different certificate is not.

The shim carries the same certificate root under its own identifier:

```
designated => identifier "pippin-shim"
              and certificate root = H"1ab7e0bc58c427092143fbadaba7f34cd607775d"
```

## Gate result

Three consecutive `rm -rf build && Scripts/package_app.sh` cycles. For each run,
the `Authority`, `Identifier`, `TeamIdentifier`, and full designated requirement
were captured and diffed.

| Check | Result |
|---|---|
| Run 1 vs run 2 | identical |
| Run 1 vs run 3 | identical |
| Signing identity across all three | `1AB7E0BC…775D`, unchanged |
| `codesign --verify --deep --strict` | valid on disk; satisfies its Designated Requirement |
| Nested shim | signed with the same authority, validated by the deep verify |
| Launch smoke test | bundle launches, `pgrep -x Pippin` finds it, quits cleanly |

**G1 passed.**

## Negative and idempotency checks

- With no identity present, `package_app.sh` exits 1 before building and does not
  create `build/`. The upstream template's `codesign --sign -` fallback is gone,
  so there is no path by which a build silently becomes ad-hoc signed.
- Re-running `setup_dev_signing.sh` refuses to touch the existing identity and
  exits 0.
- After the run, no `*.p12`, `key.pem`, `cert.pem`, or `req.cnf` remains anywhere
  under `$TMPDIR`; the trap fired.

## Honest caveats

- `spctl --assess` reported `accepted / override=security disabled`. Gatekeeper
  assessment is turned off on this machine, so that command proved nothing. It is
  not evidence the bundle would pass Gatekeeper elsewhere — it would not, being
  self-signed and un-notarized. That is expected and accepted under O2; this app
  is only ever installed locally.
- The first launch of a self-signed bundle on a machine with Gatekeeper enabled
  would require an explicit user override. Not applicable here.
- `setup_dev_signing.sh` triggers two macOS authorization prompts, one to grant
  codesign access to the private key and one to write the trust setting. Both are
  inherent to the only working path; see the script header for the alternatives
  that were tested and rejected.
