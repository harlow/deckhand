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

```sh
deckhand playlists                         # Apple Music playlists
deckhand devices                           # mounted USB drives
deckhand init /Volumes/DJUSB               # mark a FAT32/exFAT drive as Deckhand-managed (never formats)
deckhand sync /Volumes/DJUSB --playlist "House" --playlist "Friday" --dry-run
deckhand sync /Volumes/DJUSB               # re-sync the saved selection
deckhand status /Volumes/DJUSB
deckhand validate /Volumes/DJUSB
deckhand eject /Volumes/DJUSB
```

Sync is incremental: audio is copied once, analysis (BPM, beat grid, key, waveforms) is cached in
`~/Library/Application Support/Deckhand` by audio content and reused across drives. The library
database is rebuilt in a staging file, validated, and swapped in; play history recorded by the player
is preserved. Deckhand only deletes files it put on the drive.

Analysis is Deckhand's own: BPM and beat grid, key (Camelot/classic), and auto cue points with
energy levels, written as memory cues and colour-coded hot cues A–H (`--cues`, `--cue-source`).
If Mixed In Key 11 is installed, its stored results are used for tracks it already analyzed
(`--no-mixed-in-key` to turn off); it's never required.

Tracks that can't be exported (DRM, cloud-only, missing, unsupported format) are listed, never
silently dropped.

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
