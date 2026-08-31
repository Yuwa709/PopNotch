#!/bin/bash
# Build, ad-hoc sign, package, and sign an appcast for one PopNotch release.
#
# Produces three artifacts in dist/ and uploads NOTHING:
#
#   PopNotch-<version>.dmg   first-time installs, with an /Applications symlink
#   PopNotch-<version>.zip   Sparkle updates
#   appcast.xml              the signed feed Sparkle reads
#
# Both packages come from ONE signed .app. Signing twice would produce two
# bundles with different signatures for the same release, and whichever one a
# user did not install would fail Sparkle's validation later.
#
# The DMG still matters even with Sparkle wired: Sparkle only updates an app
# somebody already has. First installs come through the DMG and still hit
# Gatekeeper, which is why README documents `xattr -cr`.
#
# Publishing is a deliberate, separate act: upload both packages to a GitHub
# Release tagged v<version>, then commit appcast.xml to the repo root on main,
# which is where SUFeedURL points.
#
# Usage: scripts/release.sh 1.1
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "!! Usage: scripts/release.sh <version>   (e.g. 1.1)" >&2
    exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    # Sparkle compares versions itself, but a stray "v" or a suffix makes
    # CFBundleVersion sort unpredictably against previously shipped builds.
    echo "!! Version must be digits and dots only, no leading v: got '$VERSION'" >&2
    exit 1
fi

REPO="Yuwa709/PopNotch"
DIST="dist"
ZIP="$DIST/PopNotch-$VERSION.zip"
DMG="$DIST/PopNotch-$VERSION.dmg"
STAGING="$DIST/staging"
ENTITLEMENTS="PopNotch/PopNotch.entitlements"

# --- generate_appcast, located dynamically -----------------------------------
# It ships inside the resolved SPM artifact, whose path contains a DerivedData
# hash that changes and which a clean build deletes. Never hardcode it.
echo "==> Locating Sparkle tools"
GENERATE_APPCAST=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path "*/artifacts/sparkle/Sparkle/bin/generate_appcast" -type f 2>/dev/null | head -1)
if [[ -z "$GENERATE_APPCAST" ]]; then
    cat >&2 <<'MSG'
!! Could not find Sparkle's generate_appcast.

   It lives in the resolved Swift Package artifacts under DerivedData, which a
   clean build removes. To restore it, open PopNotch.xcodeproj and either:
       File > Packages > Resolve Package Versions
   or build the app once. Then re-run this script.
MSG
    exit 1
fi
echo "    $GENERATE_APPCAST"

# --- build -------------------------------------------------------------------
# CFBundleShortVersionString and CFBundleVersion come from these two build
# settings (GENERATE_INFOPLIST_FILE synthesizes the plist from them); neither
# lives in PopNotch/Info.plist, which carries only the custom Sparkle keys.
# Overriding them here is what makes CFBundleVersion match sparkle:version in
# the appcast, since generate_appcast reads CFBundleVersion out of the app.
#
# CODE_SIGN_IDENTITY="-" makes the build itself ad-hoc. Without it, Automatic
# signing picks the Apple Development certificate, which is a personal
# credential that must never ship. The explicit re-sign below is belt to this
# braces: it guarantees the identity regardless of project settings.
#
# No `clean`: it is not needed for correctness and risks removing the SPM
# artifacts that generate_appcast lives in.
echo "==> Building Release $VERSION"
xcodebuild -scheme PopNotch -configuration Release -destination 'platform=macOS' \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    DEVELOPMENT_TEAM="" \
    build | grep -E "error:|warning: (unable|failed)|BUILD (SUCCEEDED|FAILED)" || true

