## Data-safety and interaction bugs

1. **Footer can eject a drive mid-sync.** In `SidebarView.swift`, `DriveFooter`'s Eject is disabled only while `ejecting.contains(drive.id)`. The toolbar version also checks `job.running`. Unless `eject` guards against this in the model, the footer lets you yank a drive during a write.

2. **The banner bypasses the Sync gating.** In `TrackListView.swift`, `SyncNoticeBanner`'s "Sync Again" and "Sync Anyway" call `library.sync(d)` directly. The toolbar Sync is disabled on `pendingSourceEdits > 0` and `!driveMatchesSource`, but these two buttons skip both checks. Any refusal has to be enforced in `sync()`, not the view.

3. **A mismatched (legacy) drive still shows live status as if it were linked.**
   - `summary()` appends "N on DRIVE · N waiting to sync" whenever `manifest != nil`, with no `driveMatchesSource` check.
   - `DriveFooter.status` and the `DriveControls` label show `pendingChanges` or a green **"Up to date"** for a drive that Sync refuses to touch.
   - `DriveFooter` falls back to `library.drives.first` when `activeDrive` is nil, then shows global pending/Up-to-date state for a drive that isn't active.

4. **The mismatch banner can disappear while Sync stays dead.** The banner requires `library.sourceAvailable`, so when it's false the banner is hidden. Sync is still disabled, and its `.help` just says "Sync X". The user gets no reason. The same happens for `pendingSourceEdits > 0`.

5. **The legacy-drive fix points the wrong way.** When the drive can't be adopted, the banner says "Import that library…" and offers **Add Music…**. Importing to satisfy a drive manifest risks duplicate imports and source drift. Also, the adopt dialog warns that "All Tracks includes music from every source." If the old manifest had entire-library on, adoption silently grows the sync set, possibly past capacity. Show the resulting track count and size before confirming.

6. **Music export writes to the user's Music library.**
   - "Includes your edited ratings" means track ratings in Music get overwritten. That's not a copy. Make it an explicit toggle, off by default.
   - With no playlist selected, `onAppear` pre-selects **every** playlist for export. Default to none or the current one.

7. **The Add Music sheet can trap you.** `.disabled(!library.sourceCanChange)` wraps the whole view, Cancel and Esc included. If `sourceCanChange` is false for a non-import reason, such as a sync running, you can't dismiss the sheet.

8. **Settings dismissal is fragile.** In `MusicImportsView`, the buttons call `dismiss()` and then set `choosingSource` or `showingDestinations` on the model. This depends on the Settings window closing and the main window coming forward. "Re-import…" has an ellipsis but no dialog, and it fires immediately.

9. **Two collections for one concept.** `MusicImportsView` uses `library.connections`, while `LibraryDestinationsView` uses `library.importConnections`. If they diverge, Settings and Export will disagree about which imports exist.

## Top 5 simplifications

1. **Remove live-source machinery from the UI.** This matches your "imports aren't managed" goal. Drop:
   - the `.staleLibrary` notice and "Sync Anyway (May Be Stale)"
   - the Automation/`library.live` warning
   - `sourceConflicts`
   - the `pendingSourceEdits` Sync gate
   - the `sourceAvailable` gating on New Playlist, Move to Top Level, and Export (drag-move isn't gated anyway, so this is already inconsistent)
   - the `playlistDestination` copy

   Sync should read only the Deckhand DB. Keep the store and caches as they are; only callers change.

2. **Fold "Library Settings" into Add Music.** Today the gear opens a Settings window that's really import history plus Add and Export buttons that bounce back to the main window. Instead, list a "Previously imported" section under the three cards in `SourceChooserView`, with a per-import Re-import button that has a real confirmation. Then `LibraryIdentityView` and `MusicImportsView` can go.

3. **Have one drive control.** Keep the toolbar Sync button and the footer for status, capacity, the drive picker, and Eject. Remove the duplicate picker and eject from `DriveControls`. Move the status text into one model function (`driveLabel(drive) -> (text, color)`) so the footer, toolbar, and summary can't disagree. This alone fixes bugs 1 and 3.

4. **Give legacy drives a single state.** For an unlinked drive, hide all on-drive dots and counts. Show one banner: "Link [drive] to your Deckhand library" with the before and after track count and size. Never route to Add Music. Disable Sync with a tooltip that gives the reason.

5. **Make Export a plain file action.**
   - Rekordbox: one "Export Rekordbox XML…" using a save panel. Don't require a prior Rekordbox import, and don't show one button per import.
   - The "PLAYLISTS FOR MUSIC" picker currently sits beside a Rekordbox button that ignores it and exports everything. Either honor the selection for both targets or split them.

I'd leave the filter bar, key wheel, Quick Rate, hot-cue and keyboard controls, the sidebar drive "+ Add" hover, and the Analysis banner alone. They're DJ workflow, not source management.
