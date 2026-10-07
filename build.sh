#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mode=${GKSDUD_SIGN_MODE:-local}
sign_args=()
case "$mode" in
  local)
    [[ -f signing/local-certificate.pem ]] || { echo 'Missing fixed signing certificate. Run signing/setup-local-signing.sh first.' >&2; exit 1; }
    fingerprint=$(openssl x509 -in signing/local-certificate.pem -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
    [[ "$fingerprint" =~ ^[A-Fa-f0-9]{40}$ ]] || exit 1
    sign_args=(--sign "$fingerprint" --timestamp=none)
    ;;
  developer-id)
    : "${GKSDUD_SIGN_IDENTITY:?Set Developer ID Application signing identity}"
    sign_args=(--sign "$GKSDUD_SIGN_IDENTITY" --timestamp)
    ;;
  ad-hoc)
    echo 'WARNING: ad-hoc signing does not preserve app identity across updates.' >&2
    sign_args=(--sign - --timestamp=none)
    ;;
  *) echo 'GKSDUD_SIGN_MODE must be local, developer-id, or ad-hoc' >&2; exit 1 ;;
esac
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
mkdir -p "$stage/gksdud.app/Contents/MacOS" "$stage/gksdud.app/Contents/Helpers" "$stage/gksdud.app/Contents/Resources" "$output_dir"
swiftc -parse-as-library -D ICON_GENERATOR -module-cache-path "$stage/module-cache" DudIcon.swift -o "$stage/icon-generator"
"$stage/icon-generator" "$stage/AppIcon.iconset"
iconutil -c icns "$stage/AppIcon.iconset" -o "$stage/gksdud.app/Contents/Resources/AppIcon.icns"
sources=(main.swift DudIcon.swift KeyboardManagement.swift KeyboardSettings.swift SettingsWindow.swift InputSources.swift UpdateChecking.swift UpdateInstaller.swift SpecialCharacters.swift CLI.swift CLIServer.swift KeyboardTests.swift FeatureTests.swift CLITests.swift SelfTest.swift)
cli_sources=(CLI.swift CLITool.swift)
compile() { swiftc -swift-version 5 -O -module-cache-path "$stage/module-cache" -import-objc-header Bridge.h "${sources[@]}" -framework AppKit -framework IOKit -framework ServiceManagement "$@"; }
for arch in arm64 x86_64; do
  compile -target "$arch-apple-macos13.0" -o "$stage/gksdud-$arch"
  swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$stage/module-cache" "${cli_sources[@]}" -target "$arch-apple-macos13.0" -o "$stage/cli-$arch"
done
lipo -create "$stage/gksdud-arm64" "$stage/gksdud-x86_64" -output "$stage/gksdud.app/Contents/MacOS/gksdud"
lipo -create "$stage/cli-arm64" "$stage/cli-x86_64" -output "$stage/gksdud.app/Contents/Helpers/gksdud"
cp Info.plist "$stage/gksdud.app/Contents/Info.plist"
cp LICENSE "$stage/gksdud.app/Contents/Resources/LICENSE"
cp Resources/github.svg Resources/fairy.svg Resources/OCTICONS-LICENSE "$stage/gksdud.app/Contents/Resources/"
if [[ -n "${GKSDUD_APP_VERSION:-}" ]]; then
  [[ "$GKSDUD_APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $GKSDUD_APP_VERSION" "$stage/gksdud.app/Contents/Info.plist"
fi
if [[ -n "${GKSDUD_BUILD_NUMBER:-}" ]]; then
  [[ "$GKSDUD_BUILD_NUMBER" =~ ^[0-9]+$ ]] || exit 1
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GKSDUD_BUILD_NUMBER" "$stage/gksdud.app/Contents/Info.plist"
fi
sign "$stage/gksdud.app/Contents/Helpers/gksdud" io.gksdud.inputswitch.cli
sign "$stage/gksdud.app" io.gksdud.inputswitch
codesign --verify --deep --strict "$stage/gksdud.app"
# The release app has no test code; the same bundle with the test modes compiled in (-D TESTS) runs them.
test_app="$stage/test/gksdud.app"
ditto "$stage/gksdud.app" "$test_app"
compile -D TESTS -target "$(uname -m)-apple-macos13.0" -o "$test_app/Contents/MacOS/gksdud"
sign "$test_app" io.gksdud.inputswitch
"$test_app/Contents/MacOS/gksdud" --self-test
# The command-line tool answers help without the app, and refuses wrong arguments before asking it.
"$stage/gksdud.app/Contents/Helpers/gksdud" help settings >/dev/null
if "$stage/gksdud.app/Contents/Helpers/gksdud" set no-such=on 2>/dev/null; then exit 1; else test $? -eq 2; fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$stage/gksdud.app/Contents/Info.plist")
ditto -c -k --keepParent --norsrc "$stage/gksdud.app" "$output_dir/gksdud-$version-macos-universal.zip"
codesign -d -r- "$stage/gksdud.app"
echo "Built app: $stage/gksdud.app"
echo "Test app: $test_app"
