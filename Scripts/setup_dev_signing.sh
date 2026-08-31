#!/usr/bin/env bash
#
# Create Atmark's long-lived local code-signing identity. Run once per machine.
#
# Why this matters more than it looks: macOS keys TCC grants (Automation, Full
# Disk Access, Reminders) to the code signature. Replacing the certificate does
# not produce an error — it silently invalidates every permission the user has
# granted, and the app starts failing in ways that look like bugs. So this script
# refuses to touch an existing identity, and there is deliberately no --force.
#
# Self-signed only. There is no paid Apple Developer account behind this project
# (parent decision O2), so Developer ID and notarization are permanently out of
# reach. Signing branches for them are not merely unused here, they are a live
# footgun, so they are absent.
#
# Secrets policy: this script exports nothing. Private key material exists only
# inside a mode-0700 temporary directory under $TMPDIR — never inside the
# repository — and is wiped on exit, including on failure and interrupt. No
# .p12, .cer, or key file survives the run.
#
# macOS gives no way to do better than that. Verified, not assumed:
#   - certtool can generate a key pair directly inside the keychain with no file
#     at all, but its only Extended Key Usage option is "Any", and codesign then
#     rejects the result with "no identity found".
#   - `security import` cannot read a pipe ("Unable to decode the provided
#     data"); it needs a seekable file, so the PKCS#12 must briefly be one.
#   - `security add-trusted-cert` takes a certificate file, and without it the
#     identity stays CSSMERR_TP_NOT_TRUSTED and codesign will not use it.
#
# Expect two macOS authorization prompts. They are inherent, not incidental:
# one grants codesign access to the new private key, one writes the trust
# setting. Approve both.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../version.env
source "$ROOT/version.env"

IDENTITY="${SIGNING_IDENTITY}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
VALIDITY_DAYS=7300   # ~20 years; the identity must outlive the user's patience,
                     # because its expiry would break TCC exactly like a rotation

# --- Refuse to overwrite -----------------------------------------------------

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "Identity '$IDENTITY' already exists. Nothing to do."
  echo
  echo "This script never replaces an existing identity: doing so would silently"
  echo "invalidate every TCC grant already given to Atmark.app."
  echo
  security find-identity -v -p codesigning | grep -F "$IDENTITY" || true
  echo
  echo "If you genuinely need to start over, delete the certificate by hand in"
  echo "Keychain Access, then re-run. Expect to re-grant every permission."
  exit 0
fi

# --- Generate, import, trust -------------------------------------------------

TMPDIR_SECURE=$(mktemp -d)
chmod 700 "$TMPDIR_SECURE"
trap 'rm -rf "$TMPDIR_SECURE"' EXIT INT TERM

echo "Creating self-signed code-signing identity '$IDENTITY'..."

cat > "$TMPDIR_SECURE/req.cnf" <<CONF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = ${IDENTITY}
O  = ${APP_NAME}

[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CONF

openssl req -x509 -newkey rsa:4096 -sha256 -days "$VALIDITY_DAYS" -nodes \
  -config "$TMPDIR_SECURE/req.cnf" \
  -keyout "$TMPDIR_SECURE/key.pem" \
  -out    "$TMPDIR_SECURE/cert.pem" 2>/dev/null

# A random transport password, used only between these two adjacent commands.
# Apple's Security framework rejects OpenSSL 3.x's default PKCS#12 encoding, so
# -legacy and -macalg sha1 are required, not stylistic.
P12_PASSWORD=$(openssl rand -hex 24)
openssl pkcs12 -export -legacy -macalg sha1 \
  -name "$IDENTITY" \
  -inkey "$TMPDIR_SECURE/key.pem" \
  -in    "$TMPDIR_SECURE/cert.pem" \
  -out   "$TMPDIR_SECURE/identity.p12" \
  -passout "pass:${P12_PASSWORD}" 2>/dev/null

echo "Importing into the login keychain (expect an authorization prompt)..."
security import "$TMPDIR_SECURE/identity.p12" \
  -k "$KEYCHAIN" \
  -P "$P12_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

echo "Marking it trusted for code signing (expect a second prompt)..."
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMPDIR_SECURE/cert.pem"

# --- Verify ------------------------------------------------------------------

if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  echo "ERROR: '$IDENTITY' was created but is not a valid code-signing identity." >&2
  echo "Check Keychain Access: the certificate must be trusted for code signing." >&2
  exit 1
fi

FINGERPRINT=$(security find-identity -v -p codesigning \
              | grep -F "$IDENTITY" | awk '{print $2}')

echo
echo "Done. '$IDENTITY' is ready."
echo "  SHA-1: $FINGERPRINT"
echo
echo "Record that fingerprint. Every Atmark build must report the same one;"
echo "if it ever changes, the TCC grants are gone and the permissions must be"
echo "granted again from scratch."
