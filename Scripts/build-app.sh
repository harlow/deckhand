#!/bin/zsh
# Builds build/Deckhand.app: the SwiftUI app plus the deckhand CLI it runs for syncing, ad-hoc signed
# (the iTunesLibrary framework only answers signed apps). Usage: Scripts/build-app.sh [debug|release]
set -e
cd ${0:A:h}/..
CONFIG=${1:-release}
SCRATCH=.build-app
swift build -c $CONFIG --scratch-path $SCRATCH --product DeckhandApp
swift build -c $CONFIG --scratch-path $SCRATCH --product deckhand
BIN=$SCRATCH/$CONFIG
APP=build/Deckhand.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN/DeckhandApp $BIN/deckhand $APP/Contents/MacOS/
cp -R $BIN/Deckhand_Analysis.bundle $APP/Contents/Resources/
ICONSET=$SCRATCH/AppIcon.iconset
rm -rf $ICONSET
swift Scripts/make-icon.swift $ICONSET
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns
cat > $APP/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Deckhand</string>
    <key>CFBundleDisplayName</key><string>Deckhand</string>
    <key>CFBundleIdentifier</key><string>com.deckhand.app</string>
    <key>CFBundleExecutable</key><string>DeckhandApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleMusicUsageDescription</key><string>Deckhand reads your playlists and tracks to show their key, tempo and energy and to sync them to DJ drives.</string>
    <key>NSAppleEventsUsageDescription</key><string>Deckhand asks Music to create playlists and add tracks to them.</string>
</dict>
</plist>
EOF
# Ad-hoc signed. macOS remembers privacy permissions (Media & Apple Music, Automation) for an ad-hoc app by
# its exact build hash, so each rebuild asks again; until "Allow" is clicked (the prompt can sit hidden
# behind other windows) reading the library waits. A fixed designated requirement doesn't help ad-hoc
# builds; a stable signing certificate would.
codesign --force --deep --sign - $APP
echo "Built $APP (open it with: open $APP)"
