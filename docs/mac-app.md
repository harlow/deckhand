# Deckhand Mac app

A native Mac app for browsing the library with everything Apple Music doesn't show (key, energy, cues,
waveforms, sync state) and for syncing drives. The first half of this page describes what's built; the
rest is the design for what comes next.

## Build and run

`Sources/DeckhandApp` (SwiftUI, macOS 14+):

```sh
Scripts/build-app.sh          # or `Scripts/build-app.sh debug`; writes build/Deckhand.app (ad-hoc signed)
open build/Deckhand.app
```

The bundle contains the `deckhand` CLI next to the app, which the app runs for analyzing and syncing.
The app must be code-signed (ad-hoc is enough), because the iTunesLibrary framework only returns data
to signed apps.

App icon: the "Platter" mark, drawn by `Scripts/make-icon.swift` at build time. `PlatterMark` in
`Components.swift` draws the same mark in SwiftUI; its one-color version sits next to the window title.

## What works

- **Sidebar:** All Tracks and Needs Analysis; Apple Music playlists (folders indented) with sync badges
  for the chosen drive; new playlist (created in Music); and mounted drives with space and last sync
  (click to choose, eject). The chosen drive and playlist are remembered.
- **Track table:** sortable columns: sync dot, title/artist, three-band waveform overview (click to preview
  from that point), BPM, Camelot key chip, energy bar, genre, time. Search covers title, artist, genre or a
  key like `8A`.
- **Filters:** Camelot key wheel (with "Mixes with playing" and "Energy boost" presets), BPM range,
  minimum energy, minimum rating, genres, and "Mixes with now playing".
- **Playback:** a player bar with a detailed waveform, phrase strip and hot cues A–H (click to seek or jump),
  and an Up Next queue showing transition notes and "Mixes well next" suggestions.
- **Context menu:** Play, Play Next, Add to Up Next, Add to Playlist (via Music), Rating, Show in Finder,
  Remove from Playlist.
- **Star ratings:** shared with Apple Music in both directions. Click stars in the list (or use the Rating
  submenu) to set them in Music; the app re-reads Music when it becomes active. Sync writes ratings to the
  drive, and a rating or title change alone is enough to rewrite the drive's database.
- **Drag and drop:** drag tracks (or the whole selection) onto a sidebar playlist to add them in Apple Music,
  skipping tracks it already has; or onto Up Next to queue them.
- **Analysis banner:** when tracks aren't analyzed, Analyze Library runs `deckhand analyze` and reloads
  the results when it finishes.
- **Sync:** the toolbar shows the chosen drive's pending changes and a Sync button, which runs
  `deckhand sync <drive> -y --analyze` in the background. Progress (and Cancel) appears at the top of the
  right-hand pane.

![Deckhand keyboard shortcuts](images/keyboard-shortcuts.png)

### Keyboard (track list)

| Keys | Action |
|---|---|
| j / k or ↓ / ↑ | Move (J / K extend the selection) |
| ⌘↑ / ⌘↓ | Top / bottom |
| Return / ⇧Return | Play / play from Mix In |
| l (or p) | Preview from just before the first drop |
| Space | Play / pause |
| q / ⇧Q | Add to Up Next / play next |
| ⇧P | Add to playlist (picker: recent playlists first; j/k or ↑↓ move, Space adds or removes and stays open, Return adds and closes, / filters) |
| ⌘→ / ⌘← | Next / previous track |
| 1–8 | Hot cues A–H |
| `,` / `.` | Back / forward 4 beats |
| `<` / `>` | Back / forward 16 beats |
| `[` / `]` | Previous / next section |
| ⌥1–⌥5, ⌥0 | Rate, clear rating |
| m | Toggle "Mixes with now playing" |
| / | Search |
| ⌘L | Show the playing track |
| Delete | Remove from playlist |
| r | Quick Rate |
| ? | Cheat sheet |

### Quick Rate

`r`, or the button by search. Plays the listed tracks that have no rating (current playlist plus
filters), best guesses first, each from 16 beats before its first drop.

- `⌥1`–`⌥5` rate the track and move straight on (the same keys as the track list; plain `1`–`8` jump to
  hot cues).
- `j` moves on without rating and hides the track from Quick Rate for 30 days (kept in Deckhand's
  preferences; nothing is written to Music). `k` goes back to the previous track.
- `g` toggles groove order (on by default): each next track is the queued one that mixes best with the one
  just rated (compatible key, tempo within pitch range, same genre).
- `o` switches between best guesses first and shuffled.
- `⇧P` adds the track to playlists; `,` `.` `[` `]` move within the track; `l` replays the preview;
  Escape ends the session.

The right column shows the session's tally and what's coming up.

**Best guesses first** orders tracks by how likely you are to rate them 4★ or more, with the reason
shown under the title. The score adds up simple signals learned from the tracks you've already rated:
Music's play and skip counts, how you rate that artist and genre, the energy and tempo bands you rate
highly, and membership of playlists full of tracks you like (`Suggestions.swift`).

### Ratings backup

Apple Music keeps star ratings only in its library database, not in the audio files. Deckhand saves them
all to `~/Library/Application Support/Deckhand/Ratings/` (`ratings-latest.json` plus one dated copy per
day, kept 60 days) at launch and after each Quick Rate session, only when they've changed.

- `deckhand ratings backup` saves them by hand.
- `deckhand ratings restore [file] [--dry-run] [--overwrite]` puts them back, matching by library ID,
  then file path, then title + artist + length (so it works on a rebuilt library). By default it only
  fills in unrated tracks; `--overwrite` also replaces ratings that differ.

