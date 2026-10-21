#!/bin/sh
# Wraps the built MacosAgent executable in a minimal .app bundle. This exists for exactly one
# reason: UNUserNotificationCenter (and other proper-app-identity APIs) refuse to work - not
# silently, they crash - when run as a loose `swift build` executable with no bundle
# identifier. There is no other change here: same binary, same behavior, just given a real
# bundle so macOS treats it as a real app.
set -e
cd "$(dirname "$0")"

swift build

APP="AirBridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/MacosAgent "$APP/Contents/MacOS/MacosAgent"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>MacosAgent</string>
	<key>CFBundleIdentifier</key>
	<string>com.airbridge.macos-agent</string>
	<key>CFBundleName</key>
	<string>AirBridge</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
</dict>
</plist>
PLIST

echo "Built $APP - run it with: open $APP (or exec $APP/Contents/MacOS/MacosAgent directly)"
