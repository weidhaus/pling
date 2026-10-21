#!/bin/sh
# Builds, signs (Developer ID), notarizes and zips Pling.
# Needs a notarytool keychain profile: xcrun notarytool store-credentials <name>
set -eu
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile}"
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT"

xcodegen generate
xcodebuild -project Pling.xcodeproj -scheme Pling -configuration Release \
  -archivePath "$OUT/Pling.xcarchive" archive
cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>5SB3S8ESR3</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/Pling.xcarchive" -exportPath "$OUT" -exportOptionsPlist "$OUT/export.plist"

ditto -c -k --keepParent "$OUT/Pling.app" "$OUT/Pling-notarize.zip"
xcrun notarytool submit "$OUT/Pling-notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/Pling.app"
VERSION=$(defaults read "$PWD/$OUT/Pling.app/Contents/Info" CFBundleShortVersionString)
ditto -c -k --keepParent "$OUT/Pling.app" "$OUT/Pling-$VERSION.zip"
echo "Release: $OUT/Pling-$VERSION.zip"
