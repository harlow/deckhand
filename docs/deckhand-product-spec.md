# Deckhand — Product & Technical Specification

**Status:** Original design spec, written before implementation (v0.1, October 7, 2026)  
**Primary platform:** macOS  
**Initial hardware target:** AlphaTheta OMNIS-DUO  
**Primary source library:** Apple Music.app (formerly iTunes)  
**Core promise:** Build and sync DJ-ready USB drives from Apple Music playlists without opening Rekordbox.

> **Note.** This is the plan Deckhand was built from, kept as a design record. The principles and sync
> design still hold, but where it differs from the code, the code wins. Current behavior is documented in
> the [README](../README.md), [formats.md](formats.md), [mac-app.md](mac-app.md) and
> [status.md](status.md). The main differences:
>
> - Hardware compatibility is proven: the OMNIS-DUO browses and plays Deckhand drives, with album art, hot
>   cues and play history. Sections 26, 27 and 35 describe that milestone as still to come.
> - The scope grew past v1 (section 6): Deckhand writes hot and memory cues, named hot cues from song
>   structure, phrase analysis, energy-based track colors and ratings, and the Mac app has playback,
>   library browsing and rating.
> - Section 9's SQLite data model became a JSON manifest per drive (`/.deckhand/manifest.json`) plus an
>   on-disk analysis cache keyed by audio hash.
> - Section 16's CLI was a sketch. The real commands also include `analyze`, `import-playlists`, `cleanup`
>   and `ratings`; the "global flags" (`--json`, `--quiet`, `--no-delete`) and `sync --rebuild` don't
>   exist. Run `deckhand help` for the current list.
> - Section 17's minimal GUI was replaced by the fuller Mac app in [mac-app.md](mac-app.md).
> - Analysis uses vendored GPL libraries (qm-dsp, libKeyFinder) plus Deckhand's own trained models, so the
>   project is GPL.

---

## 1. Summary

Deckhand is a small macOS utility that turns selected Apple Music playlists into a Pioneer/AlphaTheta-compatible DJ USB.

The user continues to organize music in Apple Music, which remains the library and playlist UI. Deckhand is responsible for the mechanical work normally performed by Rekordbox:

1. Read Apple Music playlists and resolve their local audio files.
2. Compare the desired playlist state against the previous USB sync.
3. Copy only new or changed audio files.
4. Remove orphaned files when appropriate.
5. Analyze new tracks for DJ metadata such as BPM, beat grid, key, and waveform data.
6. Write the AlphaTheta/Pioneer USB database and analysis files.
7. Preserve playlist names, folders, track ordering, and metadata.
8. Safely finalize/eject the USB.

The intended experience is:

```text
Apple Music → Deckhand → USB → OMNIS-DUO
```

The product is intentionally **not** a Rekordbox replacement. Apple Music is the collection and playlist manager; Deckhand is the synchronization/export layer.

---

## 2. Problem

The existing Rekordbox workflow is much larger and more complex than this use case requires.

The target user wants to:

- manage songs in Apple Music;
- create and reorder named playlists there;
- plug in a USB drive;
- sync selected playlists to the USB;
- plug that drive directly into an OMNIS-DUO or compatible player;
- see the playlists and tracks with DJ-ready metadata.

Today Rekordbox acts as an unnecessary second library manager between Apple Music and the DJ hardware.

The product opportunity is to remove that middle step.

---

## 3. Product principles

### 3.1 Apple Music is the source of truth

Deckhand should not become another full music-library application.

Playlist creation, naming, ordering, and general music organization remain in Apple Music.

### 3.2 The USB should be disposable

A USB is an export target, not the master database.

If a drive is lost or reformatted, Deckhand should be able to recreate it from the source library.

### 3.3 Sync should be incremental

A second sync should not recopy or reanalyze an unchanged 5,000-track library.

Deckhand should identify:

- added tracks;
- removed tracks;
- changed track files;
- renamed playlists;
- reordered playlists;
- changed playlist membership;
- changed metadata.

### 3.4 Never corrupt a working DJ drive

Writes should be staged and validated before replacing working database files.

An interrupted sync should fail safely.

### 3.5 Hardware compatibility matters more than theoretical format correctness

A database that parses successfully on a computer but is rejected by the actual hardware is a failure.

Real-device tests are part of the definition of done.

### 3.6 Keep v1 narrow

Initial target:

```text
macOS
  ↓
Apple Music local files
  ↓
Deckhand
  ↓
OneLibrary USB
  ↓
OMNIS-DUO
```

Do not solve every DJ ecosystem in the first release.

---

## 4. Research conclusion / feasibility

This product appears technically feasible.

AlphaTheta now calls its newer USB library format **OneLibrary** (previously “Device Library Plus”). AlphaTheta states that the OMNIS-DUO uses OneLibrary, and that compatible DJ software can export playlists, music files, cue points, beat grids, and waveform information to compatible USB media.

Current AlphaTheta guidance also distinguishes:

- **OneLibrary** — OMNIS-DUO, XDJ-AZ, OPUS-QUAD, CDJ-3000X
- **Device Library** — CDJ-3000, XDJ-XZ, RX3 and many older players

Rekordbox 7.2.11+ currently writes both formats for broad compatibility.

The undocumented Pioneer/AlphaTheta USB structures have also been independently reverse-engineered. Current projects document and/or implement:

