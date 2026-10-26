#!/bin/bash
# Renders the README screenshots into docs/screenshots from the app's real views with sample data,
# so no personal calendar or task data ends up in the repository.
set -euo pipefail
cd "$(dirname "$0")/.."

swift Support/make-layout.swift Support/layout.json Sources/machen/Layout.generated.swift

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The tool has its own entry point, so drop the app's @main
sed 's/^@main$//' Sources/machen/App.swift > "$TMP/App.swift"
# Embedding Info.plist lets Settings show the real version number. It gets its own bundle ID so
# the tool keeps its settings apart from the real app's.
cp Support/Info.plist "$TMP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier io.github.bernorieder.machen.screenshots" "$TMP/Info.plist"
swiftc -swift-version 5 -D SCREENSHOTS -O -o "$TMP/screenshots" Support/Screenshots/main.swift "$TMP/App.swift" \
    $(ls Sources/machen/*.swift | grep -v '/App.swift$') \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$TMP/Info.plist"

mkdir -p docs/screenshots
"$TMP/screenshots" docs/screenshots Support/AppIcon.icns

# The tool's own settings are throwaway
defaults delete io.github.bernorieder.machen.screenshots 2>/dev/null || true
rm -f ~/Library/Preferences/io.github.bernorieder.machen.screenshots.plist
