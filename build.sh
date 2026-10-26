#!/bin/bash
# Builds machen.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/machen.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/machen "$APP/Contents/MacOS/machen"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP"
