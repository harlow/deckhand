# Standalone macOS release

Implemented October 11, 2026. Target: Apple Silicon, macOS 26 (Tahoe) or later.
The owner is happy to support newer Macs; Intel and older OS support are outside this release.

## What ships

- `Deckhand.app`, including the `deckhand` helper, compiled analysis model, icon and licenses.
- A drag-to-Applications disk image with a Read Me and Applications shortcut.
- Matching Deckhand source archive, including vendored analysis code and build scripts.
- SHA-256 checksums for the disk image and source archive.

Users install no Homebrew packages, Python, FFmpeg, Xcode or command-line tools.
Apple's media, Core ML and crypto frameworks are supplied by macOS. Existing folder,
Music and Rekordbox imports, local playlists, analysis and USB sync remain unchanged.

## Dependency and resource changes

The old executable linked Homebrew SQLCipher, which also linked Homebrew OpenSSL.
`Scripts/build-sqlcipher.sh` now downloads checksum-pinned SQLCipher Community 4.19.0,
compiles a static arm64 library using Apple's CommonCrypto, and supplies its pkg-config
metadata to SwiftPM. The app build uses `.build-standalone`, avoiding products previously
linked against Homebrew. Both app and helper now link only macOS system libraries.

The compiled analysis model resolves from `Contents/Resources/Deckhand_Analysis.bundle`
for both packaged executables. A packaged app never falls back to the developer's checkout.
Bare development executables still use SwiftPM's resource lookup.

Direct `swift build` of the development CLI may still use a system SQLCipher installation;
`Scripts/build-app.sh` and `Scripts/package-release.sh` produce the self-contained app.
Build machines need the macOS 26 SDK, Python 3, pkg-config and standard compiler tools.

## Build and verify

```sh
Scripts/build-app.sh release
python3 Scripts/verify-app.py build/Deckhand.app
Scripts/package-release.sh
```

Artifacts appear in `build/release`. Bundle verification checks arm64, minimum OS metadata,
external dynamic dependencies, developer library search paths, model and licenses, and
code signatures. The shipped helper's `debug runtime-check` opens SQLCipher and runs an
actual Core ML prediction without reading the user's library.

## Signing and public distribution

Without a certificate these commands produce an ad-hoc signed **local preview**, clearly
marked inside the disk image. No Developer ID signing identity is installed on this machine.
The artifact is not ready for a public download and has not been notarized.

When a Developer ID Application certificate and notarytool keychain profile are available:

```sh
DECKHAND_SIGN_IDENTITY='Developer ID Application: NAME (TEAMID)' \
DECKHAND_NOTARY_PROFILE='PROFILE_NAME' Scripts/package-release.sh --public
```

The helper is signed before the app. Certificate builds enable hardened runtime, timestamp
signatures, and Apple Events automation entitlement. Packaging signs the DMG, submits it
to Apple's notary service, and staples/validates the ticket. The bundle identifier remains
`rocks.deckhand.app`. A stable signing certificate also avoids ad-hoc rebuilds changing
the app identity used for privacy permissions.

Ship the matching source archive alongside each binary release, with GPL and third-party
license texts included in the app. App Store distribution is deferred; this build does
not introduce App Sandbox restrictions.

Versioning and publishing are defined in [the release runbook](../releases.md). `release.json`
supplies app metadata and `vVERSION` tags; GitHub Actions tests, builds and publishes verified
tagged distributions. `Deckhand-arm64.dmg` is the fixed download filename. Local previews
and public releases have separate validation requirements.

## Validation performed

- **252 tests in 48 suites passed** against the statically linked SQLCipher build. These
  cover analysis, encrypted OneLibrary writes, incremental sync, source imports, local
  playlists and USB selection behavior.
- Copied the app outside the checkout to a path with spaces. Its packaged helper loaded
  the model, ran prediction, and initialized SQLCipher with OS sandbox rules denying
  access to `/opt/homebrew`, `/usr/local` and this development checkout.
- Removed the model from a disposable copy. Runtime verification failed explicitly,
  despite the original development resources still existing: no hidden resource fallback.
- Injected a Homebrew search path into another disposable copy. Bundle verification
  rejected it before running the helper.
- Opened an isolated release app with a fresh local library and cache; imported two WAV
  files, analyzed both using the bundled helper, previewed audio, created a playlist,
  staged it, and synced to an owned 256 MB FAT disk image.
- The USB contained both tracks with matching SHA-256 hashes, six ANLZ files, an encrypted
  export database, and one playlist with both content IDs. Bundled CLI validation reported
  no problems. Sync disabled after completion.
- Restarted the app: both tracks, waveforms, BPM/key results, playlist, checked USB selection
  and clean sync state persisted. Needs Analysis remained zero.
- Mounted the generated DMG read-only, verified its Applications shortcut and local-preview
  status, copied the app to another directory, and repeated bundle/runtime checks with
  Homebrew and checkout access denied. Verified required source files inside the archive.
- Reopened the regular app with the packaged build: 2,175 visible tracks, Needs Analysis
  zero, Mixed in Bongoloco 51 tracks, and the user's connected DJTEST up to date. No real
  drive sync or user-library reset was performed during release QA.

Evidence: [completed sync](../images/library-evidence/67-standalone-release-sync.png),
[restart](../images/library-evidence/68-standalone-release-restart.png),
[regular library](../images/library-evidence/69-standalone-regular-app.png), and logs in
`validation-evidence/standalone-*`.

These are tests on the development Mac with dependencies denied and a disposable drive,
not a second clean Mac or physical DJ-player hardware. Before a public launch, validate
the signed/notarized download on a clean supported Mac, including first-use Music and
removable-volume permissions. This does not require changing users' library data.
