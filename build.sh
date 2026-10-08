#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
team=$(tr -d '\n\r' < signing/developer-team-id)
# The team's Developer ID signs releases; a Mac without it in the keychain falls back to the self-signed identity.
developer_id() {
  security find-identity -v -p codesigning | sed -n -E "s/^ *[0-9]+\) ([0-9A-F]{40}) \"Developer ID Application: .* \($team\)\"$/\1/p" | head -1 || true
}
mode=${GKSDUD_SIGN_MODE:-$([[ -n $(developer_id) ]] && echo developer-id || echo local)}
# Canary is a separate app, gksdud-dev, with its own settings, permissions and update channel.
channel=${GKSDUD_CHANNEL:-stable}
case $channel in
  stable) app=gksdud identifier=io.gksdud.inputswitch ;;
  canary) app=gksdud-dev identifier=io.gksdud.inputswitch.dev ;;
  *) echo 'GKSDUD_CHANNEL must be stable or canary' >&2; exit 1 ;;
esac
notary=()
if [[ -n "${GKSDUD_NOTARY_PROFILE:-}" ]]; then
  notary=(--keychain-profile "$GKSDUD_NOTARY_PROFILE")
elif [[ -n "${GKSDUD_NOTARY_KEY:-}" ]]; then
  notary=(--key "$GKSDUD_NOTARY_KEY" --key-id "${GKSDUD_NOTARY_KEY_ID:?Set the App Store Connect API key ID}" --issuer "${GKSDUD_NOTARY_ISSUER:?Set the App Store Connect issuer ID}")
