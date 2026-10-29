#!/bin/bash
# Builds and runs Support/Tests: machen's offline editing against a fake account, with the
# app's own sources compiled in (-D TESTING keeps the Keychain, cache and Google out of it).
set -euo pipefail
cd "$(dirname "$0")/.."

swift Support/make-layout.swift Support/layout.json Sources/machen/Layout.generated.swift

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The tool has its own entry point, so drop the app's @main
sed 's/^@main$//' Sources/machen/App.swift > "$TMP/App.swift"
swiftc -swift-version 5 -D TESTING -o "$TMP/tests" Support/Tests/main.swift "$TMP/App.swift" \
    $(ls Sources/machen/*.swift | grep -v '/App.swift$')
"$TMP/tests"