BUILT_DIR=$(xcodebuild -scheme PopNotch -configuration Release -destination 'platform=macOS' \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR/ { print $2; exit }')
APP="$BUILT_DIR/PopNotch.app"
if [[ ! -d "$APP" ]]; then
    echo "!! No built app at $APP" >&2
    exit 1
fi
echo "    $APP"

# --- ad-hoc sign, inside out -------------------------------------------------
# Order matters: nested code must be signed before its container, or sealing
# the container captures a hash that the later nested signature invalidates.
#
# --preserve-metadata=entitlements on the Sparkle components: Autoupdate ships
# com.apple.application-identifier, and re-signing without it would silently
# drop it. The app instead gets its entitlements file explicitly, because
# com.apple.security.automation.apple-events is load-bearing — Hardened Runtime
# refuses Apple Events without it and the media feature dies with a silent
# -1743, no prompt and no Automation pane entry.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
echo "==> Ad-hoc signing"
for COMPONENT in \
    "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
    "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
    "$FRAMEWORK/Versions/B/Updater.app" \
    "$FRAMEWORK/Versions/B/Autoupdate"
do
    [[ -e "$COMPONENT" ]] || { echo "!! Missing $COMPONENT" >&2; exit 1; }
    codesign -f -s - -o runtime --timestamp=none \
        --preserve-metadata=entitlements "$COMPONENT"
    echo "    signed $(basename "$COMPONENT")"
done
codesign -f -s - -o runtime --timestamp=none "$FRAMEWORK"
echo "    signed Sparkle.framework"
codesign -f -s - -o runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" "$APP"
echo "    signed PopNotch.app"

# --- verify ------------------------------------------------------------------
# This is the gate. Sparkle rejects an update whose Apple code signature is
# broken (updateIsCodeSigned && !valid), so a bad signature here becomes a
# silent refusal on every user's machine. Catching it is the point of this step.
echo "==> Verifying signature"
if ! codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'; then
    echo "!! codesign --verify --deep --strict FAILED. Refusing to package." >&2
    exit 1
fi

if ! codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "apple-events"; then
    echo "!! The apple-events entitlement is missing after signing." >&2
    echo "   Media control would fail silently with -1743. Refusing to package." >&2
    exit 1
fi
echo "    apple-events entitlement present"

BUILT_PLIST="$APP/Contents/Info.plist"
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$BUILT_PLIST")
BUILT_SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT_PLIST")
if [[ "$BUILT_VERSION" != "$VERSION" || "$BUILT_SHORT" != "$VERSION" ]]; then
    echo "!! Version mismatch in the built bundle." >&2
    echo "   CFBundleVersion=$BUILT_VERSION CFBundleShortVersionString=$BUILT_SHORT, wanted $VERSION" >&2
    exit 1
fi
echo "    CFBundleVersion=$BUILT_VERSION CFBundleShortVersionString=$BUILT_SHORT"

# A PLACEHOLDER key ships an app that can never accept an update, and the
# failure only shows up on a user's machine.
PUBKEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$BUILT_PLIST" 2>/dev/null || echo "")
if [[ -z "$PUBKEY" || "$PUBKEY" == "PLACEHOLDER" ]]; then
    echo "!! SUPublicEDKey is missing or still PLACEHOLDER. Refusing to package." >&2
    exit 1
fi
echo "    SUPublicEDKey present"

# --- package -----------------------------------------------------------------
# ditto, not zip: a plain zip does not preserve the extended attributes and
# symlink structure a signed bundle depends on, and breaks the signature.
echo "==> Packaging"
rm -rf "$DIST"
mkdir -p "$STAGING"

# Both packages are cut from $APP, which was signed exactly once above.
# ditto preserves the signature; nothing here re-signs.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
LENGTH=$(stat -f%z "$ZIP")
echo "    $ZIP ($LENGTH bytes)"

ditto "$APP" "$STAGING/PopNotch.app"
# The drag-to-install target users expect in a DMG window.
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "PopNotch $VERSION" -srcfolder "$STAGING" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
echo "    $DMG ($(stat -f%z "$DMG") bytes)"

# TODO(notarization): enable once there is a Developer ID ($99/y account).
# Revisit trigger is recorded in PROJECT-CONTEXT.md's open questions.
# Note this replaces the ad-hoc signing above rather than adding to it, and
# must happen BEFORE packaging so both artifacts carry the stapled ticket.
#
# codesign --force --sign "Developer ID Application: TEAM" \
#     --options runtime --timestamp "$APP"
# ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
# xcrun notarytool submit "$DIST/notarize.zip" \
#     --keychain-profile "popnotch-notary" --wait
# xcrun stapler staple "$APP"

# Prove the signature survived each round trip, rather than assuming it. A
# signature that breaks in packaging is invisible until a user's machine
# refuses the app or Sparkle refuses the update.
VERIFY_DIR=$(mktemp -d)
MOUNT_DIR=$(mktemp -d)
cleanup() {
    hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
    rm -rf "$VERIFY_DIR" "$MOUNT_DIR"
}
trap cleanup EXIT

ditto -x -k "$ZIP" "$VERIFY_DIR"
if ! codesign --verify --deep --strict "$VERIFY_DIR/PopNotch.app" 2>&1 | sed 's/^/    /'; then
    echo "!! Signature broke during zip packaging. Refusing to publish." >&2
    exit 1
fi
echo "    signature intact after unzip"

hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT_DIR"
if ! codesign --verify --deep --strict "$MOUNT_DIR/PopNotch.app" 2>&1 | sed 's/^/    /'; then
    echo "!! Signature broke during DMG packaging. Refusing to publish." >&2
    exit 1
fi
echo "    signature intact inside DMG"
hdiutil detach "$MOUNT_DIR" -quiet

# --- appcast -----------------------------------------------------------------
# Signs the zip with the private EdDSA key from the login keychain and writes
# appcast.xml. The download prefix must match where the asset will actually be
# uploaded, or Sparkle downloads a 404.
# generate_appcast treats EVERY archive in the directory it is given as a
# candidate update, and refuses two that carry the same bundle version — so
# pointing it at dist/ once the DMG exists fails with "Duplicate updates are
# not supported". It gets its own directory holding only the zip, hardlinked
# so nothing is copied. Sparkle updates ship as the zip; the DMG is for humans
# and must stay out of the feed.
echo "==> Generating appcast"
APPCAST_SRC="$DIST/appcast-src"
mkdir -p "$APPCAST_SRC"
ln "$ZIP" "$APPCAST_SRC/$(basename "$ZIP")"
"$GENERATE_APPCAST" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --link "https://github.com/$REPO" \
    "$APPCAST_SRC"

APPCAST="$DIST/appcast.xml"
mv "$APPCAST_SRC/appcast.xml" "$APPCAST"
rm -rf "$APPCAST_SRC"
[[ -f "$APPCAST" ]] || { echo "!! generate_appcast produced no appcast.xml" >&2; exit 1; }

if ! grep -q 'sparkle:edSignature' "$APPCAST"; then
    echo "!! appcast.xml has no EdDSA signature. Sparkle would reject this update." >&2
    exit 1
fi

echo
echo "=============================================================="
echo "  dmg      $DMG        (first installs)"
echo "  zip      $ZIP   ($LENGTH bytes, Sparkle updates)"
echo "  appcast  $APPCAST"
echo "=============================================================="
echo
echo "Nothing has been uploaded. To publish:"
echo "  1. Create a GitHub Release tagged v$VERSION on $REPO"
echo "  2. Attach BOTH $DMG and $ZIP as release assets"
echo "     (the appcast's enclosure URL points at the zip; the DMG is for humans)"
echo "  3. Copy $APPCAST to the repo root and commit it to main"
echo "     (SUFeedURL reads it from raw.githubusercontent.com/$REPO/main/appcast.xml)"
