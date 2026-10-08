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
5. Then: drop MIK fallback by default (BPM/grid already at parity; key now beats the old model on human labels).

## TODO: retrain key model (run on a machine with a GPU / time to spare)

Goal: fix major-key recall (35% GiantSteps, 60% FMAK; library is 93% minor) by fine-tuning S-KEY's ChromaNet.
Current baseline (ensemble linear + 0.7 × S-KEY): GiantSteps 68.9% exact / MIREX 75.6, GiantSteps+ 84.2 / 88.0,
FMAK subset 64.2 / 71.6, ~94% agreement with confident MIK keys.

1. Data (not in the repo; download to a scratch dir, ~27 GB+):
   - GiantSteps Key (test only): Zenodo 1095691; GiantSteps+/Beatport EDM Key: Zenodo 1101082 (see mirdata loaders).
   - FMAKv2 (CC-BY-4.0): Zenodo 10719860 — keep some zips as a test split.
   - Optional weak labels: library tracks with Mixed In Key confidence ≥ 0.8 (MIK DB on the original Mac only).
2. Fine-tune ChromaNet from github.com/deezer/skey (MIT) in PyTorch (MPS/CUDA): Beatport EDM Key (minus titles that
   overlap GiantSteps) + FMAK train split (+ down-weighted MIK labels); transposition augmentation by rolling CQT
   bins; class-balanced loss for major/minor; early stopping on a validation split. Keep the architecture unchanged.
   GiantSteps (orig and +) and FMAK test zips are strictly test-only.
3. Re-tune the ensemble weight α (and optionally a major/minor bias) by cross-validation on training data.
4. Ship only if human-label accuracy improves and confident-MIK agreement drops ≤ ~1 point:
   `Scripts/export-skey.py` (extend to take a checkpoint) → `Sources/Analysis/Resources/SKeyChromaNet.mlmodelc`;
   verify Swift vs PyTorch parity on ≥ 40 clips; bump `TrackAnalysis.currentVersion`; `swift test`.
   Report exact / MIREX / major recall / minor recall per test set, before vs after.
   Existing tools: `Scripts/train-key-model.py` (linear head), `deckhand-eval key-eval-dataset`.

## Working notes

- Build with a private scratch path when agents/others build concurrently: `swift build --scratch-path .build-main`.
  If you get odd "Undefined symbols" link errors, delete that scratch dir and rebuild.
- For syncing real drives, build from committed code (e.g. a `git worktree`) so in-progress edits don't ship.
- Fixtures from the user's Rekordbox stick live in `Fixtures/private/` (git-ignored, personal data — don't commit).
- MIK database is read-only answer key: `~/Library/Application Support/Mixedinkey/Collection11.mikdb`.
