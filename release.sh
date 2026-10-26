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

CONFIG=Support/Config.local.plist
if [[ ! -f "$CONFIG" ]]; then
    echo "$CONFIG is missing: a release needs a built-in Google client." >&2
    exit 1
fi
# A copy of the example file still has its placeholders, which nobody could sign in with
CLIENT_ID=$(/usr/libexec/PlistBuddy -c "Print :GoogleClientID" "$CONFIG" 2>/dev/null || true)
if [[ -z "$CLIENT_ID" || "$CLIENT_ID" == *example* ]]; then
    echo "$CONFIG still has no real client ID; fill it in from Google Cloud Console." >&2
    exit 1
fi

RELEASE=1 ./build.sh

IDENTITY=$(codesign -dv --verbose=2 build/machen.app 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)/\1/p' | head -1)
if [[ -z "$IDENTITY" ]]; then
    echo "build/machen.app isn't signed with a Developer ID, so it can't be notarized." >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
DMG=build/machen-$VERSION.dmg
# Worked on under a temporary name, so a disk image that isn't notarized never sits under the
# final name, where it could be uploaded by mistake
WORK=build/machen-$VERSION.unnotarized.dmg
STAGE=build/dmg
trap 'rm -rf "$STAGE" "$WORK"' EXIT
rm -rf "$STAGE" "$DMG" "$WORK"
mkdir -p "$STAGE"
cp -R build/machen.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname machen -srcfolder "$STAGE" -ov -format UDZO "$WORK" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$WORK"

echo "Submitting the disk image for notarization (usually a few minutes)…"
OUTPUT=$(xcrun notarytool submit "$WORK" --keychain-profile "$PROFILE" --wait 2>&1) || true
echo "$OUTPUT"
if ! grep -q "status: Accepted" <<<"$OUTPUT"; then
    echo "Notarization failed. For details: xcrun notarytool log <submission id> --keychain-profile $PROFILE" >&2
    exit 1
fi

xcrun stapler staple "$WORK"
spctl --assess --type open --context context:primary-signature --verbose "$WORK"
mv "$WORK" "$DMG"
echo "Release ready: $DMG"
