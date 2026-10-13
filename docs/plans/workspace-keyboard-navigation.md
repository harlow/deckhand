# Track navigation without clicking the table

Implemented October 11, 2026.

In the main library window, **j/k** selects the next/previous visible track even when keyboard focus is in the sidebar or another control. **Shift+J/K** extends the track selection. Navigation brings focus into the track table, where the remaining track shortcuts work normally.

Restored October 13: Shift+J/K selects a contiguous range from a fixed starting row.
Reversing direction shrinks the range and can extend across the starting row. Plain J/K,
Escape, a mouse selection or switching lists starts a new range; editors, sheets, help
and open menus retain their keys. AppKit regression tests cover these boundaries.

Control+J/K moves down/up by the number of full song rows that fit in the visible table.
It selects one destination row and scrolls it into view, stops at the list edges, and
adapts when the window is resized. A page jump starts a new Shift-selection range.

Search and playlist name fields retain normal text entry. Sheets, popovers, settings windows, modified shortcuts (Command, Option or Control), and hidden track lists retain their own keyboard behavior. Arrow keys retain their normal focus-dependent behavior. Escape or Return from search returns to the list.

The table installs a weak local event monitor while attached to its window, and removes it on detachment or destruction. It only handles events for its own key window, with no sheet/modal operation or editable responder. Events already targeting the table go through its existing handler once.

## Verification

Five AppKit tests pass, covering navigation from another control, single dispatch, extended selection and boundaries, real search/name field editors, modifier keys, other/inactive windows, hidden tables, and sheets. The command-line tests explicitly model the key-window flag because the test runner cannot activate an app window.

Native UI testing used **Deckhand Keyboard QA**, with a copy of the two-track fixture library:

- Shift+Tab to focus the sidebar, then j: Closer → Warmup.
- Shift+Tab, then k: Warmup → Closer.
- Command+F, then individual j and k key presses: search text becomes `jk`.
- Escape, Shift+Tab, Shift+J: both rows selected.
- New Playlist dialog, then j/k: name becomes `jk`; Cancel leaves playlists unchanged.

No USB sync was performed. The test app was closed and the regular app rebuilt and reopened.

Evidence: [search typing](../images/library-evidence/45-keyboard-search-typing.png), [extended selection](../images/library-evidence/46-keyboard-workspace-selection.png), [test log](validation-evidence/workspace-keyboard-tests.log), [build log](validation-evidence/workspace-keyboard-build.log).
