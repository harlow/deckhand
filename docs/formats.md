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
/PIONEER/Artwork/<NNNNN>/b<id>.jpg, b<id>_m.jpg            cover art (80 px and 240 px JPEG)
/.deckhand/manifest.json                                   Deckhand sync state (players ignore it)
```

Rekordbox also writes `export.pdb` / `exportExt.pdb` (legacy Device Library, for CDJ-3000 and older).
Deckhand does not write them. The OMNIS-DUO reads a Deckhand drive without them (browse, play, art,
hot cues and play history confirmed); the other OneLibrary players (XDJ-AZ, OPUS-QUAD, CDJ-3000X) should
behave the same but haven't been tested. Players that only read the legacy Device Library (CDJ-3000 and
older) won't see a Deckhand drive.

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
  payload is 2 bytes per beat with 10-bit values we haven't decoded. **Off by default**; the OMNIS-DUO works without it. Hidden flags
  `deckhand sync --extended-beatgrid --rewrite-analysis` write it, for testing on other players.
- Waveforms are 150 entries/second. Heights track √RMS (fitted to Rekordbox output). PWV6 is a
  bucket average, PWV7 per-frame; 3-band values top out at 127. PWV4's six bytes per entry and PWVC's
  three values are only approximated.

## Analysis timeline

Players and Rekordbox time MP3s from the start of the encoded stream, *including* the encoder delay
(usually 576 samples) plus the 529-sample decoder delay that Core Audio trims; LAME-tagged files add
one more 1152-sample frame. That is ~25 ms (most files) or ~51 ms (LAME). `AudioDecoder.mp3TimelineOffset`
computes it and `TrackAnalyzer` shifts beat times and pads waveforms so `TrackAnalysis` is already on
the player's timeline. Non-MP3 formats get no offset (unverified for AAC/M4A).

## Analysis accuracy

Measured with the eval tools below. References are public human-labelled key datasets, Rekordbox's own
analysis, and Mixed In Key's analysis of a test library. Rekordbox and Mixed In Key serve only as answer
keys for evaluation; sync and analyze never read either. "Held-out" means tracks never used for training.

| | |
|---|---|
| BPM exact (±0.05) | 94%. Octave errors were 0% when the file's BPM tag was passed as a hint; that is an eval option only (`deckhand-grid-eval --hints tag`), sync and analyze don't read tags |
| Key, human-labelled (GiantSteps / GiantSteps+ / FMAK test zips 060-069 + 110-124) | 69.9% / 85.7% / 65.4% exact (MIREX 75.8 / 88.9 / 73.2); major-key recall 38.5% / 63.5% / 61.4% |
| Agreement with Mixed In Key labels where MIK is confident (≥0.8), held-out album folds | 98.3% (94.9% before S-KEY fine-tuning) |
| Key model | Linear model on libKeyFinder chroma (trained on Beatport EDM Key + Mixed In Key labels weighted by MIK's confidence) + 3.8 × fine-tuned S-KEY (Deezer, MIT; Swift CQT + Core ML) + 0.4 minor bias. ~0.12 s/track |
| Grid phase vs MIK (408 held-out) | median 2.2 ms; 95.7% within 10 ms; 2.3% ≥40 ms off |
| Grid phase vs Rekordbox | 75.5% within 10 ms (MIK itself: 77.5%) |
| Downbeat agrees with Rekordbox | 75.9% (Rekordbox's own first beat is bar 1 in only 83%) |
| Tempo range | 80–160 BPM; faster tempos fold to half time (172 → 86) |
| Auto cues vs MIK (424 held-out) | F1 0.70 at ±1 beat, 0.75 at ±1 bar; up to 8 per track on phrase boundaries |
| Track energy vs MIK | 55% exact, 97% within ±1 (always-6 baseline: 51% exact) |

Mixed In Key's beat times are on Core Audio's decoded timeline; the eval tools add
`AudioDecoder.mp3TimelineOffset` before comparing them with Rekordbox (then median 3.6 ms apart).

### Evaluation and training tools

The eval targets (`deckhand-eval`, `deckhand-grid-eval`, `deckhand-cue-eval`, `deckhand-structure-eval`)
need a local Rekordbox library and/or a Mixed In Key 11 database as the answer key.

- Grid: `python3 Scripts/export-grid-groundtruth.py rb.json && swift build -c release --product deckhand-grid-eval && .build/release/deckhand-grid-eval rb.json`
- Key model: `python3 Scripts/train-key-model.py` regenerates `KeyModelWeights.swift`; evaluate with `deckhand-eval key-eval`.
- S-KEY fine-tuning: [Scripts/key-training/](../Scripts/key-training/README.md); export with `Scripts/export-skey.py <skey> <checkpoint>`.
- Cues and energy: [Scripts/cue-model/](../Scripts/cue-model/README.md).
- Song structure: [Scripts/structure-model/](../Scripts/structure-model/README.md).
- BPM/key against Rekordbox (older): `python3 Scripts/export-groundtruth.py gt.json && swift build -c release --product deckhand-eval && .build/release/deckhand-eval gt.json`
