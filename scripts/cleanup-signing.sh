#!/bin/bash
# Only for disposable GitHub-hosted runners, never a developer's keychain.
set -uo pipefail
[[ "${RUNNER_ENVIRONMENT:-}" == github-hosted && "${RUNNER_TEMP:-}" == /* ]] || {
  echo 'Refusing cleanup outside a GitHub-hosted runner.' >&2
  exit 1
}
keychain="$RUNNER_TEMP/gksdud-signing.keychain-db"
certificate="$RUNNER_TEMP/gksdud-signing.p12"
public_certificate=signing/local-certificate.pem
result=0
echo 'Removing temporary P12'
rm -f "$certificate" || result=1

echo 'Deleting temporary private-key keychain (30 second limit)'
if [[ -f "$keychain" ]]; then
  python3 scripts/run-with-timeout.py 30 security delete-keychain "$keychain" || result=1
fi

echo 'Removing public certificate trust (20 second limit)'
if [[ -f "$public_certificate" ]]; then
  # The watchdog must run as root too, so it can kill the root security process.
  sudo -n /usr/bin/python3 scripts/run-with-timeout.py 20 /usr/bin/security remove-trusted-cert -d "$public_certificate" ||
    echo '::warning::Trust removal failed or timed out; the disposable runner will be destroyed.'
fi
echo 'Removing temporary public certificate'
rm -f "$public_certificate" || result=1
exit "$result"
