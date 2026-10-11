No tools used, as requested. I found four issues worth fixing in these snippets. One is high-risk, two are medium, and one is low.

### 1. Music export can run twice at once (high)
**Where:** `LibraryDestinationsView.swift`, Export button, and `exportMusic`.

**Problem:** The button is disabled only by `selected.isEmpty || !library.sourceCanChange`. While an export runs, its label changes to "Exporting…", but it stays clickable. `exportMusic` doesn't check `exportingMusic` either. A double-click or impatient second click therefore starts a second `MusicExport.execute` against Music while the first is still writing.

**Effects:**
- Playlist creation and receipt saves can race, which risks duplicate Deckhand playlists in Music.
- The first export's `defer` clears `exportingMusic` while the second is still running. That re-enables Done and the other controls mid-export.

**Fix:** Add `|| library.exportingMusic` to the button's `.disabled`, and add `!exportingMusic` to the `guard` in `exportMusic`. This doesn't apply if `sourceCanChange` already depends on `exportingMusic`, but nothing shown here says it does.

### 2. A drive that is still being read is treated as a blank USB (medium)
**Where:** `USBConnectionView.swift`, the `drive.manifest == nil` branch.

**Problem:** `refreshDrives` first publishes placeholder drives with `isReading: true` and `manifest == nil`. If Sync USB or the sheet opens before the detailed read finishes, the view takes the "Set Up \(name)" branch. That can happen for a drive that is already a Deckhand drive or a legacy drive.

**Effects:**
- The view says "Use this USB for your Deckhand playlists…".
- "Set Up USB" stays enabled, but `initializeDrive` guards `!drive.isReading`, so clicking it silently does nothing.
- The setup copy is wrong for that drive. The guard prevents damage, but the UI misleads the user.

**Fix:** Before the `manifest == nil` check, add a `drive.isReading` branch that shows a progress message such as "Reading USB…" and a Cancel button. Also add `|| drive.isReading` to the Set Up button's `.disabled`.

### 3. "Try Again" does nothing if the volume can't be reopened (medium)
**Where:** `refreshDrive`.

**Problem:** If `Volume(url:)` fails, for example because the drive was unplugged or remounted at a different path, then `drive` is nil and the function returns early. It doesn't update `readError` or `isReading`.

**Effects:**
- Clicking "Try Again" in the error branch does nothing visible.
- If the drive was a placeholder with `isReading == true`, it stays stuck in that state.

**Fix:** On that failure path, either set `readError` on `drives[i]` or call `refreshDrives()` so the list is rebuilt.

### 4. The Done button in Library Settings may not close the window (low, depends on presentation)
**Where:** `MusicImportsView.swift`, Done button.

**Problem:** Done calls `NSApp.keyWindow?.performClose(nil)`, while the other two buttons in the same view use `dismiss()`. `performClose` only beeps if the window has no close button. So if this view is presented as a `.sheet`, both Done and Esc do nothing. If it's a `Settings` or `Window` scene, it works, but it still relies on whichever window happens to be key.

**Fix:** Use `dismiss()` to match the rest of the view.

I didn't find regressions in `FileOps`, the opt-in ratings path (`plan.ratingIDs = []` when ratings are off), the adoption gating, or the token merge logic.
