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

## Recently landed (2026-10-08)

- `sync` no longer analyzes by default; it asks if tracks are unanalyzed (`--analyze`/`--no-analyze`), and
  unanalyzed tracks get tag BPM/key until a later sync writes their analysis files.
- `deckhand analyze` with no arguments analyzes the whole library.
- Per-drive output settings are remembered; default cue source is `deckhand`.
- Fixed: analysis version changes no longer force an audio re-copy (only ANLZ files + DB are rewritten).

## Next steps

1. `deckhand analyze` (library re-analysis for key model v5), then `deckhand sync /Volumes/RATS --cue-source deckhand`
   (first run saves the setting; afterwards plain `deckhand sync /Volumes/RATS`).
2. Deck test: confirm what the OMNIS-DUO does with an unanalyzed track (expected: analyzes on load).
3. `deckhand cleanup /Volumes/RATS --dry-run`, review, then clean (add `--keep-legacy` only if using older CDJs).
4. Deck check on OMNIS-DUO: named hot cues (A Mix In, D Build, E Main Drop, H Mix Out matter most), phrase colors,
   track colors, keys. Optional `--hot-cues core` if extra pads feel noisy.
5. Done (2026-10-08): Deckhand's own key/BPM is the default; `--use-mik` opts into MIK tags + database (replaces
   `--[no-]key-tags`, `--[no-]bpm-hint`, `--[no-]mixed-in-key`). Full analyze ≈ 9 min per 1,000 tracks on this Mac.

## Key model retrained (2026-10-08)

S-KEY's ChromaNet fine-tuned on Beatport EDM Key + FMAK + confident MIK library labels (`Scripts/key-training/`,
architecture unchanged); ensemble re-tuned to 3.8 × S-KEY + 0.4 minor bias. Analysis version 6 (re-analyze).
Test results, shipped → new (exact / MIREX / major recall):
GiantSteps 68.9 / 75.6 / 35.2 → 69.9 / 75.8 / 38.5; GiantSteps+ 84.1 / 87.9 / 56.2 → 85.5 / 88.7 / 62.5;
FMAK test 65.0 / 72.8 / 59.8 → 65.4 / 73.2 / 61.4; confident-MIK agreement (held-out) 94.9 → 98.3.
Swift vs PyTorch parity checked on 354 clips (max |Δp| 5e-4). Major-key recall is still the weak spot.
Training data and checkouts were deleted afterwards; `Scripts/key-training/setup.sh` recreates them (~43 GB).

## Working notes

- Build with a private scratch path when agents/others build concurrently: `swift build --scratch-path .build-main`.
  If you get odd "Undefined symbols" link errors, delete that scratch dir and rebuild.
- For syncing real drives, build from committed code (e.g. a `git worktree`) so in-progress edits don't ship.
- Fixtures from the user's Rekordbox stick live in `Fixtures/private/` (git-ignored, personal data — don't commit).
- MIK database is read-only answer key: `~/Library/Application Support/Mixedinkey/Collection11.mikdb`.
