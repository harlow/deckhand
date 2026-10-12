# Cutting a Deckhand release

`release.json` is the only version source. It contains the semantic version, monotonically
increasing Apple build number, and GitHub repository. The initial version is `0.1.0-beta.1`.
Use `X.Y.Z-beta.N` for betas and `X.Y.Z` for stable releases. The app's marketing version
is numeric (`0.1.0`); its build number distinguishes beta and stable builds, and its
`DeckhandReleaseVersion` metadata preserves the complete version.

## Routine release

1. Finish and test the changes. Start with a clean checkout.
2. Write concise notes to a file outside the checkout, then prepare the new version:

   ```sh
   python3 Scripts/release.py prepare 0.1.0-beta.2 --notes-file /tmp/deckhand-notes.md
   ```

   This bumps the build number and creates `docs/releases/0.1.0-beta.2.md`. It rejects
   backwards versions, empty notes, existing versions, and uncommitted changes.
3. Review and commit those two files, merge into `main`, and pull the release commit.
   CI must pass. For the already-prepared first beta, skip the prepare step.
4. Create and push the annotated tag:

   ```sh
   python3 Scripts/release.py tag --dry-run
   python3 Scripts/release.py tag --push
   ```

   The tag is derived from `release.json`; there is no version argument to mistype.
   It is created only from a clean checkout. Tag push starts the **Release** workflow.
   The command also verifies that the release commit has been merged into `origin/main`.
5. Watch GitHub Actions. It verifies tag/version/commit consistency and credentials,
   runs release-tooling and Swift tests, builds, signs and notarizes the app and DMG,
   verifies the installer, then uploads into a draft GitHub release. It checks every
   uploaded asset's size and SHA-256 digest before publishing.

Beta releases get GitHub's prerelease flag and do not move the stable download link.
Cut one tag at a time and let its run finish before cutting another; the workflow serializes
publishing, and GitHub may replace an older pending run when multiple tags are queued.
Stable releases become latest. Published versions cannot be overwritten; fixes require
a new version. An older stable release cannot replace a newer stable download.

There is deliberately no automatic updater in this version. Users install a newer DMG
over the existing app; their library and analysis remain in Application Support.

## First unsigned beta

`v0.1.0-beta.1` was explicitly published as an **unsigned, unnotarized preview** from
commit `aed513fd6e521345eb14d6494afd05498ea08416`, after its CI passed. Its GitHub
release is marked prerelease and does not move the stable latest-download link.
The verified DMG, matching source, manifest, notes and checksums were uploaded to a
draft, checked against GitHub's SHA-256 digests and sizes, then published.

This is a deliberate exception to the notarized publishing route below. The normal
`release.py publish` command and tag workflow still require Apple signing. Another
unsigned beta must use a new version/build and tag, verified clean preview artifacts,
explicit unsigned-preview release notes, draft asset verification, and GitHub's
prerelease flag with latest disabled. Published assets must never be overwritten.

The homepage and README link to this exact published beta and state that Apple signing
is pending. When releasing a new beta, update those links only after its assets are
published. Once a notarized stable release exists, switch them to the stable latest URL.
The Release workflow recognizes an already-published unsigned beta and verifies its
tag, clean manifest, uploaded digests and mounted installer without importing signing
credentials or replacing assets. Unpublished normal releases still require notarization.

## Signing setup: once

A notarized release requires an Apple Developer account with a **Developer ID Application**
certificate and its private key, plus notarization credentials. No signing identity is
installed on the current development Mac yet. Never put certificate material or passwords
in the repository, release notes, issue comments or build logs.

Configure these repository Actions secrets in **Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `DECKHAND_SIGN_IDENTITY` | Exact identity, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `DECKHAND_CERTIFICATE_BASE64` | Base64 of the exported certificate and private key in a `.p12` file |
| `DECKHAND_CERTIFICATE_PASSWORD` | Password protecting that `.p12` export |
| `DECKHAND_APPLE_ID` | Apple ID belonging to the developer team |
| `DECKHAND_APPLE_APP_PASSWORD` | App-specific password for notarization |
| `DECKHAND_TEAM_ID` | Developer team ID |

The workflow imports the certificate into a temporary runner keychain, stores notarytool
credentials there, masks its generated password, and deletes the keychain at the end.
Missing secrets stop a public run before the expensive build. Contributors' CI previews
use no signing credentials and cannot publish.

For local public packaging, install the Developer ID certificate, store a notarytool
keychain profile using Apple's normal credential setup, and use a clean tagged checkout:

```sh
DECKHAND_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
DECKHAND_NOTARY_PROFILE='deckhand-local' Scripts/package-release.sh --public
python3 Scripts/release.py publish
```

`publish` also requires `gh` authentication and the existing tag on `origin`. The package
must pass public validation; a local preview or altered source/checksum cannot be published.
Local public packaging is optional; normal releases run in GitHub Actions.

## Previews and retries

Every branch CI run tests and builds an unsigned local preview. Its Actions artifact
contains the DMG, matching source, release notes, manifest and checksums, retained for
seven days. It is not a public GitHub Release and is marked inside the disk image.

For local testing:

```sh
python3 -m unittest discover -s Tests/ReleaseTests -v
Scripts/package-release.sh
python3 Scripts/release.py validate-artifacts
```

After the workflow exists on `main`, **Actions → Release → Run workflow** can rebuild an
existing tag. Leave **preview** checked to run without secrets or publishing. Uncheck it
for a public-release retry. Tests and verification run in either mode.

If build, signing, notarization or asset verification fails, the release stays absent or
draft. Fix transient credentials/service issues and rerun the same tag. A draft's assets
can be replaced on retry. If source code needs fixing, cut a new version and tag instead;
never move an existing tag. A published release is immutable through our tooling, and
re-running it refuses to replace its downloads.

## Download names and provenance

Each release has:

- `Deckhand-arm64.dmg`: fixed filename, so a permanent stable download URL works.
- `Deckhand-VERSION-source.tar.gz`: exactly `git archive` of the public release commit.
- `release-notes.md`: notes from the tagged source.
- `release-manifest.json`: full version/build, commit, platform, distribution status and
  DMG/source hashes. Dirty local previews are labelled explicitly.
- `SHA256SUMS.txt`: checksums for every download except the checksum file itself.

After the first stable release, the website and README can link to:

```text
https://github.com/harlow/deckhand/releases/latest/download/Deckhand-arm64.dmg
```

Until then, link to the Releases page or the specific published beta's tag download.
No moving beta feed is needed for the current single-download experience.

The app and DMG receive separate notarization tickets. The app is stapled **before** it
goes into the DMG. Both are checked with codesign, stapler and Gatekeeper. Installer
validation mounts the DMG read-only, checks the Applications shortcut, app version,
architecture, bundled resources/licenses, dynamic dependencies, and actual SQLCipher/
Core ML runtime behavior. Public publishing additionally verifies the pushed tag and
clean commit, notes, matching source and all uploaded asset digests.

See [standalone implementation and QA](plans/standalone-release.md) for the dependency
audit and isolated import/analysis/USB test evidence. A signed download still needs its
first-use test on a clean supported Mac before broadly announcing the first beta.
