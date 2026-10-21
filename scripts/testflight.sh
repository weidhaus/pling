#!/usr/bin/env bash
#
# Archive Pling for iOS and upload it to App Store Connect / TestFlight.
#
#   ASC_ISSUER_ID=<uuid> scripts/testflight.sh
#
# Uses an App Store Connect API key: ASC_KEY_ID (default RP4AXPC5H3), ASC_KEY_PATH
# (default ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8) and ASC_ISSUER_ID.
# The build number is a timestamp, so every upload is unique without bumping anything.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
ASC_KEY_ID="${ASC_KEY_ID:-RP4AXPC5H3}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
BUILD="$(date -u +%Y%m%d%H%M)"

(cd PlingCore && swift test -q)
(cd relay && go test ./...)
xcodegen generate -q
rm -rf build/PlingiOS.xcarchive build/export-ios
xcodebuild -project Pling.xcodeproj -scheme PlingiOS -configuration Release -destination 'generic/platform=iOS' \
    -archivePath build/PlingiOS.xcarchive CURRENT_PROJECT_VERSION="$BUILD" "${AUTH[@]}" -quiet archive

mkdir -p build/export-ios
cat > build/export-ios/ExportOptions.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>5SB3S8ESR3</string>
    <key>signingStyle</key><string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath build/PlingiOS.xcarchive -exportPath build/export-ios \
    -exportOptionsPlist build/export-ios/ExportOptions.plist "${AUTH[@]}"
echo "Uploaded build $BUILD. It appears in TestFlight once Apple finishes processing (usually 5–15 min)."
