# Track tools and analysis action

Implemented October 11, 2026.

The main-panel analysis banner was restricted to the Needs Analysis sidebar selection. It now appears whenever the library has unanalyzed tracks and no job is running, including when browsing a playlist. Its text explicitly describes the whole library, and Analyze Library retains the existing background analysis command. The banner disappears after successful analysis or while a job is running.

Quick Rate and search now sit with the filter controls, aligned along their bottom edge. The title and track summary remain on the row above. A small SwiftUI layout wraps Quick Rate/search onto a second row when the column is too narrow, keeping one search field and its focus/Command+F shortcut intact.

## Native verification

Used Deckhand Tools QA with a copied two-track fixture library and a fresh, isolated analysis cache. The regular app was closed during testing.

- Banner/action visible in All Tracks, Friday, and Needs Analysis.
- Quick Rate and search aligned with filters in a normal-width window.
- Command+F focused the relocated search; searching Warmup showed one of two tracks. Escape restored the list.
- Clicking Analyze Library completed in three seconds; Needs Analysis became zero, waveform/key/tempo appeared, and the banner disappeared.
- Resizing the window narrower wrapped the controls into two rows without overlap.
- Build and code signature verification passed. No real library analysis or USB sync was performed. The regular app was reopened after testing.

Evidence: [playlist analysis action and aligned tools](../images/library-evidence/47-playlist-tools-analysis.png), [narrow layout after successful analysis](../images/library-evidence/48-tools-narrow-analysis-complete.png), [build log](validation-evidence/track-tools-build.log).

After reopening the regular app, [this screenshot](../images/library-evidence/49-regular-library-tools-analysis.png) confirms its eight remaining unanalyzed tracks have the main-panel action and the relocated controls align with filters.