- legacy `export.pdb` read/write;
- OneLibrary `exportLibrary.db`;
- playlist tables;
- track metadata;
- audio paths;
- artwork paths;
- Pioneer ANLZ data;
- beat grids;
- waveform data;
- hardware-sensitive path and binary-format details.

The `fourfour` project specifically describes itself as a tool to write CDJ-compatible USB drives without Rekordbox and states that its format layer has been proven on real CDJ-3000 hardware. Its OneLibrary notes include the current `exportLibrary.db` schema and analysis-file behavior.

**Important licensing note:** the fourfour repository does not currently present an obvious repository-wide open-source license. Treat it as technical research/reference unless permission or licensing terms are confirmed. Do not copy its implementation directly into a commercial product without resolving this.

For legacy Device Library support, `rekordbox-pdb-rs` is MIT licensed and provides read/write support for `export.pdb`.

### Primary references

- AlphaTheta OneLibrary:  
  https://alphatheta.com/en/onelibrary/

- AlphaTheta USB compatibility notice, March 18 2026:  
  https://alphatheta.com/en/information/important-notice-for-customers-using-usb-devices-with-our-dj-equipment/

- OMNIS-DUO manual:  
  https://downloads.support.alphatheta.com/manuals/OMNIS_DUO_DRI1882A_manual.pdf

- fourfour:  
  https://github.com/morizkraemer/fourfour

- fourfour Pioneer/OneLibrary reverse-engineering notes:  
  https://github.com/morizkraemer/fourfour/blob/master/pioneer-usb-writer/reference-code/PIONEER.md

- MIT-licensed legacy Device Library writer:  
  https://github.com/fragmede/rekordbox-pdb-rs

- Deep Symmetry DeviceSQL/ANLZ research:  
  https://github.com/Deep-Symmetry/crate-digger

- Apple Music XML export documentation:  
  https://support.apple.com/guide/music/save-a-copy-of-a-playlist-mus27cd5060f/mac

---

## 5. Primary user story

> As a DJ who manages music in Apple Music, I want to select several Apple Music playlists and sync them directly to a USB drive so that my OMNIS-DUO can browse and play those playlists without requiring me to maintain a duplicate Rekordbox library.

Example:

```text
Apple Music

DJ
├── House
├── Disco
├── Pool Party
├── New Stuff
└── Friday
```

Deckhand:

```text
$ deckhand sync

DJ USB: SANDISK 128GB

Selected playlists

✓ House          184 tracks
✓ Disco           92 tracks
  Pool Party      71 tracks
✓ New Stuff       26 tracks
✓ Friday          48 tracks

Changes

+ 7 tracks
- 2 tracks
~ 3 playlists changed

Sync? [Y/n]
```

After sync, the user inserts the USB into an OMNIS-DUO and sees:

```text
PLAYLISTS
├── House
├── Disco
├── New Stuff
└── Friday
```

with playlist order and track order matching Apple Music.

---

## 6. Initial scope

### In scope for v1

- macOS only.
- Apple Music.app as the source library.
- Local, playable audio files.
- Select playlists to sync.
- Preserve playlist names.
- Preserve playlist hierarchy where available.
- Preserve track order.
- Incremental sync.
- OneLibrary export.
- OMNIS-DUO as the primary hardware acceptance target.
- Track metadata needed for useful browsing.
- BPM analysis.
- Beat-grid generation.
- Musical key analysis.
- Required waveform/ANLZ generation.
- Dry-run/diff mode.
- Safe/atomic database updates.
- Human-readable errors.
- Persistent per-drive sync state.
- CLI first.
- Optional minimal macOS UI later.

### Explicitly out of scope for initial v1

- Full Rekordbox replacement.
- Performance mode.
- Mixing.
- Audio playback.
- Library browsing beyond what is needed to select playlists.
- Metadata editing.
- Cue-point editing UI.
- Cloud music download.
- Circumventing Apple Music DRM.
- Windows.
- Serato library support.
- Traktor library support.
- Spotify or streaming-service integration.
- Automatic DJ set generation.
- Smart-playlist editor.
- Older CDJ support unless it falls out cheaply from the architecture.
- Writing to the user's Rekordbox desktop database.

---

## 7. Audio eligibility

Deckhand must distinguish between playlist entries and actual exportable audio files.

### Supported source concept

A track is exportable when Deckhand can resolve it to a local audio file that the target hardware can decode.

Likely initial formats:

- MP3
- AAC/M4A where unprotected
- WAV
- AIFF
- FLAC

Actual format support should be validated against the target OMNIS-DUO firmware/specification before finalizing the allowlist.

### Not exportable

Examples:

- Apple Music subscription tracks protected by DRM;
- cloud-only tracks with no accessible local source file;
- missing files;
- unsupported codecs;
- inaccessible files.

These should never silently disappear.

Example:

```text
Cannot sync 3 tracks

Friday
  ! Artist — Song A
    Apple Music subscription track; no exportable local file

House
  ! Artist — Song B
    Local file is missing

Disco
  ! Artist — Song C
    Unsupported file type
```

Sync may continue with eligible tracks after explicit/default policy is defined.

---

## 8. Source-library integration

### Preferred approach

Read Apple Music directly from macOS automation APIs.

Preferred implementation: **`iTunesLibrary.framework` (`ITLibrary`)**. It is Apple's read-only library API and exposes persistent IDs, file locations, playlists with parent/folder IDs, and resolved smart-playlist contents without scripting or foregrounding Music.app.

Fallbacks:

1. AppleScript / `osascript`
2. ScriptingBridge

