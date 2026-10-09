# Deckhand

Sync Apple Music playlists to a Pioneer/AlphaTheta DJ USB (OneLibrary format) without Rekordbox.

```
Apple Music → Deckhand → USB → OMNIS-DUO
```

Status: MVP, pending hardware confirmation. See [docs/deckhand-product-spec.md](docs/deckhand-product-spec.md)
and [docs/formats.md](docs/formats.md).

## Build

```sh
brew install sqlcipher
swift build -c release
.build/release/deckhand --help
```

Requires macOS 14+. The first run may ask for Media & Apple Music access.

## Use

Two simple steps — analyze, then sync:

```sh
deckhand analyze                           # analyze the whole Apple Music library (cached; only new tracks next time)
deckhand init /Volumes/DJUSB               # once per drive: mark it Deckhand-managed (never formats)
deckhand sync /Volumes/DJUSB --entire-library   # or --playlist "House" --playlist "Friday"
deckhand sync /Volumes/DJUSB               # later: re-sync with the drive's saved selection and settings
deckhand eject /Volumes/DJUSB
```

`sync` doesn't analyze by default, so it's fast. If some tracks aren't analyzed yet it asks whether to analyze them
now (`--analyze` / `--no-analyze` to skip the question); unanalyzed tracks show their tag BPM/key and get full
analysis files on a later sync.

Other commands: `playlists`, `devices`, `status`, `validate`, `import-playlists` (bring a Rekordbox drive's
playlists into Apple Music, `--add-missing` to add its tracks), `cleanup` (remove leftovers from another tool),
`sync --adopt` (take over audio already on a drive instead of copying it). Output settings such as
`--hot-cues`, `--build-lead`, `--key-format`, `--track-color` are remembered per drive.

## Hardware test (OMNIS-DUO)

Use a spare stick — `sync` replaces `PIONEER/rekordbox/exportLibrary.db`.

1. `deckhand init /Volumes/X` then `deckhand sync /Volumes/X --playlist "<small playlist>"`, then `deckhand eject`.
2. On the OMNIS-DUO check: drive mounts, playlist appears with the right name, tracks in the right
   order, tracks load and play, BPM and key shown, waveform renders, beat grid lines up with the kick,
   no re-analysis prompt, no new `ANLZ0001.*` files on the stick afterwards.
3. If it fails, try the extended beat grid:
   `deckhand sync /Volumes/X --extended-beatgrid --rewrite-analysis` and test again.
4. Bring the stick back and run `deckhand validate /Volumes/X`; look for `ANLZ0001.*` files
   (the player rejected ours) and `RBFLTR.DAT`.

## Layout

| Target | Role |
|---|---|
| `DeckhandCore` | Normalized source model, `TrackAnalysis`, `MusicalKey` |
| `MusicSource` | Apple Music via `iTunesLibrary.framework` |
| `Analysis` | Decode (AVFoundation), waveforms, BPM/beat grid and key (vendored qm-dsp, GPL) |
| `OneLibrary` | ANLZ writer, `exportLibrary.db` writer, validator |
| `Sync` | Planner (diff), executor (copy/analyze/stage/commit), manifest, analysis cache |
| `deckhand` | CLI |

## License

GPL-3.0-or-later (qm-dsp is GPL). Not affiliated with AlphaTheta or Pioneer DJ.
