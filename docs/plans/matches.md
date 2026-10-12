# Matches

Press **M**, or right-click a song and choose **Find Matches**, to open a temporary list in the middle pane. The selected song is the seed; when nothing is selected, use the playing song. The seed stays pinned above the scrolling table. Playing another song does not change it. Pressing M again explicitly chooses a new seed and retains the original return state.

The list contains up to **50** recommendations across the entire Deckhand library, independent of the original playlist and filters. Results rank by compatible Camelot keys, tempo distance, energy, genre and artist. This is metadata-based matching, not acoustic similarity. Unavailable files, the seed, duplicate paths/hashes and extreme tempo mismatches are excluded. Unanalyzed tracks can still qualify through genre or artist. An empty result explains that analysis or more music can help.

Quiet category filters select **Smooth**, **Lift**, or **Change Direction** from the same ranked results. Smooth favors compatible keys and nearby tempos, with similar energy when known; Lift adds energy; Change Direction has a genre/artist connection or a less direct transition. Each result includes its category and matching evidence under the title. Original filters and sort are saved separately; Matches initially uses ranking order.

Use **J/K** or arrow keys to browse, **Enter** to play, **L** to start the selected match's pre-drop preview, **Space** to pause, and the existing cue, bar-jump and rating controls. Playback continues through the captured match list, honoring the explicit Up Next queue first. The seed's play button plays it followed by the visible matches. Returning to the library does not stop the music.

**A** adds selected results directly to the leaf playlist where Matches started, with duplicate skipping and a saved/already-present notice. From All Tracks, Needs Analysis or a folder, A opens the existing playlist picker. Dragging results onto sidebar playlists also works. Matches never creates a playlist automatically. Delete cannot remove recommendations from the originating playlist. Saved additions persist in SQLite and stage USB changes through the usual flow; no automatic sync occurs.

**Esc**, the back arrow, or a sidebar selection leaves Matches. Back/Esc restore the original sidebar item, search, filters, sort and selected songs. Editors, help, menus and sheets keep their normal Escape behavior. Quick Rate remains a separate mode. Matches is ephemeral and does not reopen after app restart.

## Validation

Pure ranking tests cover the 50-result limit, deterministic ordering, groups and explanations, incomplete/invalid analysis, unrelated tracks, unavailable files and path/hash duplicates. Real audio/cache/SQLite integration tests cover a 62-track library, playback without seed drift, deduplicated direct adds, reseeding, view restoration, sidebar exit, no implicit destination from All Tracks, persistence and absence of Matches after restart. AppKit tests cover M dispatch from the table and other controls, typing protection, and Escape priority.

Native QA used a separate 62-track library and generated WAVs, running only the Applications app. M opened 50 matches for Seed Song; J/Enter and L auditioned different results while the seed stayed pinned. A added Match 60 and Match 25 to My Set; a repeated A skipped the duplicate. All Tracks → M → A opened the picker, and J/Enter added Match 30 to Other Set. Restart showed My Set with 3 tracks and Other Set with 1. Escape returned with Seed Song selected. The shortcut overlay included M and Escape. The regular library and preferences were restored afterward: 2,175 tracks, Disco Pool Party 28, Mixed in Bongoloco 51.

- [Pinned seed and 50 results while Match 60 is selected/playing](../images/matches/pinned-seed.jpg)
- [All Tracks playlist picker](../images/matches/playlist-picker.jpg)
- [281 regression tests in 54 suites passed](validation-evidence/matches-regression-tests.log)
- [Separate 20,000-track scale benchmark passed; clean evaluation 1.668 seconds](validation-evidence/matches-scale-tests.log)
- [23 focused tests in 5 suites passed against final source](validation-evidence/matches-focused-tests.log)

The combined all-suite runs failed only the existing wall-clock scale threshold under contention (4.395 and 5.773 seconds versus 3). The complete functional suite and the benchmark were therefore verified separately; no timeout or benchmark threshold was weakened. The final standalone release build passed signature, runtime/resource and dependency checks (Apple Silicon, macOS 26+, system libraries only).
