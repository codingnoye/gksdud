#!/bin/bash
# Builds build/vhid-keys and build/HidProbe.app. The Karabiner client headers are fetched for the installed daemon's version.
set -euo pipefail
cd "$(dirname "$0")"
daemon='/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app'
[[ -d "$daemon" ]] || { echo 'Install Karabiner-Elements first; its virtual keyboard daemon is required.' >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$daemon/Contents/Info.plist")
source="build/Karabiner-DriverKit-VirtualHIDDevice-$version"
mkdir -p build
# The client headers and their dependencies are committed there; the client protocol must match the daemon.
[[ -d "$source" ]] || git -c advice.detachedHead=false clone -q --depth 1 --branch "v$version" https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice.git "$source"
clang++ -std=c++2b -O1 -Wall -isystem "$source/vendor/vendor/include" -I "$source/include" vhid-keys.cpp -o build/vhid-keys \
  -framework IOKit -framework CoreFoundation
app=build/HidProbe.app
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.gksdud.hid-probe</string>
<key>CFBundleName</key><string>HidProbe</string>
<key>CFBundleExecutable</key><string>HidProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
swiftc -O -module-cache-path "$PWD/build/module-cache" HidProbe.swift -o "$app/Contents/MacOS/HidProbe" -framework AppKit -framework IOKit
codesign --force --sign - "$app" 2> /dev/null
echo "Built build/vhid-keys and $app for virtual HID daemon $version"
