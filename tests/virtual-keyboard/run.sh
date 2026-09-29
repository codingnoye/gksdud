#!/bin/bash
# Runs HidProbe against vhid-keys started as: sudo tests/virtual-keyboard/build/vhid-keys tests/virtual-keyboard/build/vhid.sock
# Extra arguments go to HidProbe (--reset).
set -euo pipefail
cd "$(dirname "$0")"
socket="$PWD/build/vhid.sock"
[[ -S "$socket" ]] || { echo "Start the helper first: sudo $PWD/build/vhid-keys $socket" >&2; exit 1; }
output="$PWD/build/result.txt"
rm -f "$output"
open -n -W --stdout "$output" --stderr /dev/null build/HidProbe.app --args "$socket" "$@"
cat "$output"
result=$(grep '^RESULT: ' "$output" || true)
[[ $result =~ ^RESULT:\ ([0-9]+)/([0-9]+)$ && ${BASH_REMATCH[1]} == "${BASH_REMATCH[2]}" ]] || grep -q '^reset:' "$output"
