#!/bin/bash
# Only for disposable GitHub-hosted runners, never a developer's keychain.
set -uo pipefail
[[ "${RUNNER_ENVIRONMENT:-}" == github-hosted && "${RUNNER_TEMP:-}" == /* ]] || {
  echo 'Refusing cleanup outside a GitHub-hosted runner.' >&2
  exit 1
}
keychain="$RUNNER_TEMP/gksdud-signing.keychain-db"
certificate="$RUNNER_TEMP/gksdud-signing.p12"
notary="$RUNNER_TEMP/gksdud-notary"
result=0
echo 'Removing temporary P12 and notary key'
rm -f "$certificate" "$notary/AuthKey.p8" || result=1

echo 'Deleting temporary private-key keychain (30 second limit)'
if [[ -f "$keychain" ]]; then
  python3 scripts/run-with-timeout.py 30 security delete-keychain "$keychain" || result=1
fi
exit "$result"
