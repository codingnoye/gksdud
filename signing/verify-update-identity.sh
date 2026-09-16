#!/bin/bash
set -euo pipefail
if [[ $# != 2 ]]; then echo "Usage: $0 old.app new.app" >&2; exit 1; fi
first=$1
second=$2
requirement() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'; }
old_requirement=$(requirement "$first")
new_requirement=$(requirement "$second")
[[ -n "$old_requirement" && "$old_requirement" == "$new_requirement" ]]
[[ "$old_requirement" != *cdhash* ]]
for bundle in "$first" "$second"; do
  codesign --verify --all-architectures --strict -R "=$old_requirement" "$bundle"
done
first_hash=$(shasum -a 256 "$first/Contents/MacOS/gksdud" | cut -d ' ' -f 1)
second_hash=$(shasum -a 256 "$second/Contents/MacOS/gksdud" | cut -d ' ' -f 1)
[[ "$first_hash" != "$second_hash" ]]
echo "PASS: different signed binaries satisfy the same certificate-bound designated requirement."
echo "$old_requirement"
echo 'This does not prove live TCC permission retention; test an authorized installed-app update separately.'
