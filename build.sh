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
    sign_args=(--sign "$fingerprint" --timestamp=none --requirements "=designated => identifier \"io.gksdud.inputswitch\" and certificate leaf = H\"$fingerprint\"")
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
output_dir=${GKSDUD_OUTPUT_DIR:-"$PWD/outputs"}
stage=$(mktemp -d /private/tmp/gksdud-build.XXXXXX)
mkdir -p "$stage/gksdud.app/Contents/MacOS" "$stage/gksdud.app/Contents/Resources" "$output_dir"
swiftc -parse-as-library -D ICON_GENERATOR -module-cache-path "$stage/module-cache" DudIcon.swift -o "$stage/icon-generator"
"$stage/icon-generator" "$stage/AppIcon.iconset"
iconutil -c icns "$stage/AppIcon.iconset" -o "$stage/gksdud.app/Contents/Resources/AppIcon.icns"
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O -target "$arch-apple-macos13.0" -module-cache-path "$stage/module-cache" -import-objc-header Bridge.h main.swift DudIcon.swift KeyboardManagement.swift KeyboardSettings.swift KeyboardTests.swift SettingsWindow.swift UpdateChecking.swift UpdateInstaller.swift SpecialCharacters.swift FeatureTests.swift -o "$stage/gksdud-$arch" -framework AppKit -framework IOKit -framework ServiceManagement
done
lipo -create "$stage/gksdud-arm64" "$stage/gksdud-x86_64" -output "$stage/gksdud.app/Contents/MacOS/gksdud"
cp Info.plist "$stage/gksdud.app/Contents/Info.plist"
cp LICENSE "$stage/gksdud.app/Contents/Resources/LICENSE"
if [[ -n "${GKSDUD_BUILD_NUMBER:-}" ]]; then
  [[ "$GKSDUD_BUILD_NUMBER" =~ ^[0-9]+$ ]] || exit 1
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GKSDUD_BUILD_NUMBER" "$stage/gksdud.app/Contents/Info.plist"
fi
codesign --force "${sign_args[@]}" --options runtime "$stage/gksdud.app"
codesign --verify --deep --strict "$stage/gksdud.app"
"$stage/gksdud.app/Contents/MacOS/gksdud" --self-test
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
ditto -c -k --keepParent --norsrc "$stage/gksdud.app" "$output_dir/gksdud-$version-macos-universal.zip"
codesign -d -r- "$stage/gksdud.app"
echo "Built app: $stage/gksdud.app"
