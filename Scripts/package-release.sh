#!/bin/zsh
# Build a local preview, or require a signed/notarized tagged distribution with --public.
set -euo pipefail
cd ${0:A:h}/..
MODE=${1:-preview}
[[ "$MODE" == preview || "$MODE" == --public ]] || { print -u2 "Usage: Scripts/package-release.sh [--public]"; exit 1; }
PUBLIC=()
[[ "$MODE" == --public ]] && PUBLIC=(--public)
python3 Scripts/release.py preflight "${PUBLIC[@]}"
VERSION=$(python3 Scripts/release.py value version)
TAG=$(python3 Scripts/release.py value tag)
if [[ "$MODE" == --public ]]; then python3 Scripts/release.py check --tag "$TAG" --require-clean; fi
OUT="$PWD/build/release"
APP="$OUT/Deckhand.app"
mkdir -p "$OUT"
DECKHAND_APP_PATH="$APP" Scripts/build-app.sh release
STAGE=$(mktemp -d /tmp/deckhand-dmg.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
# Staple the app before creating the DMG so the installed copy has an offline ticket.
notarize() {
    local target="$1"
    local -a keychain_options
    keychain_options=()
    [[ -n "${DECKHAND_NOTARY_KEYCHAIN:-}" ]] && keychain_options=(--keychain "$DECKHAND_NOTARY_KEYCHAIN")
    xcrun notarytool submit "$target" --keychain-profile "$DECKHAND_NOTARY_PROFILE" "${keychain_options[@]}" --wait --output-format json > "$OUT/notary-result.json"
    python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r.get("status")=="Accepted" else "Apple notarization was not accepted; inspect notary-result.json")' "$OUT/notary-result.json"
}
if [[ "$MODE" == --public ]]; then
    ditto -c -k --keepParent "$APP" "$STAGE/Deckhand.zip"
    notarize "$STAGE/Deckhand.zip"
    rm "$STAGE/Deckhand.zip"
    xcrun stapler staple "$APP"
    python3 Scripts/verify-app.py "$APP" --public
fi
ditto "$APP" "$STAGE/Deckhand.app"
ln -s /Applications "$STAGE/Applications"
cp docs/release-readme.txt "$STAGE/Read Me.txt"
if [[ "$MODE" != --public ]]; then
    print "Local preview build. This package has not been notarized. Public distribution requires Developer ID signing and Apple notarization." > "$STAGE/Release Status.txt"
fi
DMG="$OUT/Deckhand-arm64.dmg"
SOURCE="$OUT/Deckhand-$VERSION-source.tar.gz"
hdiutil create -volname Deckhand -srcfolder "$STAGE" -ov -format UDZO "$DMG"
if [[ "$MODE" == --public ]]; then
    codesign --force --sign "$DECKHAND_SIGN_IDENTITY" --timestamp "$DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    # Public source must be exactly the committed/tagged tree, never working-directory extras.
    git archive --format=tar HEAD | gzip -n > "$SOURCE"
else
    git ls-files --cached --others --exclude-standard -z | tar --null -T - -czf "$SOURCE"
    print "Local preview only: not for public distribution."
fi
python3 Scripts/release.py manifest --artifacts "$OUT" "${PUBLIC[@]}"
python3 Scripts/release.py validate-artifacts --artifacts "$OUT" "${PUBLIC[@]}"
print "Release artifacts: $OUT"
