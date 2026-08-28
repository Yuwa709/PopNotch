#!/bin/bash
# Build a distributable PopNotch DMG: archive, export the app, ad-hoc sign,
# verify, package. Output lands in dist/.
#
# Signing is AD-HOC by decision (PROJECT-CONTEXT.md, Distribution): Apple
# Silicon requires some signature to run at all, a Development certificate
# fails confusingly on other people's machines, and there is no Developer ID
# yet. Users hit the Gatekeeper "Open Anyway" flow documented in README.md.
#
# Usage: scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHIVE=build/PopNotch.xcarchive
DIST=dist

echo "==> Archiving (Release)"
xcodebuild -scheme PopNotch -configuration Release archive \
    -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' \
    | grep -E "error:|warning:|ARCHIVE (SUCCEEDED|FAILED)" || true

APP="$ARCHIVE/Products/Applications/PopNotch.app"
if [[ ! -d "$APP" ]]; then
    echo "!! Archive did not produce $APP"; exit 1
fi

# Export = copy out of the archive. xcodebuild -exportArchive is deliberately
# not used: every export method it offers assumes a real signing identity,
# and ad-hoc is the decision. The archive's app is complete as-is.
VERSION=$(defaults read "$(pwd)/$APP/Contents/Info" CFBundleShortVersionString)
echo "==> Exporting PopNotch $VERSION"
rm -rf "$DIST" && mkdir -p "$DIST/staging"
ditto "$APP" "$DIST/staging/PopNotch.app"

echo "==> Ad-hoc signing"
codesign --force --sign - --options runtime "$DIST/staging/PopNotch.app"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$DIST/staging/PopNotch.app"

# TODO(notarization): enable once there is a Developer ID ($99/y account).
# Revisit trigger is recorded in PROJECT-CONTEXT.md's open questions.
#
# echo "==> Notarizing"
# codesign --force --sign "Developer ID Application: TEAM" \
#     --options runtime --timestamp "$DIST/staging/PopNotch.app"
# ditto -c -k --keepParent "$DIST/staging/PopNotch.app" "$DIST/PopNotch.zip"
# xcrun notarytool submit "$DIST/PopNotch.zip" \
#     --keychain-profile "popnotch-notary" --wait
# xcrun stapler staple "$DIST/staging/PopNotch.app"

echo "==> Building DMG"
ln -s /Applications "$DIST/staging/Applications"
hdiutil create -volname "PopNotch $VERSION" -srcfolder "$DIST/staging" \
    -ov -format UDZO "$DIST/PopNotch-$VERSION.dmg" >/dev/null
rm -rf "$DIST/staging"

echo
echo "Done: $DIST/PopNotch-$VERSION.dmg"
echo "Remember: un-notarized. Downloaders need the README's Gatekeeper steps."