The adapter should expose a stable internal model rather than leak AppleScript concepts throughout the app.

Required source fields:

```text
Playlist
- stable source ID
- name
- parent/folder ID if applicable
- position/order

Track
- stable source ID / persistent ID
- title
- artist
- album
- genre
- track number
- year
- rating if useful
- duration
- local filesystem URL/path
- source modification information if available
```

### Fallback

Support Apple Music XML exports as a debugging/import fallback.

Apple supports exporting individual playlists or the library as XML.

This is not the preferred daily workflow because manual export defeats the product's primary value.

---

## 9. Internal data model

Deckhand should maintain its own small local database.

SQLite is sufficient.

Suggested entities:

### `source_tracks`

```text
source_track_id
persistent_id
title
artist
album
genre
duration_ms
source_path
file_size
file_mtime
file_hash
codec
sample_rate
bit_depth
metadata_hash
```

### `source_playlists`

```text
source_playlist_id
name
parent_id
sort_order
metadata_hash
```

### `source_playlist_tracks`

```text
source_playlist_id
source_track_id
position
```

### `analysis`

```text
source_track_id
analysis_version
audio_hash
bpm
key
beatgrid_blob/reference
waveform_blob/reference
three_band_waveform_blob/reference
analysis_completed_at
```

### `devices`

```text
device_id
volume_uuid
volume_name
filesystem
first_seen_at
last_synced_at
export_format_version
```

### `device_tracks`

Maps source tracks to exported USB paths/IDs.

```text
device_id
source_track_id
usb_content_id
usb_relative_path
audio_hash
analysis_hash
last_synced_at
```

### `device_playlists`

```text
device_id
source_playlist_id
usb_playlist_id
name
parent_usb_playlist_id
playlist_hash
last_synced_at
```

This mapping enables deterministic incremental updates and stable IDs across repeated syncs.

---

## 10. Track identity

Do not identify tracks using title + artist.

Preferred identity chain:

1. Apple Music persistent ID for source identity.
2. Audio file hash for content identity.
3. Path + size + modification timestamp as an optimization before hashing.

This matters because:

- files can move;
- metadata can change;
- two songs can have identical titles;
- a track may appear in many playlists;
- playlist membership changes should not duplicate audio.

One physical audio file should generally be copied once even if referenced by twenty playlists.

---

## 11. Sync state / diff algorithm

Sync should be deterministic.

### Step 1 — discover source state

Read selected Apple Music playlists and flatten their track membership into a desired-state graph.

### Step 2 — validate tracks

For every track:

- resolve local source path;
- verify readability;
- inspect codec;
- verify target compatibility;
- calculate/refresh identity hash as needed.

### Step 3 — load previous device state

Read:

- Deckhand's device manifest/state;
- existing OneLibrary database where useful;
- filesystem contents.

Do not rely solely on the hidden Deckhand manifest; the exporter should be able to detect unexpected drive changes.

### Step 4 — calculate diff

Output categories:

```text
Tracks
+ add
- remove
~ replace/reanalyze
= unchanged

Playlists
+ create
- delete
~ rename/reorder/membership change
= unchanged
```

### Step 5 — analyze only what is necessary

A new analysis is needed when:

- a new audio file is added;
- underlying audio content changed;
- analysis algorithm version changed;
- required generated data is missing/corrupt.

Playlist-only changes must not trigger audio reanalysis.

### Step 6 — stage changes

Create new databases and metadata in a temporary/staging location.

Prefer same-volume staging where atomic rename semantics are helpful.

### Step 7 — copy/delete files

Copy added/replaced audio.

Only remove orphaned audio after determining that no selected playlist references it.

### Step 8 — generate database

Build OneLibrary structures from desired state.

### Step 9 — validate

Run internal structural validation before commit.

### Step 10 — commit

Swap staged databases into place.

Write updated Deckhand manifest last.

### Step 11 — sync filesystem buffers / optional eject

Provide:

```text
deckhand eject
```

or automatically offer safe eject from a GUI.

---

## 12. USB structure

Exact output must be verified against current AlphaTheta-compatible exports.

Conceptually:

```text
/
├── Contents/
│   └── ...
└── PIONEER/
    ├── rekordbox/
    │   ├── exportLibrary.db
    │   └── ...
    ├── USBANLZ/
    │   └── ...
    └── Artwork/
        └── ...
```

OneLibrary uses an `exportLibrary.db` database plus associated analysis/waveform data.

The reverse-engineering references currently describe `exportLibrary.db` as a SQLCipher-encrypted SQLite database and document the relevant schema.

Do not assume schema/version stability. Put the export implementation behind an interface such as:

```swift
protocol DeviceExporter {
    func inspect(volume: URL) throws -> DeviceState
    func plan(desired: Library) throws -> SyncPlan
    func export(_ plan: SyncPlan) throws
    func validate(volume: URL) throws -> ValidationReport
}
```

This allows additional exporter versions later.

---

## 13. Analysis pipeline

This is likely the most complex subsystem after format writing.

Required output should be validated against the OMNIS-DUO rather than inferred solely from desktop parsers.

Potential analysis stages:

```text
audio
  ↓
decode PCM
  ↓
loudness / peak data
  ↓
BPM
  ↓
beat grid
  ↓
musical key
  ↓
waveform envelopes
  ↓
3-band waveform
  ↓
Pioneer/AlphaTheta analysis serialization
```

### Required / likely metadata

