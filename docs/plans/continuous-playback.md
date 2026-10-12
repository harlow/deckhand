# Continue playback through the list

Starting a song in the track list now captures the visible order after that song.
When it finishes, playback continues automatically. This applies to Enter, double-click,
the Play context-menu item, starting playback with Space, and clicking a waveform.

- Explicit Up Next choices play first. After the queue ends, the original list resumes.
- A song played from the queue is removed from the automatic remainder to avoid repeats.
- Browsing, filtering or sorting another view does not change the playing list. Explicitly
  starting a song creates a new list continuation using the order visible at that moment.
- Unreadable audio is skipped. The last song stops without looping; Space can replay it.
- Next and Previous preserve the continuation. Up Next shows the next automatic song
  as “Next in list” when there are no explicit queued songs.
- Quick Rate's standalone previews discard the previous list continuation and retain
  their existing rating/skip flow.

The audio delegate checks player identity so a late completion for an old song cannot
advance a newly selected song. The artwork provider is retained for automatic advances.

## Verification

273 tests passed across 52 suites. Seven new playback tests use generated silent WAVs,
including real natural-end callbacks for visible ordering, queue priority, returning
to the list, skipping unavailable files and stopping at the end. Other cases cover
Previous, replacing the playing list, standalone previews, explicit queued playback,
reset, and stale callbacks. These tests do not use the user's library or USB files.

The standalone arm64 bundle passed its runtime dependency and code-signature checks
and was installed in Applications. After the user opened the unsigned build,
native UI verification passed using the isolated Keyboard Test library: Song 1
finished and Song 2 started automatically while Target Playlist was being browsed;
Up Next showed Song 3 as the next song in the original list. Evidence was captured
at `/tmp/deckhand-continuous-playback.jpg`. No user library or USB data was changed,
and normal app preferences were restored after the fixture check.
