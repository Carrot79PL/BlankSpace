#!/bin/bash
# Buduje BlankSpace.app (release, podpis ad-hoc z Hardened Runtime)
set -e
cd "$(dirname "$0")"
swift build -c release
APP="BlankSpace.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BlankSpace "$APP/Contents/MacOS/BlankSpace"
cp Assets/podpis_logo.png "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/pl.lproj"
cp Assets/en.lproj/Localizable.strings "$APP/Contents/Resources/en.lproj/"
: > "$APP/Contents/Resources/pl.lproj/Localizable.strings"
[ -f Assets/AppIcon.icns ] && cp Assets/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>BlankSpace</string>
<key>CFBundleDisplayName</key><string>BlankSpace</string>
<key>CFBundleIdentifier</key><string>studio.tm.blankspace</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDevelopmentRegion</key><string>pl</string>
<key>CFBundleLocalizations</key><array><string>pl</string><string>en</string></array>
<key>CFBundleExecutable</key><string>BlankSpace</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSRemovableVolumesUsageDescription</key><string>BlankSpace potrzebuje dostępu do dysków zewnętrznych, aby nadpisać na nich wolne miejsce.</string>
</dict></plist>
PL
codesign --force --options runtime --sign - "$APP"
echo "OK: $(pwd)/$APP"

if [ "$1" = "dmg" ]; then
  rm -rf dmg_stage BlankSpace.dmg; mkdir dmg_stage
  cp -R "$APP" dmg_stage/; ln -s /Applications dmg_stage/Applications
  hdiutil create -volname "BlankSpace" -srcfolder dmg_stage -ov -format UDZO BlankSpace.dmg >/dev/null
  rm -rf dmg_stage; echo "DMG: $(pwd)/BlankSpace.dmg"
fi