- track duration;
- BPM;
- beat-grid locations;
- musical key;
- overview waveform;
- detailed waveform;
- three-band waveform for OneLibrary;
- seek/index information where required by format/hardware;
- analysis-file path references.

### Version analysis output

Analysis results must include an `analysis_version`.

Example:

```text
analysis_version = 3
audio_hash = abc123...
```

If the algorithm changes, Deckhand can selectively invalidate old analysis.

### Initial strategy

Before investing heavily in custom DSP, investigate reusable libraries for:

- BPM;
- beat tracking;
- key detection;
- waveform generation.

Keep DSP output independent from Pioneer serialization:

```text
GenericTrackAnalysis
        ↓
OneLibraryAnalysisWriter
```

This avoids coupling the audio-analysis algorithm to the USB format.

---

## 13A. Track enrichment, tags, color, and harmonic key

Deckhand should not only make tracks playable; it should make the USB feel like a properly prepared DJ library.

The analysis/enrichment pipeline should populate the metadata used while browsing and filtering on the hardware.

### Core enriched fields

For every analyzed track, Deckhand should aim to provide:

```text
BPM
Musical key
Harmonic/alphanumeric key
Color
Rating
Comments
My Tags
```

The OneLibrary format has native track-level fields for BPM, musical key, color, rating, and DJ comments. Current OneLibrary implementations also expose My Tag relationships. Target hardware, including OMNIS-DUO, can use BPM, key, rating, color, and tag information as track-filter criteria.

### BPM

BPM should be computed from the audio rather than relying on potentially stale source-file metadata.

Store sufficient precision internally:

```text
128.00
124.37
```

The OneLibrary representation stores BPM × 100.

Deckhand should also retain confidence/debug information internally if the analyzer can provide it.

### Musical key

Store a normalized musical key internally, for example:

```text
A minor
C major
F# minor
```

The exporter can then render the representation expected by the target library/device.

### Harmonic key

Deckhand should additionally calculate a harmonic-mixing representation.

Example:

```text
A minor  → 8A
C major  → 8B
E minor  → 9A
G major  → 9B
```

Internally, keep the canonical musical key and derive display formats from it rather than treating `8A` as the only source of truth.

Suggested model:

```text
key_tonic
key_mode
key_classic
key_alphanumeric
```

For example:

```text
key_tonic        = A
key_mode         = minor
key_classic      = Am
key_alphanumeric = 8A
```

Rekordbox supports both Classic and Alphanumeric key-display formats, so Deckhand should be capable of exporting/displaying either representation as appropriate.

### Color

Color should be treated as useful DJ metadata, not waveform styling.

OneLibrary exposes eight standard track colors:

```text
Pink
Red
Orange
Yellow
Green
Aqua
Blue
Purple
```

Deckhand should support:

1. preserving a source color where one exists;
2. assigning a color in Deckhand;
3. applying color through rules;
4. leaving it unset.

Do **not** invent automatic color semantics in the core format. Instead, make automatic color assignment a configurable rule.

Possible future examples:

```text
Energy 1–2 → Blue
Energy 3   → Green
Energy 4   → Orange
Energy 5   → Red
```

or:

```text
Warm-up playlist → Aqua
Peak-time playlist → Red
Closing playlist → Purple
```

These are user-defined workflows, not universal meanings.

### Rating

Support a normalized 0–5 rating.

Possible source precedence:

```text
Deckhand override
→ Apple Music rating, if available
→ unset
```

### Comments

Comments are useful as a portable free-text field.

Deckhand may generate or preserve text such as:

```text
Peak time
Vocal
Long intro
Good opener
Clean
Explicit
```

Avoid overwriting an existing source comment unless explicitly configured.

### My Tags

My Tags should be modeled as first-class many-to-many metadata when practical.

Example:

```text
Energy
├── Low
├── Medium
└── High

Vibe
├── Deep
├── Funky
├── Euphoric
└── Dark

Use
├── Opener
├── Builder
├── Peak
└── Closer

Vocals
├── Instrumental
├── Vocal
└── Acapella-friendly
```

A track may have multiple tags.

This creates room for Deckhand to become a lightweight **DJ preparation engine** without becoming a second music-library application.

### Automatic enrichment vs user metadata

Separate metadata into two categories.

#### Computed

Safe for Deckhand to regenerate:

```text
BPM
beat grid
musical key
harmonic key
waveforms
analysis confidence
```

#### Curated

Should be preserved unless the user explicitly edits or applies a rule:

```text
color
rating
comments
My Tags
```

This distinction should be represented in the internal model.

### Source-file writeback

By default, Deckhand should **not modify the user's original audio files**.

The canonical workflow is:

```text
original audio
      ↓
Deckhand analysis database
      ↓
OneLibrary metadata on USB
```

This avoids unexpectedly changing ID3/MP4/FLAC metadata, file modification dates, cloud-sync state, or Apple Music's view of the file.

A later explicit option may support:

```bash
deckhand write-tags
```

or:

```text
[ ] Write BPM and key back to original audio files
```

If implemented, source-file writeback must be opt-in and should initially be limited to well-supported portable fields such as:

- BPM;
- musical key;
- selected comment fields.

Color and My Tags should remain Deckhand/OneLibrary metadata unless a clearly interoperable file-tag convention is chosen.

### Enrichment cache

Analysis should remain independent of the USB.

Example:

```text
Apple Music track
      ↓
Deckhand analysis cache
      ├── BPM
      ├── beat grid
      ├── key
      ├── harmonic key
      ├── waveforms
      └── computed metadata
      ↓
one or more USB exports
```

