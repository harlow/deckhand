# Deckhand — status (2026-10-07)

## Working and committed

- Sync Apple Music → OneLibrary USB; confirmed on OMNIS-DUO: browse/play, album art, hot cues, play history kept.
- Analysis (all Deckhand's own): beat grid (≈MIK parity), BPM, key (ensemble linear + S-KEY; GiantSteps 69% exact,
  94% agreement with confident MIK), auto cues + energy, song structure → named hot cues A–H, phrase colors (PSSI),
  energy track colors. Details/numbers: `docs/formats.md`.
- Commands: `playlists devices init analyze [--all] sync [--entire-library] [--adopt] status validate eject
  import-playlists [--add-missing] cleanup`.
- Last commit: `8cf2f37` (key ensemble) / `51ab041` (ID3 decode fallback) — see `git log`.

## RATS stick

- Fully Deckhand-managed: `sync --entire-library --adopt --cue-source deckhand` completed — 2,164 tracks,
  11 playlists, validates OK. 1,980 files adopted (moved), 184 copied. 28 DRM tracks skipped.
- Built with key model v4 (before the S-KEY ensemble). Rekordbox leftovers (≈178 old audio files, old ANLZ/artwork,
  export.pdb) still on the stick — `deckhand cleanup /Volumes/RATS --dry-run` not run yet.
- All 5 Rekordbox-only playlists were imported into Apple Music (Apple Music is canonical).

## Uncommitted work in progress

1. **Per-drive settings** (`Sources/deckhand/Commands.swift`, `Sources/Sync/Manifest.swift`,
   `Sources/Sync/SyncExecutor.swift`): sync output flags (`--cue-source`, `--hot-cues`, `--cues`, `--build-lead`,
   `--key-format`, `--track-color`, `--phrases`) are saved in the drive's manifest and reused; default cue source is
   now `deckhand`. Verified on the DJTEST image; full `swift test` not yet run. Commit after tests pass.

2. **Fix for the bug below is applied but untested** (`SyncPlanner.swift`: removed the `.replace` on outdated/missing
   analysis; `SyncExecutor.swift`: a missing ANLZ0000.DAT now counts as stale). Run `swift test`, then commit.

## Known bug (fix applied in working tree, untested)

- **Analysis version bumps force a full audio re-copy.** `SyncPlanner` marks a track `.replace` when
  `prev.analysisVersion != TrackAnalysis.currentVersion` or its ANLZ .DAT is missing, which counts toward
  `bytesToCopy` (RATS re-sync failed: "need 31.75 GB"). Fix: drop that `.replace` condition in the planner and,
  in `SyncExecutor`, also treat a missing ANLZ0000.DAT as stale (the fingerprint check already covers version
  changes). Then re-sync RATS to apply key model v5 (analysis is cached; only ANLZ files + DB are rewritten).

## Next steps

1. Run `swift test --scratch-path .build-main`; commit the settings work + the re-copy fix.
2. Re-sync RATS (`deckhand sync /Volumes/RATS` — settings are remembered after one run with `--cue-source deckhand`).
3. `deckhand cleanup /Volumes/RATS --dry-run`, review, then clean (add `--keep-legacy` only if using older CDJs).
4. Deck check on OMNIS-DUO: named hot cues (A Mix In, D Build, E Main Drop, H Mix Out matter most), phrase colors,
   track colors, keys. Optional `--hot-cues core` if extra pads feel noisy.
5. Then: drop MIK fallback by default (BPM/grid already at parity; key now beats the old model on human labels).

## Working notes

- Build with a private scratch path when agents/others build concurrently: `swift build --scratch-path .build-main`.
  If you get odd "Undefined symbols" link errors, delete that scratch dir and rebuild.
- For syncing real drives, build from committed code (e.g. a `git worktree`) so in-progress edits don't ship.
- Fixtures from the user's Rekordbox stick live in `Fixtures/private/` (git-ignored, personal data — don't commit).
- MIK database is read-only answer key: `~/Library/Application Support/Mixedinkey/Collection11.mikdb`.
