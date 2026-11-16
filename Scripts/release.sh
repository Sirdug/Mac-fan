#!/bin/bash
# Publishes a new version of Mac Fan that installed copies update themselves to.
#
#   Scripts/release.sh 1.1.0 "What changed in this version"
#
# It bumps the version, builds the app (with the fan helper inside), zips it,
# signs the zip with your update key and uploads the zip and update.json to a
# GitHub release. Installed copies read update.json from the newest release, so
# they pick it up within a few hours, or at once from Check Now in the panel.
# If the fan helper changed, they ask for the admin password once to update it.
#
# Settings live in Scripts/release.env (see Scripts/release.env.example):
#   GITHUB_REPO        owner/name of a public repository that holds the releases
#                      (default Sirdug/Mac-fan)
#   FEED_URL           where update.json will be served, if not on GitHub
#   DOWNLOAD_BASE_URL  where the zip will be served, if not on GitHub
#   SIGN_IDENTITY      a code signing certificate, instead of ad hoc signing
#   UPDATE_KEY_FILE    the update signing key (default ~/.config/mac-fan/update-key)
#
# PUBLISH=0 stops after writing the files to build/release, to upload them yourself.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -f Scripts/release.env ]; then
    set -a
    source Scripts/release.env
    set +a
fi

VERSION="${1:-}"
NOTES="${2:-}"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "usage: Scripts/release.sh <version> [notes]   e.g. Scripts/release.sh 1.1.0 \"Quieter curves\"" >&2
    exit 1
fi

PUBLISH="${PUBLISH:-1}"
GITHUB_REPO="${GITHUB_REPO:-Sirdug/Mac-fan}"
if [ -n "$GITHUB_REPO" ]; then
    FEED_URL="${FEED_URL:-https://github.com/$GITHUB_REPO/releases/latest/download/update.json}"
    DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-https://github.com/$GITHUB_REPO/releases/download/v$VERSION}"
fi
if [ -z "${FEED_URL:-}" ] || [ -z "${DOWNLOAD_BASE_URL:-}" ]; then
    echo "Set GITHUB_REPO (or FEED_URL and DOWNLOAD_BASE_URL) in Scripts/release.env first." >&2
    exit 1
fi
if [ "$PUBLISH" = 1 ]; then
    gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first." >&2; exit 1; }
    if gh release view "v$VERSION" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
        echo "Release v$VERSION already exists. Pick a higher version." >&2
        exit 1
    fi
fi

PLIST=Resources/Info.plist
plist() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
plist_set() { plist "Set :$1 $2" 2>/dev/null || plist "Add :$1 string $2"; }

# The key that proves an update came from you. Made once; installed copies trust only it.
KEY_FILE="${UPDATE_KEY_FILE:-$HOME/.config/mac-fan/update-key}"
if [ ! -f "$KEY_FILE" ]; then
    if plist "Print :UpdatePublicKey" >/dev/null 2>&1; then
        echo "The update key $KEY_FILE is missing, but the app already expects one." >&2
        echo "Restore it from your backup. A new key can't update copies people already have." >&2
        exit 1
    fi
    swift Scripts/update-tool.swift generate "$KEY_FILE" >/dev/null
    echo "Created your update signing key at $KEY_FILE"
    echo "Back it up somewhere safe and keep it private: without it you can't publish updates."
fi
PUBLIC_KEY="$(swift Scripts/update-tool.swift public "$KEY_FILE")"
EXISTING_KEY="$(plist "Print :UpdatePublicKey" 2>/dev/null || true)"
if [ -n "$EXISTING_KEY" ] && [ "$EXISTING_KEY" != "$PUBLIC_KEY" ]; then
    echo "$KEY_FILE doesn't match the key in $PLIST, so installed copies would reject this update." >&2
    exit 1
fi

BUILD=$(( $(plist "Print :CFBundleVersion") + 1 ))
plist_set CFBundleShortVersionString "$VERSION"
plist_set CFBundleVersion "$BUILD"
plist_set UpdatePublicKey "$PUBLIC_KEY"
plist_set UpdateFeedURL "$FEED_URL"

CONFIG=release Scripts/build-app.sh

OUT=build/release
ZIP="MacFan-$VERSION.zip"
rm -rf "$OUT"
mkdir -p "$OUT"
ditto -c -k --keepParent "build/Mac Fan.app" "$OUT/$ZIP"
swift Scripts/update-tool.swift manifest "$KEY_FILE" "$OUT/$ZIP" "$VERSION" "$BUILD" \
    "$DOWNLOAD_BASE_URL/$ZIP" "$(plist "Print :LSMinimumSystemVersion")" "$NOTES" > "$OUT/update.json"

echo "Version $VERSION (build $BUILD) is in $OUT"
if [ "$PUBLISH" != 1 ]; then
    echo "Not published. Upload $ZIP to $DOWNLOAD_BASE_URL/ and update.json to $FEED_URL"
    exit 0
fi

gh release create "v$VERSION" "$OUT/$ZIP" "$OUT/update.json" \
    --repo "$GITHUB_REPO" --title "Mac Fan $VERSION" --notes "${NOTES:-Version $VERSION}" --latest
echo "Published. Installed copies will update to $VERSION on their own."
echo "New people can download https://github.com/$GITHUB_REPO/releases/latest/download/$ZIP"
