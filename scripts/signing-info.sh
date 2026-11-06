#!/bin/sh
set -eu
for app in "${1:?Pass a bundle path}" /Applications/AIFleet.app; do
    [ -d "$app" ] || continue
    echo "Bundle: $app"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist"
    lipo -archs "$app/Contents/MacOS/AIFleet"
    lipo -archs "$app/Contents/MacOS/fleet-session-engine"
    codesign -dv -r- "$app" 2>&1
    codesign --verify --deep --strict "$app"
done
