#!/bin/zsh
# Builds a self-contained Apple Silicon app for macOS 26+. Usage: [debug|release]
set -euo pipefail
cd ${0:A:h}/..
CONFIG=${1:-release}
[[ "$CONFIG" == debug || "$CONFIG" == release ]] || { print -u2 "Expected debug or release"; exit 1; }
# A separate scratch directory prevents reusing products linked to a developer's Homebrew library.
SCRATCH=.build-standalone
Scripts/build-sqlcipher.sh
export PKG_CONFIG_PATH="$PWD/.build-release-deps/prefix/lib/pkgconfig"
swift build -c $CONFIG --scratch-path $SCRATCH --product DeckhandApp
swift build -c $CONFIG --scratch-path $SCRATCH --product deckhand
BIN=$SCRATCH/$CONFIG
APP=${DECKHAND_APP_PATH:-build/Deckhand.app}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp $BIN/DeckhandApp $BIN/deckhand "$APP/Contents/MacOS/"
cp -R $BIN/Deckhand_Analysis.bundle "$APP/Contents/Resources/"
LICENSES="$APP/Contents/Resources/Licenses"
mkdir -p "$LICENSES"
cp LICENSE THIRD_PARTY_NOTICES "$LICENSES/"
cp .build-release-deps/sqlcipher-4.19.0/LICENSE.md "$LICENSES/SQLCipher.txt"
cp Sources/CKeyFinder/LICENSE "$LICENSES/libKeyFinder.txt"
cp Sources/CQMDSP/COPYING "$LICENSES/qm-dsp.txt"
cp Sources/CQMDSP/qm-dsp/ext/kissfft/COPYING "$LICENSES/KISS-FFT.txt"
cp "$SCRATCH/checkouts/swift-argument-parser/LICENSE.txt" "$LICENSES/Swift-Argument-Parser.txt"
ICONSET=$SCRATCH/AppIcon.iconset
rm -rf $ICONSET
swift Scripts/make-icon.swift $ICONSET
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Deckhand</string>
    <key>CFBundleDisplayName</key><string>Deckhand</string>
    <key>CFBundleIdentifier</key><string>rocks.deckhand.app</string>
    <key>CFBundleExecutable</key><string>DeckhandApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleMusicUsageDescription</key><string>Deckhand reads your playlists and tracks to show their key, tempo and energy and to sync them to DJ drives.</string>
    <key>NSAppleEventsUsageDescription</key><string>Deckhand asks Music to create playlists and add tracks to them.</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>rocks.deckhand.playlist</string>
            <key>UTTypeDescription</key><string>Deckhand Playlist</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key><string>rocks.deckhand.tracks</string>
            <key>UTTypeDescription</key><string>Deckhand Tracks</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
    </array>
</dict>
</plist>
EOF
python3 Scripts/release.py stamp-plist "$APP/Contents/Info.plist"
# DECKHAND_SIGN_IDENTITY can name a stable signing certificate when one is installed.
# Without it the fallback is ad-hoc signing. macOS remembers privacy permissions (Media & Apple Music, Automation) for an ad-hoc app by
# its exact build hash, so each rebuild asks again; until "Allow" is clicked (the prompt can sit hidden
# behind other windows) reading the library waits. A fixed designated requirement doesn't help ad-hoc
# builds; a stable signing certificate would.
IDENTITY=${DECKHAND_SIGN_IDENTITY:--}
SIGN_OPTIONS=()
if [[ "$IDENTITY" != - ]]; then SIGN_OPTIONS=(--options runtime --timestamp --entitlements Scripts/Deckhand.entitlements); fi
# Sign nested executables first, then the outer bundle.
codesign --force --sign "$IDENTITY" "${SIGN_OPTIONS[@]}" "$APP/Contents/MacOS/deckhand"
codesign --force --sign "$IDENTITY" "${SIGN_OPTIONS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
python3 Scripts/verify-app.py "$APP"
echo "Built $APP (open it with: open $APP)"
