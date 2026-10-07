# Format notes

What Deckhand writes, and what we learned matching it to Rekordbox 7 exports. Sources: our own
comparisons against a Rekordbox 7 USB export and local Rekordbox analysis files, the
[fourfour notes](https://github.com/morizkraemer/fourfour/blob/master/pioneer-usb-writer/reference-code/PIONEER.md)
(reference only — no code copied), [pyrekordbox](https://github.com/dylanljones/pyrekordbox) (MIT) and
[Deep Symmetry's analysis](https://djl-analysis.deepsymmetry.org/).

## USB layout

```
/Contents/Deckhand/<hh>/<Artist - Title> [<hash8>].<ext>   audio (Deckhand-owned)
/PIONEER/rekordbox/exportLibrary.db                        OneLibrary database
/PIONEER/USBANLZ/P<XXX>/<HHHHHHHH>/ANLZ0000.{DAT,EXT,2EX}  analysis
/.deckhand/manifest.json                                   Deckhand sync state (players ignore it)
```

Rekordbox also writes `export.pdb` / `exportExt.pdb` (legacy Device Library, for CDJ-3000 and older).
Deckhand does not write them yet. OneLibrary-only players (OMNIS-DUO, XDJ-AZ, OPUS-QUAD, CDJ-3000X)
should not need them — **unconfirmed until the hardware test**.

## exportLibrary.db

- SQLCipher 4 defaults, key `r8gddnr4k847830ar6cqzbkk0el6qytmb3trbbx805jm74vez64i5o8fnrqryqls`.
- Journal mode **WAL** (as Rekordbox writes it). We checkpoint and close before moving the file into place,
  so no `-wal`/`-shm` files are left.
- Schema and the four indexes match Rekordbox byte-for-byte (`schemaMatchesGoldenExport` test).
- `property`: one row, `dbVersion = "1000"`, `deviceName = ""`.
- `menuItem` / `category` / `sort`: copied from a Rekordbox export (`OneLibraryMenus.swift`). Names are
  wrapped in U+FFFA…U+FFFB.
- Absent foreign keys are `0`, not NULL. `titleForSearch` / `nameForSearch` are empty strings.
- `analysedBits = 41` for analyzed tracks; `analysisDataUpdateCount = informationUpdateCount = 1`.
- `key.name` is a free-form display string — Rekordbox libraries mix `Am`, `8A`, `Amin`. Deckhand
  writes one format (`--key-format classic|alphanumeric`).
- `playlist.sequenceNo` is 0-based among siblings; `playlist_content.sequenceNo` is 1-based.
  Folders: `attribute = 1` (assumed; not present in our golden export).
- **The player writes to this database**: `history`, `history_content` and `content.djPlayCount`.
  Deckhand rebuilds the DB each sync and carries those over for content IDs that still exist.
- Unknown / left at 0: `contentLink` (Rekordbox: constant 788224 per source library),
  `masterDbId`, `masterContentId`.

## ANLZ files

Path: hash of the USB-relative audio path (UTF-16 code units), see `AnlzPath.swift`. Players ignore
`analysisDataFilePath` and compute this themselves.

Section order (matches Rekordbox USB exports):

| File | Sections |
|---|---|
| .DAT | PPTH PVBR PQTZ PWAV PWV2 PCOB PCOB |
| .EXT | PPTH PWV3 PCOB PCOB PCO2 PCO2 [PQT2] PWV5 PWV4 [PSSI] |
| .2EX | PPTH PWV7 PWV6 PWVC |

- `PMAI` header: `1, 0x10000, 0x10000, 0`.
- `PPTH`: UTF-16BE **with null terminator**; length field includes it. Players reject the file otherwise.
- `PVBR`: 400 zero entries + total sample count. Rekordbox leaves entries zero even for MP3s we checked.
- `PQTZ`: header is 24 bytes, second field must be `0x80000`. Beats are `u16 bar position, u16 bpm×100, u32 ms`.
- `PQT2`: always present in Rekordbox USB exports. Header: two anchor beats (first, last) + beat count;
  payload is 2 bytes per beat with 10-bit values we haven't decoded. **Off by default**; enable with
  `deckhand sync --extended-beatgrid --rewrite-analysis` (hidden flags) for the hardware A/B test.
- Waveforms are 150 entries/second. Heights track √RMS (fitted to Rekordbox output). PWV6 is a
  bucket average, PWV7 per-frame; 3-band values top out at 127. PWV4's six bytes per entry and PWVC's
  three values are only approximated.

## Analysis timeline

Players and Rekordbox time MP3s from the start of the encoded stream, *including* the encoder delay
(usually 576 samples) plus the 529-sample decoder delay that Core Audio trims; LAME-tagged files add
one more 1152-sample frame. That is ~25 ms (most files) or ~51 ms (LAME). `AudioDecoder.mp3TimelineOffset`
computes it and `TrackAnalyzer` shifts beat times and pads waveforms so `TrackAnalysis` is already on
the player's timeline. Non-MP3 formats get no offset (unverified for AAC/M4A).

## Analysis accuracy (vs Rekordbox, 150 random tracks)

| | |
|---|---|
| BPM exact (±0.05) | 94% (0% octave errors with tag hints) |
| Key exact (libKeyFinder) | 67% — Mixed In Key tags agree with Rekordbox 99%, so tags are preferred |
| Grid phase median error | 6.8 ms; ~15% of grids 40–110 ms off, 4% half a beat off |
| Downbeat agreement | ~43% |

Re-run: `python3 Scripts/export-groundtruth.py gt.json && swift build -c release --product deckhand-eval && .build/release/deckhand-eval gt.json`.