This means plugging in a second backup USB should not cause Deckhand to analyze the music again.

### Suggested future UI

A lightweight review surface could eventually show:

```text
TITLE                  BPM      KEY       HARMONIC    COLOR
Move Your Body         125.00   F#m       11A         ● Red
Music Sounds Better    124.00   Bm        10A         ● Orange
Finally                126.00   C#m       12A         ● Purple
```

The goal is preparation and correction, not general library management.

---

## 14. OneLibrary writer

### Responsibility

Translate Deckhand's normalized internal library into the files required by OneLibrary-compatible hardware.

It should own:

- USB content IDs;
- artist IDs;
- album IDs;
- genre IDs;
- key IDs;
- playlist IDs;
- parent playlist relationships;
- playlist entry ordering;
- USB-relative audio paths;
- analysis-file paths;
- artwork paths;
- required database properties;
- database encryption;
- version-specific fields.

### Do not expose format quirks to the rest of Deckhand

The rest of the app should say:

```text
Playlist {
  name: "Friday",
  tracks: [...]
}
```

not:

```text
insert into playlist_content(...)
```

### Stability strategy

Use deterministic ID allocation where safe.

Persist source-to-device ID mappings so that unchanged tracks/playlists do not receive new IDs on every sync.

---

## 15. Legacy Device Library

Legacy support should be a separate exporter.

Possible later architecture:

```text
Normalized Library
       │
       ├── OneLibraryExporter
       │     └── OMNIS-DUO / XDJ-AZ / OPUS-QUAD / CDJ-3000X
       │
       └── DeviceLibraryExporter
             └── CDJ-3000 / XDJ-XZ / RX3 / older devices
```

A future "maximum compatibility" mode can write both formats, matching current Rekordbox behavior.

Do not let legacy support delay the OMNIS-DUO MVP.

---

## 16. CLI specification

The CLI should be the canonical automation interface even if a GUI is later added.

Binary:

```bash
deckhand
```

### `deckhand playlists`

List Apple Music playlists.

```bash
deckhand playlists
```

Example:

```text
APPLE MUSIC PLAYLISTS

ID             TRACKS    NAME
p_001             184    House
p_002              92    Disco
p_003              71    Pool Party
p_004              26    New Stuff
p_005              48    Friday
```

### `deckhand devices`

List eligible mounted removable volumes.

```bash
deckhand devices
```

### `deckhand init`

Initialize a USB as a Deckhand-managed device.

```bash
deckhand init /Volumes/DJUSB
```

This command must clearly explain any destructive formatting behavior.

**Formatting should never happen implicitly.**

### `deckhand sync`

Interactive:

```bash
deckhand sync /Volumes/DJUSB
```

Explicit:

```bash
deckhand sync /Volumes/DJUSB \
  --playlist "House" \
  --playlist "Friday"
```

### `deckhand sync --dry-run`

Calculate and display the exact diff without writing.

```bash
deckhand sync /Volumes/DJUSB --dry-run
```

Example:

```text
Deckhand — DJUSB

PLAYLISTS
~ House
= Friday
+ New Stuff
- Pool Party

TRACKS
+ 7 new
- 2 orphaned
~ 1 changed
= 312 unchanged

ANALYSIS
7 tracks need analysis

COPY
742 MB

No changes written.
```

### `deckhand status`

```bash
deckhand status /Volumes/DJUSB
```

Displays:

- last successful sync;
- selected source playlists;
- number of tracks;
- database type/version;
- missing/corrupt files;
- pending changes.

### `deckhand validate`

```bash
deckhand validate /Volumes/DJUSB
```

Runs deeper structural validation.

### `deckhand eject`

```bash
deckhand eject /Volumes/DJUSB
```

Safely unmounts the drive.

### Useful global flags

```text
--json
--verbose
--quiet
--no-delete
--dry-run
```

`--json` is useful for a future GUI and scripting.

---

## 17. Minimal GUI

> Superseded by the Mac app in [mac-app.md](mac-app.md).

A GUI is not required to prove the product.

If/when added, keep it deliberately small.

```text
┌─────────────────────────────────────────┐
│ Deckhand                       ● DJUSB  │
│                                         │
│ Apple Music playlists                   │
│                                         │
│ ☑ House                         184     │
│ ☑ Disco                          92     │
│ ☐ Pool Party                     71     │
│ ☑ New Stuff                      26     │
│ ☑ Friday                         48     │
│                                         │
│ Changes                                 │
│ 7 new · 2 removed · 3 playlists        │
│                                         │
│             [ Sync USB ]                │
└─────────────────────────────────────────┘
```

Stack: SwiftUI (or a menu-bar app) built on the same Swift package as the CLI.

Do not duplicate sync logic in the GUI.

---

## 18. Recommended implementation architecture

A strong initial implementation would be:

A single Swift package with one target per subsystem (planned layout; the shipped package is shown after it):

```text
deckhand/
├── Package.swift
├── Sources/
│   ├── DeckhandCore/
│   │   ├── Model
│   │   ├── Diff
│   │   ├── Manifest
│   │   └── Errors
│   │
│   ├── MusicSource/
│   │   └── Apple Music adapter (iTunesLibrary.framework)
│   │
│   ├── Analysis/
│   │   ├── Probe
│   │   ├── Decode
│   │   ├── BPM
│   │   ├── Beatgrid
│   │   ├── Key
│   │   └── Waveform
│   │
│   ├── OneLibrary/
│   │   ├── Database
│   │   ├── AnalysisWriter
│   │   ├── Artwork
│   │   └── Validation
│   │
│   ├── Sync/
│   │   ├── Planner
│   │   ├── Copy
│   │   ├── Staging
│   │   └── Commit
│   │
│   └── deckhand-cli/
│
└── App/               # optional later (SwiftUI)
```

