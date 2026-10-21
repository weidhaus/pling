#!/bin/sh
# Builds, signs (Developer ID), notarizes, publishes a GitHub release with a Sparkle appcast.
#   NOTARY_PROFILE=<notarytool keychain profile> scripts/release.sh
# Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml first.
# Sparkle's EdDSA private key is read from the login Keychain (account "pling", see generate_keys).
set -eu
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile}"
REPO=weidhaus/pling
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT/updates"

xcodegen generate
xcodebuild -project Pling.xcodeproj -scheme Pling -configuration Release \
  -derivedDataPath build/dd -archivePath "$OUT/Pling.xcarchive" archive
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

ditto -c -k --keepParent "$OUT/Pling.app" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/Pling.app"

VERSION=$(defaults read "$PWD/$OUT/Pling.app/Contents/Info" CFBundleShortVersionString)
ZIP="Pling-$VERSION.zip"
ditto -c -k --keepParent "$OUT/Pling.app" "$OUT/updates/$ZIP"

SPARKLE=build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin
"$SPARKLE/generate_appcast" --account pling \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" "$OUT/updates"

cp "$OUT/updates/$ZIP" "$OUT/Pling.zip"   # stable name for the README download link
gh release create "v$VERSION" "$OUT/updates/$ZIP" "$OUT/Pling.zip" "$OUT/updates/appcast.xml" \
  --repo "$REPO" --title "Pling $VERSION" --generate-notes
echo "Published $ZIP"
