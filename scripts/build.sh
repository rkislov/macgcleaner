#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
APP="$PWD/build/MacGCleaner.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
export MACOSX_DEPLOYMENT_TARGET=13.0
export CGO_CFLAGS="-mmacosx-version-min=13.0"
export CGO_LDFLAGS="-mmacosx-version-min=13.0"
CGO_ENABLED=1 go build -trimpath -ldflags='-s -w' -o "$APP/Contents/MacOS/cleaner-engine" ./cmd/cleaner
swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx13.0" native/MacGCleaner.swift -o "$APP/Contents/MacOS/MacGCleaner" -framework SwiftUI -framework AppKit
cp native/Info.plist "$APP/Contents/Info.plist"
cp LICENSE NOTICE "$APP/Contents/Resources/"
swift native/BuildIcon.swift "$PWD/build/AppIcon.iconset"
iconutil -c icns "$PWD/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP/Contents/MacOS/cleaner-engine"
codesign --force --sign - "$APP"
print "Built: $APP"