As built, `Package.swift` has these targets:

```text
Sources/
├── DeckhandCore/        shared model (tracks, analysis, keys, phrases, ratings backup)
├── MusicSource/         Apple Music via iTunesLibrary.framework; AppleScript writer
├── Analysis/            decoding, beat grid, key (libKeyFinder + S-KEY Core ML), cues, structure, waveforms
├── CQMDSP/              vendored qm-dsp (GPL)
├── CKeyFinder/          vendored libKeyFinder (GPL) with an Accelerate FFT backend
├── CSQLCipher/          system library: Homebrew sqlcipher
├── OneLibrary/          exportLibrary.db, ANLZ files, validation
├── Sync/                planner, executor, manifest, analysis cache, adopt, cleanup
├── deckhand/            CLI (swift-argument-parser)
├── DeckhandApp/         SwiftUI Mac app
├── EvalSupport/         eval-only: Mixed In Key reader and file-tag reader
└── deckhand-eval, deckhand-cue-eval, deckhand-structure-eval, deckhand-grid-eval/   eval tools
```

### Language decision

**Decision (October 7, 2026): start with Swift for everything.**

Rationale:

- v1 is macOS-only and Apple Music-centric, so most platform work is Apple APIs that Swift calls directly.
- One language and toolchain; no FFI layer; one thing to build, sign, and notarize.
- A future SwiftUI GUI shares the same package with no bridging.

Expected building blocks:

| Need | Swift option |
|---|---|
| Apple Music source | `iTunesLibrary.framework` (`ITLibrary`) |
| Audio decoding | `AVFoundation` (`AVAudioFile`) |
| DSP (FFT, onset, chroma) | `Accelerate` / vDSP |
| ML-based beat tracking | Core ML (e.g. converted Beat This! model) |
| `exportLibrary.db` | GRDB.swift with SQLCipher, or SQLCipher directly |
| Volume detection / eject | `DiskArbitration` |
| CLI | `swift-argument-parser` |
| GUI (later) | SwiftUI / menu-bar app |

**Use the best tool for the job.** Swift-everywhere is the starting point, not a rule. If any part of the system would be materially better in another language, use it — for example:

- **Python** for prototyping and evaluating BPM/beat/key algorithms against real tracks before porting the winner to Accelerate/Core ML;
- **Rust** for the binary format layer (ANLZ, OneLibrary) if Swift's binary-handling ergonomics become a real drag, if Windows becomes a goal, or if the format writer should be published as a reusable library;
- anything else that clearly wins for a specific subsystem.

Keep any non-Swift component behind a narrow boundary (the `DeviceExporter` protocol, a C/UniFFI interface, or a subprocess speaking JSON) so it can be replaced later without touching the rest of the app.

Watch licensing when choosing analysis libraries: many strong options (Essentia, aubio, libKeyFinder, qm-dsp) are GPL/AGPL, and madmom's models are non-commercial.

---

## 19. Safety and filesystem behavior

DJ USB corruption is unacceptable.

### Requirements

- Detect volume before modifying.
- Refuse internal/system drives.
- Never format without an explicit dedicated command and confirmation.
- Refuse read-only volumes.
- Check free space before sync.
- Stage databases before replacement.
- Keep previous database backup until successful commit.
- Flush writes before reporting success.
- Detect unexpectedly disconnected drives.
- Avoid leaving half-written library databases as canonical files.
- Preserve unrelated files by default.
- Only delete files that Deckhand owns or can prove are orphaned Deckhand-managed content.
- Store a Deckhand marker/manifest such as:

```text
/.deckhand/manifest.sqlite
```

or:

```text
/.deckhand/manifest.json
```

The manifest must not be required by the DJ player.

---

## 20. Sync ownership

Deckhand must decide what it owns.

Recommended v1 policy:

> A Deckhand-initialized drive contains a Deckhand-managed music namespace. Deckhand may update/delete files within its own managed paths but must leave unrelated user files untouched.

Example:

```text
/Contents/Deckhand/...
```

If OneLibrary requires a different conventional content path, track ownership in the manifest rather than assuming everything under `/Contents` belongs to Deckhand.

---

## 21. File naming

Avoid filesystem collisions and illegal characters.

Do not rely exclusively on:

```text
Artist/Album/Title.mp3
```

because duplicate titles and normalization issues will happen.

Possible scheme:

```text
/Contents/Deckhand/AB/CD/<stable-id>-Song Title.mp3
```

or a stable hash-based directory structure.

The user never needs to browse the USB filesystem manually; playlist metadata is the UI.

Keep names human-readable where possible, but prioritize:

- stable paths;
- cross-filesystem safety;
- deterministic output;
- compatibility.

---

## 22. Playlist semantics

Requirements:

- playlist name preserved;
- track ordering preserved;
- duplicate track occurrences preserved if the format supports/permits them;
- one source track referenced by multiple playlists without duplicate audio;
- playlist rename should not force recopy;
- track reorder should not force recopy;
- playlist deletion should only delete audio that becomes globally orphaned;
- playlist folder hierarchy should be preserved if OneLibrary supports the desired representation.

