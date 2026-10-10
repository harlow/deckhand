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
  submenu, or ⌥0–⌥5) to set them in Music. The list and the sync dot change at once; Music's answer, read
  back after the write, replaces it, and an error (no Automation access, Music not answering, track not
  found) is shown rather than ignored. Sync writes ratings to the drive, and a rating or title change alone is
  enough to rewrite the drive's database.
- **Drag and drop:** drag tracks (or the whole selection) onto a sidebar playlist to add them in Apple Music,
  skipping tracks it already has; or onto Up Next to queue them.
- **Analysis banner:** when tracks aren't analyzed, Analyze Library runs `deckhand analyze` and reloads
  the results when it finishes.
- **Sync:** the toolbar shows the chosen drive's pending changes and a Sync button (blue only when something
  is pending), which runs `deckhand sync <drive> -y --analyze --require-live` in the background once any
  ratings still being written have reached Music. Progress (and Cancel) appears at the top of the right-hand
  pane. Afterwards the drive shows up to date at once if the sync said so; the app then reads Music and the
  drive again, and if anything is still pending a note above the track list says what (with Sync Again).
  See [Sync status](#sync-status) below.

![Deckhand keyboard shortcuts](images/keyboard-shortcuts.png)

### Keyboard (track list)

| Keys | Action |
|---|---|
| j / k or ↓ / ↑ | Move (J / K extend the selection) |
| ⌘⇧] / ⌘⇧[ | Next / previous playlist in the sidebar (works anywhere in the window) |
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
library of ~2,000 tracks. Drive reads run off the main thread (USB manifests can take seconds), and so do
status evaluations and every Apple Event.

View → Show Console (⌥⌘C) logs slow steps, freezes over 250 ms, actions and job output. The same log goes
to the system log: `/usr/bin/log show --predicate 'subsystem == "rocks.deckhand.app"'`.

### Sync status

Every dot, playlist badge, "N to sync", byte count, "won't fit" and the Sync button's colour come from one value:
the engine's `SyncStatus.evaluate` (through `SyncPlanner.evaluate`, exactly as `deckhand status` and `deckhand
sync` decide), run off the main thread on the app's library, the drive's manifest and files, and the drive's
saved settings. `DeckhandAppCore` holds the parts that don't need a UI, and its tests cover the races below.

- **Facts without hashing.** The app never hashes to evaluate: audio its background analysis load hasn't hashed
  yet is *unknown*, shown as neither synced nor pending, and the evaluation runs again as hashes arrive. Until the
  first evaluation lands the drive shows "Checking…". Retained, failed and ineligible tracks show as the engine
  sees them (hover the dot for why).
- **Ordering.** Evaluations can finish out of order; the newest one issued wins (`StatusStore`). Drive reads
  carry sequence tokens (`ReadLedger`), so a slow read never overwrites a newer one or a selection edit the app
  just saved.
- **After a sync.** The CLI's last line, `@result {...}`, says whether its own self-check was clean. If so the app
  shows the drive clean at once; evaluations begun before the sync ended are dropped. Then it reads Music and the
  drive again and evaluates ("verification"); that replaces the optimistic status, and if anything is still
  pending (and nothing was edited during the sync) a note above the track list lists it. The same lines go to the
  Console.
- **Music's live data.** iTunesLibrary reads a copy of the library that Music's agent updates in batches; it
  trails edits by seconds, and some records stay stale indefinitely (Music back-fills comments and genres from
  file tags without passing them on). So every field the drive's database takes from Music (title, artist,
  album, album artist, genre, track/disc number, year, rating, comment) is read live with raw Apple Events
  (~250 ms for 2,000 tracks) and laid over the snapshot, normalized like iTunesLibrary's values so an unchanged
  track compares equal. Dates and file locations always come from the snapshot (Apple Events report some dates
  an hour off, and paths in another Unicode form). `deckhand sync` and `status` read the library the same way,
  so the app and the CLI see the same data. `deckhand debug music-live` lists where the snapshot and Music differ.
- **Ratings.** Set in the app, a rating shows at once (`RatingOverlay`). `MusicBridge` writes it — coalesced per
  track, the last one wins — then reads it back; the row takes Music's value. A library read that ran before the
  write can't put the old rating back (reads and writes carry the bridge's sequence numbers), and Sync waits for
  queued ratings first.
- **Reloads.** The library is read again when Music's agent posts `com.apple.AMPLibraryAgent.libraryChanged`
  (debounced), a few seconds after the app's own writes, after every sync, and when the app becomes active.
- **Access.** At launch the app checks whether it may control Music (`AEDeterminePermissionToAutomateTarget`)
  and asks once if it hasn't. If Music is running but can't be read (access refused, no answer), a banner says
  the list and status may trail recent edits, with Open Settings for Automation. If Music isn't running, the
  snapshot is current (nothing is waiting to reach it) and no banner shows. The app's Sync passes
  `--require-live`: if Music can't be read then, the CLI stops before writing and prints `@live {...}`, and the
  app offers **Sync Anyway (May Be Stale)**, which syncs from the snapshot.
- **Selection edits** (adding or removing playlists, All Tracks) show at once and are saved with `Manifest.edit`;
  the view then takes what was saved. During the app's own sync they wait and are saved when it finishes; if
  another Deckhand is syncing the drive, the edit is undone with an explanation.

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
  - **Reading:** the iTunesLibrary framework (`AppleMusicLibrary`), with Music's live values laid over it
    (`MusicLive`, below). iTunesLibrary is read-only and only returns data to a code-signed app.
  - **Writing:** ratings as raw Apple Events (`MusicEvents`); playlists and adding and removing tracks with
    Music's AppleScript (`AppleMusicWriter`, also used by `import-playlists`), slow for bulk edits but fine for
    one-off changes. In the app all of it, reads included, goes through `MusicBridge`'s one serial queue.
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
