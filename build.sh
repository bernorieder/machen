#!/bin/bash
# Builds machen.app into ./build
#
# Google sign-in: copy Support/Config.example.plist to Support/Config.local.plist (gitignored)
# and fill in your "Desktop app" OAuth client to build it into the app. Without it, users
# enter their own client on first launch.
#
# Signing: uses the first "Developer ID Application" identity in your keychain (hardened
# runtime, ready for notarization), or ad-hoc signing if there is none.
# Override with SIGN_IDENTITY="..." ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/machen.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/machen "$APP/Contents/MacOS/machen"
cp Support/Info.plist "$APP/Contents/Info.plist"

CONFIG=Support/Config.local.plist
if [[ -f "$CONFIG" ]]; then
    for key in GoogleClientID GoogleClientSecret; do
        if value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$CONFIG" 2>/dev/null) && [[ -n "$value" ]]; then
            /usr/libexec/PlistBuddy -c "Add :$key string $value" "$APP/Contents/Info.plist"
        fi
    done
    echo "Google client: built in from $CONFIG"
else
    echo "Google client: none built in ($CONFIG not found)"
fi

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc (no Developer ID identity found)"
fi

echo "Built $APP"