Smart playlists should initially be treated as their current resolved list of tracks, not reimplemented as rules.

---

## 23. Metadata precedence

Initial rule:

**Apple Music metadata is the user-facing source metadata.**

Analysis-derived fields supplement it.

Examples:

```text
Title       → Apple Music
Artist      → Apple Music
Album       → Apple Music
Genre       → Apple Music
Artwork     → Apple Music/file metadata where available
BPM         → Deckhand analysis unless explicitly imported
Key         → Deckhand analysis unless explicitly imported
Beat grid   → Deckhand analysis
Waveforms   → Deckhand analysis
```

Later versions could support precedence settings.

---

## 24. Error model

Errors should be actionable.

Bad:

```text
Error 42
```

Good:

```text
Could not sync "Song Name"

The Apple Music entry points to:
~/Music/Music/Media/Artist/Song.m4a

That file no longer exists.

Fix the track in Apple Music or remove it from the selected playlist.
```

Aggregate failures where possible rather than failing on the first bad track.

---

## 25. Logging

Default logs should answer:

- What did Deckhand think the source state was?
- What did it think the previous device state was?
- What changed?
- Which files were copied/deleted?
- Which tracks were analyzed?
- Which database version was written?
- Did validation pass?
- Was commit successful?

Avoid dumping sensitive path information into remote telemetry by default.

For early development, local structured logs are more important than SaaS telemetry.

---

## 26. Hardware-first technical spike

This should be the first implementation milestone.

**Do not start by building the GUI.**

Goal:

> Produce a USB from Deckhand-controlled code that an OMNIS-DUO can browse and play without Rekordbox ever touching the drive.

### Spike fixture

Use approximately 3 known local tracks:

```text
Playlist: Deckhand Test

1. Track A
2. Track B
3. Track C
```

Generate:

- copied audio;
- OneLibrary DB;
- playlist;
- required analysis paths/files;
- minimum required metadata.

### Hardware acceptance

On OMNIS-DUO:

- USB mounts;
- playlist appears;
- playlist has correct name;
- all three tracks appear;
- order is correct;
- tracks load;
- tracks play;
- BPM displays correctly;
- waveform renders;
- beat grid behaves plausibly;
- key displays if required;
- no "library not found" / re-analysis failure occurs.

Only after this passes should the project move to generalized syncing.

---

## 27. Development phases

### Phase 0 — Compatibility proof

Deliverable:

```text
known files → generated USB → OMNIS-DUO
```

No Apple Music integration required.

Success means a completely Rekordbox-free USB works on the target hardware.

### Phase 1 — Apple Music ingestion

Deliverable:

```text
deckhand playlists
```

and normalized source model.

### Phase 2 — Full rebuild sync

Deliverable:

```text
deckhand sync --rebuild
```

Selected playlists are recreated from scratch on a Deckhand USB.

No incremental optimization required yet.

### Phase 3 — Analysis pipeline

Generate production-quality BPM, beat grid, key, waveforms, and required ANLZ/OneLibrary data.

If Phase 0 uses fixture/precomputed analysis to de-risk the database first, replace it here with genuine analysis.

### Phase 4 — Incremental sync

Add manifests, file hashes, diff planning, orphan cleanup, and analysis cache.

### Phase 5 — Safety/validation

Atomic commits, interrupted-write handling, backup/rollback, structural validator, device validation suite.

### Phase 6 — Minimal GUI

Playlist checkboxes, diff preview, progress, sync button, eject.

### Phase 7 — Broader hardware compatibility

Legacy Device Library and dual-format USBs.

---

## 28. MVP acceptance criteria

The MVP is complete when all of the following are true.

### Apple Music

- Deckhand can enumerate playlists.
- Deckhand can resolve local tracks.
- Selected playlists can be stored as device sync configuration.
- Playlist order is maintained.
- Missing/protected tracks are clearly reported.

### USB

- A fresh Deckhand drive works without ever being opened in Rekordbox.
- OMNIS-DUO recognizes the library.
- Selected playlists are visible.
- Tracks load and play.
- Playlist ordering matches Apple Music.
- Track ordering matches Apple Music.

### Analysis and DJ metadata

- BPM is analyzed and available on the device.
- Beat grids are generated and usable.
- Waveforms display.
- Musical key is analyzed and available.
- Harmonic/alphanumeric key can be derived and displayed/exported as appropriate.
- Track color can be stored and exported.
- Rating and comments can be preserved/exported.
- My Tags can be represented/exported where supported by the target format.
- OMNIS-DUO track filtering works with the populated BPM/key/color/tag metadata where supported.
- Re-running sync does not reanalyze unchanged audio.

### Incremental sync

Given:

```text
House:
A
B
C
```

then source becomes:

```text
House:
C
A
D
```

the second sync should:

- copy D;
- preserve A and C;
- remove B only if no other synced playlist references B;
- update playlist membership/order;
- analyze D only;
- not recopy/reanalyze A or C.

### Reliability

- `--dry-run` performs no writes.
- Interrupted sync cannot silently leave a corrupt canonical database.
- Insufficient space is detected before copying.
- Missing files are reported before commit.
- A validation command can detect common inconsistencies.

---

## 29. Test strategy

### Unit tests

- source playlist normalization;
- track identity;
- hashes;
- filename normalization;
- diff planner;
- orphan detection;
- deterministic ID assignment;
- path generation;
- database serialization;
- analysis serialization.

### Golden fixtures

Maintain small known-good exports generated by current Rekordbox solely as compatibility fixtures.

