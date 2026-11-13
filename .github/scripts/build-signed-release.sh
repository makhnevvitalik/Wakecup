#!/bin/bash
# Import signing material only on an ephemeral GitHub-hosted macOS runner.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted && "${RUNNER_OS:-}" == macOS ]] || {
  echo "This script is restricted to GitHub-hosted macOS runners." >&2; exit 2
}
: "${SIGNING_CERTIFICATE_P12:?Missing MACOS_SIGNING_CERTIFICATE_P12 secret}"
: "${SIGNING_CERTIFICATE_PASSWORD:?Missing MACOS_SIGNING_CERTIFICATE_PASSWORD secret}"
: "${SIGNING_CERTIFICATE_NAME:?Missing SIGNING_CERTIFICATE_NAME variable}"
: "${SIGNING_CERTIFICATE_SHA1:?Missing SIGNING_CERTIFICATE_SHA1 variable}"
identity="$(printf '%s' "$SIGNING_CERTIFICATE_SHA1" | tr '[:lower:]' '[:upper:]')"
[[ "$identity" =~ ^[A-F0-9]{40}$ ]] || { echo 'Invalid certificate SHA-1' >&2; exit 2; }
work="$(mktemp -d "$RUNNER_TEMP/wakecup-signing-XXXXXXXX")"
keychain="$work/signing.keychain-db"
keychain_password="$(openssl rand -base64 36 | tr -d '\n')"
echo "::add-mask::$keychain_password"
original_keychains=()
while IFS= read -r item; do
  item="${item#"${item%%[![:space:]]*}"}"
  item="${item%"${item##*[![:space:]]}"}"
  item="${item#\"}"; item="${item%\"}"
  [[ -z "$item" ]] || original_keychains+=("$item")
done < <(security list-keychains -d user)
cleanup() {
  security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077
printf '%s' "$SIGNING_CERTIFICATE_P12" | base64 --decode > "$work/signing.p12"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security list-keychains -d user -s "$keychain" "${original_keychains[@]}"
security import "$work/signing.p12" -k "$keychain" -P "$SIGNING_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
security find-certificate -c "$SIGNING_CERTIFICATE_NAME" -p "$keychain" > "$work/certificate.pem"
actual="$(openssl x509 -in "$work/certificate.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
[[ "$actual" == "$identity" ]] || { echo 'Certificate does not match the configured fingerprint' >&2; exit 1; }
openssl x509 -in "$work/certificate.pem" -outform DER -out "$work/certificate.der"
# Same self-signed certificate trust mechanism as Language Switcher Plus.
# Never run this on a personal Mac: trust is confined to the disposable runner.
swiftc -suppress-warnings .github/scripts/trust-certificate.swift -o "$work/trust-certificate"
sudo "$work/trust-certificate" "$work/certificate.der"
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
security find-identity -v -p codesigning "$keychain" | awk -v expected="$identity" '
  $2 == expected { found = 1 }
  END { exit !found }
' || { echo 'Configured certificate is not a valid signing identity' >&2; exit 1; }
export WAKECUP_SIGNING_IDENTITY="$identity"
export WAKECUP_REQUIRE_RELEASE_SIGNING=1
./build-release.sh