fi
sign_args=()
case "$mode" in
  local)
    [[ -f signing/local-certificate.pem ]] || { echo 'Missing fixed signing certificate. Run signing/setup-local-signing.sh first.' >&2; exit 1; }
    fingerprint=$(openssl x509 -in signing/local-certificate.pem -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
    [[ "$fingerprint" =~ ^[A-Fa-f0-9]{40}$ ]] || exit 1
    sign_args=(--sign "$fingerprint" --timestamp=none)
    ;;
  developer-id)
    identity=${GKSDUD_SIGN_IDENTITY:-$(developer_id)}
    [[ -n "$identity" ]] || { echo "No Developer ID Application identity of team $team. Set GKSDUD_SIGN_IDENTITY." >&2; exit 1; }
    # Notarization needs a secure timestamp; other builds skip the network call.
    timestamp=--timestamp=none
    [[ ${#notary[@]} -eq 0 ]] || timestamp=--timestamp
    sign_args=(--sign "$identity" "$timestamp")
    ;;
  ad-hoc)
    echo 'WARNING: ad-hoc signing does not preserve app identity across updates.' >&2
    sign_args=(--sign - --timestamp=none)
    ;;
  *) echo 'GKSDUD_SIGN_MODE must be local, developer-id, or ad-hoc' >&2; exit 1 ;;
esac
[[ ${#notary[@]} -eq 0 || $mode == developer-id ]] || { echo 'Notarization needs GKSDUD_SIGN_MODE=developer-id.' >&2; exit 1; }
# The command-line tool inside is signed before the app, with an identifier of its own.
sign() {
  local requirement=()
  if [[ $mode == local ]]; then
    requirement=(--requirements "=designated => identifier \"$2\" and certificate leaf = H\"$fingerprint\"")
  fi
  codesign --force "${sign_args[@]}" ${requirement[@]+"${requirement[@]}"} --identifier "$2" --options runtime "$1"
}
output_dir=${GKSDUD_OUTPUT_DIR:-"$PWD/outputs"}
stage=$(mktemp -d /private/tmp/gksdud-build.XXXXXX)
mkdir -p "$stage/$app.app/Contents/MacOS" "$stage/$app.app/Contents/Helpers" "$stage/$app.app/Contents/Resources" "$output_dir"
swiftc -parse-as-library -D ICON_GENERATOR -module-cache-path "$stage/module-cache" DudIcon.swift -o "$stage/icon-generator"
"$stage/icon-generator" "$stage/AppIcon.iconset"
iconutil -c icns "$stage/AppIcon.iconset" -o "$stage/$app.app/Contents/Resources/AppIcon.icns"
sources=(main.swift DudIcon.swift KeyboardManagement.swift KeyboardSettings.swift SettingsWindow.swift InputSources.swift UpdateChecking.swift UpdateInstaller.swift SpecialCharacters.swift CLI.swift CLIServer.swift KeyboardTests.swift FeatureTests.swift CLITests.swift SelfTest.swift)
cli_sources=(CLI.swift CLITool.swift)
compile() { swiftc -swift-version 5 -O -module-cache-path "$stage/module-cache" -import-objc-header Bridge.h "${sources[@]}" -framework AppKit -framework IOKit -framework ServiceManagement "$@"; }
for arch in arm64 x86_64; do
  compile -target "$arch-apple-macos13.0" -o "$stage/gksdud-$arch"
  swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$stage/module-cache" "${cli_sources[@]}" -target "$arch-apple-macos13.0" -o "$stage/cli-$arch"
done
lipo -create "$stage/gksdud-arm64" "$stage/gksdud-x86_64" -output "$stage/$app.app/Contents/MacOS/gksdud"
lipo -create "$stage/cli-arm64" "$stage/cli-x86_64" -output "$stage/$app.app/Contents/Helpers/gksdud"
cp Info.plist "$stage/$app.app/Contents/Info.plist"
if [[ $channel == canary ]]; then
  for key in CFBundleName CFBundleDisplayName; do /usr/libexec/PlistBuddy -c "Set :$key $app" "$stage/$app.app/Contents/Info.plist"; done
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $identifier" -c 'Add :GKSDUDChannel string canary' "$stage/$app.app/Contents/Info.plist"
fi
cp LICENSE "$stage/$app.app/Contents/Resources/LICENSE"
cp Resources/github.svg Resources/fairy.svg Resources/OCTICONS-LICENSE "$stage/$app.app/Contents/Resources/"
if [[ -n "${GKSDUD_APP_VERSION:-}" ]]; then
  [[ "$GKSDUD_APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $GKSDUD_APP_VERSION" "$stage/$app.app/Contents/Info.plist"
fi
if [[ -n "${GKSDUD_BUILD_NUMBER:-}" ]]; then
  [[ "$GKSDUD_BUILD_NUMBER" =~ ^[0-9]+$ ]] || exit 1
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GKSDUD_BUILD_NUMBER" "$stage/$app.app/Contents/Info.plist"
fi
sign "$stage/$app.app/Contents/Helpers/gksdud" "$identifier.cli"
sign "$stage/$app.app" "$identifier"
codesign --verify --deep --strict "$stage/$app.app"
# The release app has no test code; the same bundle with the test modes compiled in (-D TESTS) runs them.
test_app="$stage/test/$app.app"
ditto "$stage/$app.app" "$test_app"
compile -D TESTS -target "$(uname -m)-apple-macos13.0" -o "$test_app/Contents/MacOS/gksdud"
sign "$test_app" "$identifier"
"$test_app/Contents/MacOS/gksdud" --self-test
# The command-line tool answers help without the app, and refuses wrong arguments before asking it.
"$stage/$app.app/Contents/Helpers/gksdud" help settings >/dev/null
if "$stage/$app.app/Contents/Helpers/gksdud" set no-such=on 2>/dev/null; then exit 1; else test $? -eq 2; fi
if [[ ${#notary[@]} -gt 0 ]]; then
  ditto -c -k --keepParent --norsrc "$stage/$app.app" "$stage/notarize.zip"
  result=$(xcrun notarytool submit "$stage/notarize.zip" "${notary[@]}" --wait --timeout 30m --output-format json) || true
  if [[ $(plutil -extract status raw - <<<"$result" 2>/dev/null) != Accepted ]]; then
    echo "Notarization failed: $result" >&2
    id=$(plutil -extract id raw - <<<"$result" 2>/dev/null) && xcrun notarytool log "$id" "${notary[@]}" >&2 || true
    exit 1
  fi
  xcrun stapler staple "$stage/$app.app"
  spctl --assess --type execute -vv "$stage/$app.app"
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$stage/$app.app/Contents/Info.plist")
ditto -c -k --keepParent --norsrc "$stage/$app.app" "$output_dir/$app-$version-macos-universal.zip"
codesign -d -r- "$stage/$app.app"
echo "Built app: $stage/$app.app"
echo "Test app: $test_app"
