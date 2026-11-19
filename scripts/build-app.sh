#!/usr/bin/env bash
# Builds dist/ClaudeUsageBar.app and dist/ClaudeUsageBar.zip: a universal
# (Apple silicon + Intel) app, ad-hoc signed. No Developer ID involved.
# Usage: scripts/build-app.sh [version]   (default: from git tags)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
APP="dist/ClaudeUsageBar.app"

swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf dist
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/ClaudeUsageBar" "$APP/Contents/MacOS/ClaudeUsageBar"
# The app icon: an Icon Composer file the app draws from the menu bar
# glyph, compiled into Assets.car (macOS 26) and AppIcon.icns (older).
mkdir -p "$APP/Contents/Resources"
# actool quietly does nothing with relative paths.
"$BIN_DIR/ClaudeUsageBar" render-icon "$ROOT/dist/AppIcon.icon"
xcrun actool "$ROOT/dist/AppIcon.icon" --compile "$ROOT/$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist "$ROOT/dist/AppIcon-Info.plist" >/dev/null
test -f "$APP/Contents/Resources/Assets.car" || { echo "actool didn't make the app icon" >&2; exit 1; }
rm -rf dist/AppIcon.icon dist/AppIcon-Info.plist
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.kemasaqar.ClaudeUsageBar</string>
  <key>CFBundleName</key><string>ClaudeUsageBar</string>
  <key>CFBundleDisplayName</key><string>Claude Usage Bar</string>
  <key>CFBundleExecutable</key><string>ClaudeUsageBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Menu bar only: no Dock icon, no app menu. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" dist/ClaudeUsageBar.zip
echo "Built $APP ($VERSION) and dist/ClaudeUsageBar.zip"