Compare:

- schema;
- table relationships;
- expected paths;
- representative binary analysis sections.

Do not require byte-identical output if the hardware format permits semantically equivalent values.

### Round-trip tests

Deckhand-written DB → Deckhand parser → normalized model.

Where compatible third-party parsers exist:

Deckhand-written DB → independent parser.

### Hardware suite

At minimum:

1. OMNIS-DUO — required for v1.

Later:

2. XDJ-AZ
3. OPUS-QUAD
4. CDJ-3000X
5. CDJ-3000 via legacy exporter
6. XDJ-RX3 / XDJ-XZ where desired

Every release touching serialization should run hardware smoke tests before shipping when practical.

---

## 30. Open technical questions

These should be answered during Phase 0/1.

### OneLibrary

- What is the minimum valid `exportLibrary.db` content for OMNIS-DUO?
- Which auxiliary files are mandatory versus optional?
- Which waveform/analysis sections are required for full UI behavior?
- What values are device-generated or version-sensitive?
- Can the DB be cleanly rebuilt each sync or should it be updated incrementally?
- Which AlphaTheta library-version fields must track current firmware expectations?

### Analysis and tagging

- Which beat-analysis implementation gives acceptable DJ-quality grids?
- How should tempo ambiguity be handled (e.g. 70 vs 140 BPM)?
- Which key-analysis implementation is accurate enough for harmonic mixing?
- Should the default key display be Classic (`Am`) or Alphanumeric (`8A`)?
- Which curated metadata should Deckhand import from Apple Music?
- Should My Tags be v1 or immediately-following-v1 scope?
- Should color be manual-only initially, or support user-defined automatic rules?
- Do we need phrase analysis in v1? Probably no.
- How much of the current Pioneer ANLZ format is mandatory on OneLibrary-only hardware?
- What analysis can be omitted without degrading the core experience?

### Apple Music

- What is the most reliable stable identifier across file moves?
- How are playlist folders exposed through current macOS scripting APIs?
- Can all required metadata be read without foregrounding Music.app?
- What macOS permissions/prompts are required?

### USB

- Which filesystems should be officially supported?
- What are OMNIS-DUO limits for filesystem, capacity, filename/path length, and codec?
- Is a Deckhand-specific managed directory safe on all target hardware?
- How should manually-added files on a Deckhand USB be treated?

### Legal/licensing

- Which reverse-engineered references may be used as documentation versus incorporated code?
- Is an independent OneLibrary implementation preferable?
- Confirm trademark language and product disclaimer before public release.
- Do not incorporate unlicensed repository code without explicit permission.

---

## 31. Things we should deliberately avoid

- Building a giant music library UI.
- Importing the entire Apple Music library when only selected playlists are needed.
- Coupling source-library IDs directly to Pioneer IDs.
- Reanalyzing every track on every sync.
- Recopying tracks because their playlist moved.
- Assuming filesystem paths are identities.
- Modifying a USB before calculating the full plan.
- Deleting files that Deckhand cannot prove it owns.
- Making a GUI before proving hardware compatibility.
- Copying reverse-engineered source code with unclear licensing.
- Supporting every Pioneer device in v1.
- Requiring Rekordbox for "initialization," because that defeats the product.

---

## 32. Nice-to-have follow-ons

After the core workflow is reliable:

### More source libraries

- filesystem folders;
- Serato;
- Traktor;
- Rekordbox XML;
- Music XML;
- M3U/M3U8.

### More destinations

- legacy Pioneer Device Library;
- dual-format USB;
- Traktor USB/library export;
- generic M3U USB.

### DJ metadata

- hot cues;
- memory cues;
- loops;
- ratings;
- comments;
- My Tags;
- colors.

### Quality-of-life

- menu-bar mode;
- auto-detect inserted DJ USB;
- "Sync now" notification;
- automatic safe eject;
- multiple USB profiles;
- mirror two backup USBs;
- verify backup USBs are identical;
- source playlist presets.

---

## 33. Product positioning

Deckhand should remain easy to explain:

> **Your Apple Music playlists, ready for the decks.**

Alternative:

> **Sync Apple Music playlists directly to your DJ USB. No Rekordbox library required.**

The differentiation is not "another DJ library manager."

It is:

> **Don't manage two libraries.**

---

## 34. Working name

**Deckhand** is the recommended working name.

It fits the job of the product:

- the user organizes the music;
- Deckhand prepares it for the decks;
- the CLI commands read naturally.

Examples:

```bash
deckhand playlists
deckhand sync
deckhand status
deckhand validate
deckhand eject
```

Before public launch, perform normal trademark/domain/package-name diligence.

---

## 35. Recommended first developer task

Build the smallest possible proof:

```text
Three local tracks
      ↓
hard-coded playlist
      ↓
OneLibrary writer
      ↓
USB
      ↓
OMNIS-DUO
```

No Apple Music.

No GUI.

No incremental sync.

No library editor.

The first question to answer is binary:

> **Can Deckhand independently create a USB that the OMNIS-DUO recognizes, browses, and plays correctly?**

Once the answer is yes, the rest of the product can be built around that proven compatibility layer.

---

## 36. Definition of the product

Deckhand is not a DJ application.

Deckhand is not a Rekordbox clone.

Deckhand is a **compiler for DJ USBs**:

```text
Apple Music playlists
        +
local audio
        ↓
      Deckhand
        ↓
DJ-player-compatible USB
```

That conceptual model should guide architecture and scope decisions throughout development.
