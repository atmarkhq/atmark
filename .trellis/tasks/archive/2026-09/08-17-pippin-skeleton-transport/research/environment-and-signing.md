# Step 0 — Environment and Signing Preconditions

Gathered 2026-08-18 on the user's machine, read-only. Feeds `implement.md` step 0
and step 2.

## Toolchain — all preconditions met

| Item | Value | Verdict |
|---|---|---|
| macOS | 26.5.1 (build 25F80) | matches C4 |
| Xcode | 26.5 (17F42) | matches C4 |
| macOS SDK | 26.5 | Liquid Glass appearance available by building against it |
| Swift | 6.3.2 | Swift 6 language mode available |
| Default target | `arm64-apple-macosx26.0` | `platforms: [.macOS(.v26)]` is correct |

No toolchain work is needed before step 1.

## Signing identities present

`security find-identity -v -p codesigning` reports 4 valid identities, all of the
same free-tier Apple ID:

```
2) C083AEA2… "Apple Development: iswuzhi@gmail.com (4AR9CL8R86)"
4) EFF09806… "Apple Development: iswuzhi@gmail.com (4AR9CL8R86)"
   (plus 2 more of the same subject marked CSSMERR_TP_CERT_REVOKED)
```

No `Pippin` certificate exists yet.

Note the Apple ID here (`iswuzhi@gmail.com`) differs from the git author identity
(`is.52hertz@gmail.com`). Not a problem, just worth knowing so the identity used
for signing is chosen deliberately rather than by whichever one a script finds
first.

## Finding that matters for O2

An **Apple Development** certificate already exists, so it is technically usable
for signing. It should still *not* be the identity Pippin uses. Reasons:

1. **Xcode rotates and revokes these.** Two of the four are already revoked —
   direct evidence of churn on this machine. C3 requires an identity that never
   changes; an identity Xcode manages on its own schedule is the opposite of that,
   and a rotation would silently invalidate every TCC grant the user has given.
2. **It is not ours to control.** A dedicated self-signed identity created once by
   `Scripts/setup_dev_signing.sh` is owned by this project and has no external
   process with a reason to replace it.
3. The existing certs are tied to a free-tier account anyway, so they buy nothing
   that self-signing does not — no notarization, no Developer ID.

**Conclusion: proceed with the self-signed path as decided in O2**, and have
`setup_dev_signing.sh` create a clearly named identity (e.g. `Pippin Local
Signing`) rather than discovering an `Apple Development:` cert from the keychain.
The script must refuse to overwrite it once created.

## Still open in step 0 (not yet done)

- Resolve the `modelcontextprotocol/swift-sdk` version and confirm against the
  real package: `StatefulHTTPServerTransport` init and `HTTPRequestValidator`
  shape; `StdioTransport`; `Tool` / `Tool.Annotations` / `outputSchema`;
  `Server.withMethodHandler(ListTools/CallTool)`; how
  `notifications/tools/list_changed` is emitted.
- **The stop condition:** whether the SDK exposes a per-request session identifier.
  Confirm-token session binding (parent criterion A2) depends on it. If it is not
  exposed, stop and revise the parent `design.md` before writing any tool.
- Throwaway `swift build` compiling a minimal server against the resolved version.
