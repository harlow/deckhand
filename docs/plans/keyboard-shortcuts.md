# Simple keyboard shortcuts

Implemented and verified October 11, 2026. The shortcut overlay opens with `?`, `⌘/`,
or Help → Keyboard Shortcuts. Letter labels are uppercase for readability; they do not
require Shift unless the Shift symbol is shown. Quick Rate has its own contextual help.

## Everyday map

| Action | Key | Verification |
| --- | --- | --- |
| Previous / next playlist | `[` / `]` | Native app; wraps visible playlists, skips filters and folder headers |
| Previous / next song | `K` / `J`, or ↑ / ↓ | Native app and AppKit navigation tests |
| Play selected song | Enter | Native app with generated WAVs |
| Play / pause | Space | Native app and player tests |
| Jump to playing song's start | H | Native app; paused transport remains paused |
| Jump to pre-drop preview | L | Native app; test drop at 32s previews from 24s |
| Back / forward 16 bars | Shift+H / Shift+L | Native app and beat-grid tests; 64 beats on a four-beat bar grid |
| Rate 1–5 stars | Option+1–5 | Each value verified in native app using an isolated local library |
| Clear rating | Option+0 | Native app; persisted rating cleared |
| Jump to hot cues 1–5 | 1–5 | All five verified at 0s, 32s, 64s, 80s and 96s in the generated track |
| Add selected songs to a playlist | A | Native picker; Escape cancels, Return adds; membership survives restart |
| Search songs | / | Native app; letters, brackets and question marks remain text while editing |
| Show / hide help | ? or Command+/ | Native app, including Command+/ while editing search |
| Close help / cancel | Escape | Native overlay and playlist picker |
| Collapse multiple selected songs | Escape | Native five-song selection returns to one; open filter closes first and keeps all five selected. AppKit tests cover workspace, editor, help, sheet, and menu priority |

Navigation and song commands work across the workspace while text editors and modal
dialogs retain their keyboard input. Arrow keys retain normal focus behavior. H/L seek
within the playing song; Enter plays the selected song. If nothing is playing, L starts
the selected song's preview. Bar jumps require a beat grid or a known tempo.

## Approved removals

The user approved removing these song-list bindings: P as a preview alias, Shift+Enter
for Mix In, Q/Shift+Q for queue/play next, Shift+P for the playlist picker, hot cues 6–8,
comma/period and their Shift variants for beat jumps, Shift+brackets for section jumps,
M for the mix filter, R for starting Quick Rate, Command+L for revealing playback, and
Shift+J/K for extending selection. Tests and a native walkthrough confirmed these no
longer dispatch song-list actions. The corresponding mouse/menu features remain.

Ordinary menu and focus shortcuts remain, including Command+F, Tab/Shift+Tab, standard
table selection/editing keys, and the existing Playback and Library menus. Quick Rate's
mode-specific shortcuts remain; native testing confirmed cue 8 and its contextual help.

## Evidence and test isolation

- 259 Swift tests passed across 50 suites. Dedicated AppKit tests cover dispatch,
  removed aliases, editable fields, sheet isolation, modal help, and focus restoration.
- Opening help while editing search now restores the text field and insertion point;
  native testing typed `Song`, opened/closed help, then appended ` 2` successfully.
- Player tests use generated silent WAVs with synthetic analysis and five hot cues.
  They verify 64-beat seeks, boundary clamping, playback toggles and pause preservation.
- The native walkthrough used only the generated library, playlists and analysis.
  Ratings and playlist membership were read back from its local database after restart.
- Read-only fingerprints confirmed the real library's tracks, playlists, sources and
  metadata, plus mounted USB manifests and export databases, were unchanged by QA.
- Original app settings were restored and the regular installed app was reopened.

Screenshot: [keyboard-shortcuts.png](../images/keyboard-shortcuts.png).

To regenerate the isolated native fixture, optionally retain the player-test artifacts:

```sh
DECKHAND_SHORTCUT_QA_DIR=/tmp/deckhand-shortcut-qa \
PKG_CONFIG_PATH="$PWD/.build-release-deps/prefix/lib/pkgconfig" \
swift test --scratch-path .build-standalone --filter PlayerShortcutTests
```

Use a fresh directory each time. Launch a single app instance with `DECKHAND_LIBRARY_DIR`
pointing at that directory's `Library` subdirectory and `DECKHAND_CACHE_DIR` at `Cache`.
Never sync the generated test library to a real USB.
