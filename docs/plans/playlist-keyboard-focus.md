# Playlist keyboard focus

Click a playlist to focus its tracks; clicking it again also returns focus. The existing
Command-Shift bracket shortcuts switch playlists and focus tracks. Plain brackets retain
playback section navigation. Tab moves from the sidebar to tracks, and Shift-Tab returns to
the sidebar so arrows can choose another playlist. Search keeps normal text input.

Focus requests are applied by the native table after its rows and selection have updated.
An existing visible track selection is retained; when no selected track remains, the first
row is selected. Empty lists still accept keyboard focus. USB checkboxes keep their existing actions.

Native QA with an isolated copied library verified:

- Click Friday, j selects Closer, k returns to Warmup.
- Shift-Tab, Down switches to Weekend; Tab, j selects Closer.
- Command-Shift-right-bracket switches to RB Set; k selects Warmup.
- Command-F, typing jk enters jk in search without moving tracks.
- Escape then clicking the already-open RB Set, j selects Closer again.

All 20 dedicated library model tests passed, including repeated focus requests and preserving
sidebar focus during arrow navigation. The app was rebuilt successfully.

Evidence: [selected track after playlist click and j](../images/library-evidence/31-playlist-keyboard-focus.png)
and [test output](validation-evidence/playlist-keyboard-focus-tests.log).
