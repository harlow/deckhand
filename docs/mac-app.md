# Deckhand Mac app: design concept (2026-10-09)

A native Mac app for browsing the library with everything Apple Music doesn't show (key, energy, cues,
waveforms, sync state) and for syncing drives. It replaces the minimal GUI in the product spec (§17).

The mockups are on a design canvas: [Deckhand Mac App](https://claude.ai/artifact/XzWMPo11zcRYuqGjukFSNR).
The link is private until it's shared from the canvas's Share menu. Track names and numbers in the mockups
are placeholders.

## First pass (2026-10-09)

`Sources/DeckhandApp` (SwiftUI, macOS 14+). Build and launch:

```sh
Scripts/build-app.sh          # or `Scripts/build-app.sh debug`; writes build/Deckhand.app (ad-hoc signed)
open build/Deckhand.app
```

The bundle contains the `deckhand` CLI next to the app, which the app runs for analyzing and syncing.

App icon: the "Platter" mark (logo concept 1 on the design canvas), drawn by `Scripts/make-icon.swift` at build
time. `PlatterMark` in `Components.swift` draws the same mark in SwiftUI; its one-color version sits next to the
window title.

**Works:**
- **Sidebar:** Apple Music playlists (folders indented) with sync badges for the chosen drive, new playlist
  (via Music), and mounted drives with space and last sync (click to choose, eject). The chosen drive and
  playlist are remembered.
- **Track table:** sortable columns: sync dot, title/artist, three-band waveform overview (click to preview
  from that point), BPM, Camelot key chip, energy bar, genre, time. Search covers title, artist, genre or a
  key like `8A`.
- **Filters:** Camelot key wheel, BPM range, minimum energy, genres, and "Mixes with now playing".
- **Playback:** a player bar with a detailed waveform, phrase strip and hot cues A–H (click to seek or jump),
  and an Up Next queue showing transition notes and "Mixes well next" suggestions.
- **Context menu:** Play, Play Next, Add to Up Next, Add to Playlist (via Music), Show in Finder.
- **Star ratings:** shared with Apple Music in both directions. Click stars in the list (or use the Rating
  submenu) to set them in Music; the app re-reads Music when it becomes active. There's a minimum-rating filter.
  Sync writes ratings to the drive, and rating or title changes alone now trigger a database rewrite.
- **Drag and drop:** drag tracks (or the whole selection) onto a sidebar playlist to add them in Apple Music,
  skipping tracks it already has; or onto Up Next to queue them.
- **Analysis banner:** runs `deckhand analyze` and reloads results when it finishes.
- **Sync sheet:** runs `deckhand sync <drive> --dry-run`, then `deckhand sync <drive> -y --analyze`, showing
  the output.

![Deckhand keyboard shortcuts](images/keyboard-shortcuts.png)

**Keyboard (track list):** j/k or ↓/↑ move (J/K extend), ⌘↑/⌘↓ top/bottom, Return plays, ⇧Return plays from
Mix In, l (or p) previews from just before the first drop, Space play/pause, q/⇧Q queue/play next, ⇧P add to playlist (picker: recent playlists first, j/k or ↑↓ move, Space adds or takes out and stays open, Return adds and closes, / filters), ⌘→/⌘← next/previous, 1–8 hot cues A–H, `,`/`.` ∓4 beats, `<`/`>`
∓16 beats, `[`/`]` sections, ⌥1–⌥5/⌥0 rating, m "Mixes with now playing", `/` search, ⌘L show playing, Delete
remove from playlist, `r` Quick Rate, `?` cheat sheet.

**Quick Rate** (`r`, or the button by search): plays the listed tracks that have no rating (current
playlist plus filters), best guesses first (below), each from 16 beats before its first drop. `⌥1`–`⌥5` rate it and
move straight on (the same keys as the track list; plain `1`–`8` jump to hot cues, as there). `j` moves on without rating and hides
the track from Quick Rate for 30 days (kept in Deckhand's preferences, nothing written to Music); `k` goes
back to the previous track to change it. `g` toggles groove order (on by default): each next track is the queued one that mixes best with the one just rated (compatible key, tempo within pitch range, same genre). `⇧P` adds it to playlists (the same picker as the track list). `,` `.` `[` `]` move within the track, `l` replays the preview,
Escape ends it. `o` switches between best guesses first and shuffled. The right column shows the session's tally and what's coming up.

**Ratings backup:** Apple Music keeps star ratings only in its library database, not in the audio files.
Deckhand saves them all to `~/Library/Application Support/Deckhand/Ratings/` (`ratings-latest.json` plus a
dated copy per day, kept 60 days) at launch and after each Quick Rate session, only when they've changed.
`deckhand ratings backup` does it by hand; `deckhand ratings restore [file] [--dry-run] [--overwrite]` puts
them back, matching by library ID, then file path, then title + artist + length (so it works on a rebuilt
library), and by default only fills in unrated tracks.

**Best guesses first:** Quick Rate plays tracks in order of how likely you are to rate them 4★+, with
the reason shown under the title. The score adds up simple signals, learned from the tracks you've already
rated: Music's play and skip counts, how you rate that artist and genre, energy and tempo bands you rate
highly, and membership of playlists full of tracks you like (`Suggestions.swift`). `o` switches to
shuffled. (This was briefly a "Suggestions" sidebar list; tracks vanishing from it as they were rated felt
wrong, so the ranking now just orders Quick Rate.)

**Performance notes:** the track list is an `NSTableView` (`TrackTable.swift`) with fixed-height rows and SwiftUI
cells hosted only for visible rows. SwiftUI's `Table` measured every row up front and froze for ~70 s on All
Tracks (2,164 rows). Drive reads run off the main thread (USB manifests can take seconds). View → Show Console
(⌥⌘C) logs slow steps, freezes over 250 ms, actions and job output; it also goes to the system log
(`/usr/bin/log show --predicate 'subsystem == "com.deckhand.app"'`).

**Not yet:**
- Editing analysis (BPM/key/grid/cues), smart crates, play history, set planner, library health.
- Genre families in the filter and an optional family-on-drive setting; see `docs/genres.md` for the proposed
  grouping. Genre clean-up and suggestions for untagged tracks come later.
- In-app drive setup: a drive whose playlists were never chosen needs one `deckhand sync` in Terminal.
- Sync and analyze progress are shown as raw CLI output rather than native progress UI.

## Screens

### 1. Library window

- **Toolbar:** search (title, artist, label, or a key like `8A`), a drive pill showing pending changes
  ("RATS · 2 changes"), and **Sync**.
- **Sidebar:**
  - Library: All Tracks, Recently Added, Needs Analysis.
  - Playlists, with **+** to add one. Each has a sync badge: green check (up to date on the drive), orange
    count (changes waiting), or dashed circle (not on any drive).
  - Smart Crates (saved filters, see below).
  - Drives: used space, player model, last sync, eject.
- **Playlist header:** track count, length, "40 on RATS · 2 waiting to sync", Play and Shuffle Preview.
- **Filter chips:** Key (opens the key wheel), BPM range, Energy, Genre, and **Mixes with now playing**
  (keys within one Camelot step or the relative major/minor, and BPM within pitch range).
- **Track table:** each row has a sync dot, artwork, title/artist, a waveform overview, BPM, a coloured
  Camelot key chip, a 10-segment energy bar, genre and time.
  - The waveform overview is three-band coloured, like Rekordbox, with the detected cue positions as ticks.
    Clicking it previews the track from that point, with a playhead.
  - A track being analyzed shows a progress bar instead of a waveform.
- **Player bar:** a large waveform with hot cues A–H and a phrase strip (Intro / Build / Drop / Break /
  Outro, from song structure), plus transport controls and time.
- **Up Next:** the queue, with a note on each transition ("9A → 10A · +1 BPM · energy ↑", or a "key
  clash" warning) and suggested next tracks scored on key, tempo and energy.

### 2. Key filter popover

A Camelot wheel: minor keys (A) on the inner ring, major keys (B) on the outer. Click keys to select them.
- **Presets:** Mixes with the playing key, Energy boost (+2), Same key only.
- **Pitch option:** also match keys reached by pitching ±6% with Key Lock off.

### 3. Sync sheet

- **What will change:** tracks to copy (with size), tracks to analyze first, playlists to update, removals,
  and new play-history sessions found on the deck (kept).
- **Space:** a bar showing the drive's space after the sync.
- **Settings:** a summary of the drive's saved output settings (cues, hot-cue style, build lead, key format,
  track colour, phrases), with Edit.
- **Options:** "Sync automatically when RATS is plugged in" and "Eject when done".

## More features

In rough priority order:

1. **Fixing analysis by hand.** Deckhand's analysis is now the only source of key/BPM/cues (MIK input was
   removed), so it has to be correctable: halve or double the BPM, nudge the downbeat, override the key,
   and move, add or delete cues.
   - Overrides are stored in Deckhand's cache by audio hash, survive re-analysis, and are flagged in the UI.
2. **Smart crates.** Saved filter sets (key, BPM, energy, genre, date added) that update themselves and
   sync to the drive like playlists. Lexicon's smartlists are a main reason DJs use it.
3. **Played on deck.** Read the play history the OMNIS-DUO writes to the stick (sync already keeps it)
   and turn each gig into a "Played at …" playlist in Apple Music.
4. **Set planner.** A playlist mode that plots key and energy track by track and flags key clashes,
   tempo jumps and energy dips.
5. **Library health.** Duplicates, missing files, DRM tracks that can't sync, and failed analyses.
6. **Keyboard-first browsing.** Space to preview, arrow keys to move, number keys to jump to hot cues while
   previewing, and ⌥↩ to queue. DJs say in-list preview is the feature they miss most outside Rekordbox.
7. **Auto-sync on plug-in** (opt-in, per drive), with a notification when it's done.

Deferred: importing grids, cues and keys from an existing Rekordbox library (discussed 2026-10-09). It
would let Rekordbox users keep cues they placed by hand. It needs a reader for Rekordbox's master.db or
`rekordbox.xml`.

## Architecture

- **Apple Music stays the source of truth** for files, playlists, ratings and the play-count history it
  shares with the phone.
  - **Reading:** the iTunesLibrary framework (`AppleMusicLibrary`). It is read-only and only returns data
    to a code-signed app, so the app bundle must be signed.
  - **Writing playlists:** Music's AppleScript (`AppleMusicWriter`, already used by `import-playlists`):
    create a playlist and duplicate tracks into it. It's slow for bulk edits but fine for one-off changes.
- **Deckhand's cache** holds everything Music can't: key, energy, beat grid, cues, sections/phrases,
  waveforms (peak/RMS and three bands), and future manual fixes. The UI mostly reads data that `deckhand
  analyze` already produces.
- **Stack:** a SwiftUI app target in this package, built on the `Sync`, `Analysis` and `MusicSource`
  libraries. Sync logic stays in the libraries; the CLI and the app call the same code.
  - Layout: sidebar layout and a sortable table.
  - Waveforms: drawn from the cached waveform data.
  - Preview and playback: AVFoundation.
  - Progress: `SyncExecutor` events.
- **Risk to check first:** there's a report of the iTunesLibrary framework failing to load on macOS 15.1.
  Build a signed hello-world that loads the library on current macOS before anything else.

## References

- Lexicon library manager: [walkthrough](https://wearecrossfader.co.uk/blog/lexicon-music-management-for-djs/),
  [smartlists](https://rekord.cloud/blog/lexicon-smart-playlists),
  [MusicTech](https://musictech.com/news/gear/dj-library-management-lexicon/)
- In-list waveform preview requests modelled on Rekordbox:
  [NI forum](https://community.native-instruments.com/discussion/585/feature-request-add-waveform-previews-with-hotcues-in-browser),
  [preview player](https://community.native-instruments.com/discussion/693/preview-player-improvements)
- [Apple ITLibrary](https://developer.apple.com/documentation/ituneslibrary/itlibrary.md);
  [iTunesLibrary on macOS 15.1](https://developer.apple.com/forums/thread/768006)
- [Doug's Scripts: Music playlist scripting](https://dougscripts.com/itunes/pdf/mxplaylistmanager.pdf)
