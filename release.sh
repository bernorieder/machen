#!/bin/bash
# Builds, signs and notarizes machen into build/machen-<version>.dmg for distribution.
#
# One-time setup: save your notarization credentials in the keychain as "machen-notary":
#   xcrun notarytool store-credentials machen-notary --apple-id <your Apple ID> --team-id LA5LV6543Z
# It asks for an app-specific password (create one at account.apple.com → Sign-In and Security).
# Use another profile name with NOTARY_PROFILE=... ./release.sh
set -euo pipefail
cd "$(dirname "$0")"
PROFILE=${NOTARY_PROFILE:-machen-notary}

if [[ ! -f Support/Config.local.plist ]]; then
    echo "Support/Config.local.plist is missing: a release needs a built-in Google client." >&2
    exit 1
fi

./build.sh

IDENTITY=$(codesign -dv --verbose=2 build/machen.app 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)/\1/p' | head -1)
if [[ -z "$IDENTITY" ]]; then
    echo "build/machen.app isn't signed with a Developer ID, so it can't be notarized." >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
DMG=build/machen-$VERSION.dmg
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/machen.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname machen -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "Submitting $DMG for notarization (usually a few minutes)…"
OUTPUT=$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1) || true
echo "$OUTPUT"
if ! grep -q "status: Accepted" <<<"$OUTPUT"; then
    echo "Notarization failed. For details: xcrun notarytool log <submission id> --keychain-profile $PROFILE" >&2
    exit 1
fi

xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "Release ready: $DMG"
