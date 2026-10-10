# Project status

## Works

- **Sync** from Apple Music to a OneLibrary USB drive. Confirmed on an AlphaTheta OMNIS-DUO: browsing,
  playback, album art, hot cues, and play history (the deck's history and play counts survive later syncs).
- **Analysis**, all done by Deckhand itself: BPM and beat grid, key (linear model plus a fine-tuned S-KEY
  ensemble), waveforms, auto cues and track energy, song structure turned into named hot cues A–H, phrase
  colors (PSSI) and energy-based track colors. Accuracy numbers are in [formats.md](formats.md#analysis-accuracy).
- **CLI**: `playlists`, `devices`, `init`, `analyze`, `sync`, `status`, `validate`, `eject`,
  `import-playlists`, `cleanup`, `ratings backup|restore`. Run `deckhand help <command>` for flags.
  - `sync` doesn't analyze by default. It asks when tracks aren't analyzed yet (`--analyze` /
    `--no-analyze` answer up front). Unanalyzed tracks are synced without BPM, key or cues until a
    later sync writes their analysis.
  - Output settings (`--key-format`, `--cues`, `--hot-cues`, `--build-lead`, `--track-color`,
    `--[no-]phrases`) are remembered per drive.
  - A change in analysis version rewrites only the analysis files and database, not the audio.
  - `sync --adopt` takes over audio already on the drive (e.g. from a Rekordbox export) instead of
    copying it again; `cleanup` then removes what the old export left behind.
- **Mac app** (first pass): library browser with waveforms, keys, energy and filters, player and queue,
  star ratings and Quick Rate, analysis and sync. See [mac-app.md](mac-app.md).

## Known limitations

- Only the OMNIS-DUO has been tested. Other OneLibrary players (XDJ-AZ, OPUS-QUAD, CDJ-3000X) should
  work; players that only read the legacy `export.pdb` (CDJ-3000 and older) aren't supported.
- Major-key recall is the weakest part of key detection (see [formats.md](formats.md#analysis-accuracy)).
- The MP3 timeline offset is verified; AAC/M4A files get no offset and that is unverified.
- Analysis can't be corrected by hand yet.
- In the app, a drive's playlists must be chosen once with `deckhand sync <drive>` in Terminal.
- Full library analysis takes roughly 9 minutes per 1,000 tracks on an Apple Silicon Mac.

## Next

1. Fixing analysis by hand (BPM halving/doubling, downbeat, key, cues) in the Mac app.
2. Smart crates (saved filters that sync like playlists).
3. Genre families for the filter (see [genres.md](genres.md)).

The longer list is in [mac-app.md](mac-app.md#more-features).

## Development notes

- If several builds run at once (e.g. two checkouts or agents), give each its own scratch path:
  `swift build --scratch-path .build-main`. Odd "Undefined symbols" link errors usually go away after
  deleting that scratch directory and rebuilding.
- When syncing a real drive during development, build from committed code (e.g. a `git worktree`) so
  half-finished edits don't end up on the stick.
