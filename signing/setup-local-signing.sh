#!/bin/bash
# Run only after explicitly approving key creation/import and user code-signing trust.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" != "--create-and-trust" ]]; then
  echo "Usage: bash signing/setup-local-signing.sh --create-and-trust"
  echo "Creates a private signing identity in the login keychain and trusts it for code signing only."
  exit 1
fi
identity='CodingNoye gksdud Local Signing'
keychain="$HOME/Library/Keychains/login.keychain-db"
if [[ -e signing/local-certificate.pem ]] || security find-certificate -c "$identity" "$keychain" >/dev/null 2>&1; then
  echo 'An identity already exists. Refusing to rotate it or overwrite its public certificate.' >&2
  exit 1
fi
umask 077
private_stage=$(mktemp -d /private/tmp/gksdud-signing.XXXXXX)
cleanup() {
  rm -f "$private_stage/private.key" "$private_stage/identity.p12" "$private_stage/certificate.pem"
  rmdir "$private_stage"
}
trap cleanup EXIT
openssl req -new -x509 -newkey rsa:3072 -nodes -days 3650 -sha256 \
  -config signing/openssl.cnf -keyout "$private_stage/private.key" -out "$private_stage/certificate.pem"
# Random transport password only in this process, never logged or persisted.
transport_password=$(openssl rand -hex 24)
export GKSDUD_P12_PASSWORD="$transport_password"
openssl pkcs12 -export -inkey "$private_stage/private.key" -in "$private_stage/certificate.pem" \
  -name "$identity" -out "$private_stage/identity.p12" -passout env:GKSDUD_P12_PASSWORD
security import "$private_stage/identity.p12" -k "$keychain" -P "$transport_password" -T /usr/bin/codesign
unset GKSDUD_P12_PASSWORD transport_password
# Preserve only the public certificate; no private key enters the project.
cp "$private_stage/certificate.pem" signing/local-certificate.pem
chmod 644 signing/local-certificate.pem
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" signing/local-certificate.pem
echo 'Created persistent signing identity. Back up the identity securely through Keychain Access.'
openssl x509 -in signing/local-certificate.pem -noout -subject -fingerprint -sha256
