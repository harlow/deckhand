# L previews the highlighted song

Fixed October 12, 2026. In ordinary playlists, the L command preferred `player.current` whenever something was already playing. J/K could highlight a different row, but L still sought within the earlier song. Matches already used the selected row.

The track-list command now always plays its first selected row from the existing pre-drop preview point, in both modes. This starts the selected song even if playback was paused and preserves continuation through the visible list. With no selected row, L retains its previous current-song seek fallback and pause state. H, Shift+H/L, hot cues and Quick Rate's mode-specific controls are unchanged.

The help overlay, README and keyboard runbook now say that L previews the selected song.

## Regression evidence

The PlayerShortcutTests fixture creates three silent WAVs and synthetic beat/drop analysis. It now hosts the real TrackListView, sends J then L to its native KeyTableView, and checks which song is playing, the 24-second preview point (16 beats before a 32-second drop at 120 BPM), and the following song. It also covers L starting a paused selected song, and an empty selection retaining the paused current-song fallback.

- [Before the fix](validation-evidence/selected-preview-before.log): the actual view-command regression test fails because Song 1 remains current after J selects Song 2 and L is pressed.
- [After the fix](validation-evidence/selected-preview-tests.log): 32 tests across playback, continuous playback, keyboard routing, help, table selection, Matches persistence and listing pass.

The standalone build passed signature, runtime/resource and dependency checks. The updated Applications app was installed and restarted on the regular library. No production playlists, ratings or USB contents were edited during testing.
