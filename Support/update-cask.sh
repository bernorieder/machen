#!/bin/bash
# Points the Homebrew cask at the release published last: sets its version and checksum in the tap
# (bernorieder/homebrew-machen, checked out next to this repository), then commits and pushes.
# Run it after publishing release v<version> with machen-<version>.dmg on GitHub.
# Use another checkout of the tap with TAP_DIR=... Support/update-cask.sh
set -euo pipefail
cd "$(dirname "$0")/.."
TAP=${TAP_DIR:-../homebrew-machen}
CASK=$TAP/Casks/machen.rb

if [[ ! -f "$CASK" ]]; then
    echo "$CASK is missing: clone bernorieder/homebrew-machen next to this repository." >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
# The checksum GitHub reports for the published file, so the cask matches what people download
DIGEST=$(gh release view "v$VERSION" --json assets \
    --jq ".assets[] | select(.name == \"machen-$VERSION.dmg\") | .digest" 2>/dev/null || true)
if [[ "$DIGEST" != sha256:* ]]; then
    echo "Release v$VERSION with machen-$VERSION.dmg isn't on GitHub yet; publish it first." >&2
    exit 1
fi
SHA=${DIGEST#sha256:}

sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
if git -C "$TAP" diff --quiet -- Casks/machen.rb; then
    echo "The cask is already at machen $VERSION."
    exit 0
fi
git -C "$TAP" commit -q -m "machen $VERSION" -- Casks/machen.rb
git -C "$TAP" push -q origin main
echo "Cask updated to machen $VERSION ($SHA)"