### Performance and diagnostics

The track list is an `NSTableView` (`TrackTable.swift`) with fixed-height rows and SwiftUI cells hosted
only for visible rows; SwiftUI's `Table` measured every row up front and froze for over a minute on a
library of ~2,000 tracks. Drive reads run off the main thread (USB manifests can take seconds).

View → Show Console (⌥⌘C) logs slow steps, freezes over 250 ms, actions and job output. The same log goes
to the system log: `/usr/bin/log show --predicate 'subsystem == "rocks.deckhand.app"'`.

### Not built yet

- Editing analysis (BPM/key/grid/cues), smart crates, play history, set planner, library health.
- Genre families in the filter and an optional family-on-drive setting; see [genres.md](genres.md).
- In-app drive setup: a drive whose playlists were never chosen needs one `deckhand sync <drive>` in
  Terminal first.

## Design: screens

The target design. Much of it is built (see above); the rest is planned.

### Library window

- **Toolbar:** search (title, artist, label, or a key like `8A`), a drive pill showing pending changes
  ("DJUSB · 2 changes"), and **Sync**.
- **Sidebar:**
  - Library: All Tracks, Recently Added, Needs Analysis.
  - Playlists, with **+** to add one. Each has a sync badge: green check (up to date on the drive), orange
    count (changes waiting), or dashed circle (not on any drive).
  - Smart Crates (saved filters, see below).
  - Drives: used space, player model, last sync, eject.
- **Playlist header:** track count, length, "40 on DJUSB · 2 waiting to sync", Play and Shuffle Preview.
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

### Key filter popover

A Camelot wheel: minor keys (A) on the inner ring, major keys (B) on the outer. Click keys to select them.
- **Presets:** Mixes with the playing key, Energy boost (+2), Same key only.
- **Pitch option:** also match keys reached by pitching ±6% with Key Lock off.

### Sync sheet

- **What will change:** tracks to copy (with size), tracks to analyze first, playlists to update, removals,
  and new play-history sessions found on the deck (kept).
- **Space:** a bar showing the drive's space after the sync.
- **Settings:** a summary of the drive's saved output settings (cues, hot-cue style, build lead, key format,
  track colour, phrases), with Edit.
- **Options:** "Sync automatically when DJUSB is plugged in" and "Eject when done".

## More features

In rough priority order:

1. **Fixing analysis by hand.** Deckhand's analysis is the only source of key, BPM and cues, so it has to
   be correctable: halve or double the BPM, nudge the downbeat, override the key, and move, add or delete
   cues. Overrides would be stored in Deckhand's cache by audio hash, survive re-analysis, and be flagged
   in the UI.
2. **Smart crates.** Saved filter sets (key, BPM, energy, genre, date added) that update themselves and
   sync to the drive like playlists.
3. **Played on deck.** Read the play history the player writes to the drive (sync already keeps it) and
   turn each gig into a "Played at …" playlist in Apple Music.
4. **Set planner.** A playlist mode that plots key and energy track by track and flags key clashes,
   tempo jumps and energy dips.
5. **Library health.** Duplicates, missing files, DRM tracks that can't sync, and failed analyses.
6. **Auto-sync on plug-in** (opt-in, per drive), with a notification when it's done.

Deferred: importing grids, cues and keys from an existing Rekordbox library, so Rekordbox users keep cues
they placed by hand. It needs a reader for Rekordbox's `master.db` or `rekordbox.xml`.

## Architecture

- **Apple Music stays the source of truth** for files, playlists, ratings and play counts.
  - **Reading:** the iTunesLibrary framework (`AppleMusicLibrary`). It is read-only and only returns data
    to a code-signed app.
  - **Writing** (playlists, adding and removing tracks, ratings): Music's AppleScript
    (`AppleMusicWriter`, also used by `import-playlists`). It's slow for bulk edits but fine for one-off
    changes.
- **Deckhand's cache** holds everything Music can't: key, energy, beat grid, cues, sections/phrases and
  waveforms (peak/RMS and three bands). The app reads what `deckhand analyze` produces.
- **Stack:** a SwiftUI app target in this package, built on the `Sync` library (and through it
  `Analysis`, `MusicSource` and `OneLibrary`). Sync logic stays in the libraries and the CLI; the app runs
  the bundled `deckhand` CLI for analyze and sync and reads its machine-readable progress
  (`DECKHAND_PROGRESS=1`). Playback uses AVFoundation; waveforms are drawn from the cached waveform data.

## References

- Lexicon library manager: [walkthrough](https://wearecrossfader.co.uk/blog/lexicon-music-management-for-djs/),
  [smartlists](https://rekord.cloud/blog/lexicon-smart-playlists),
  [MusicTech](https://musictech.com/news/gear/dj-library-management-lexicon/)
- In-list waveform preview requests modelled on Rekordbox:
  [NI forum](https://community.native-instruments.com/discussion/585/feature-request-add-waveform-previews-with-hotcues-in-browser),
  [preview player](https://community.native-instruments.com/discussion/693/preview-player-improvements)
- [Apple ITLibrary](https://developer.apple.com/documentation/ituneslibrary/itlibrary);
  [iTunesLibrary on macOS 15.1](https://developer.apple.com/forums/thread/768006)
- [Doug's Scripts: Music playlist scripting](https://dougscripts.com/itunes/pdf/mxplaylistmanager.pdf)
