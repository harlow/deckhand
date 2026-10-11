# USB state audit — October 11, 2026

The surprising **Can't sync** message was caused by the isolated QA app comparing a real USB with
its two-track fixture library. That app displayed the same Deckhand title as the regular app. The
regular library contains the USB's music and playlists; this was not a failing USB or lost sync data.
QA windows now use their bundle's explicit display name in the title and toolbar. The QA app was
closed after verification and only the regular app was left open.

## Drives checked at 9:44 AM

| Drive | Actual state against the regular library | Next action |
| --- | --- | --- |
| DECKHAND | Current library identity matches. 15 audio files, three selected playlists: Warming, Beatport 2023, Afterhours; Weekend is their exported parent folder. Last sync 9:38 AM, generation 40. All audio files present. Complete evaluation, zero unknown tracks, **zero pending changes**. | None. Sync is disabled after the startup check. |
| DJTEST | Older Apple Music export, manifest format 1, no saved generation or local library identity. Warming with 11 audio files, all present. All 11 track IDs and its playlist exist in the regular library. Validation: **no problems found**. Safe to link through the imported Apple Music identity. | Explicitly link and sync when wanted. Preview: 11 track metadata/analysis/artwork updates plus database and legacy-manifest updates, **13 changes** total. No audio copy/removal appeared in the read-only preview. |

The old DJTEST manifest did not record a database identity. The engine asks to update its database;
the previous UI incorrectly phrased the absent recorded identity as proof that the database was
replaced. That preview now says **Update the USB's library database for this version of Deckhand**.
Validation found no corruption. No real USB was linked, synced, initialized or cleared during this audit.
DECKHAND's latest saved sync was already present when inspected.

## Stable UI rules

| Condition | Toolbar | Clicking Sync |
| --- | --- | --- |
| Reading USB or evaluating initial changes | Drive name, disabled Sync with spinner | Waits for the check; opening the app never starts a sync. |
| Current library, clean USB | Drive name, disabled Sync | No action needed. |
| Pending export changes | Orange **N changes to sync**, Sync | Runs the requested sync; a removal of all exported content still requires explicit confirmation. Click the drive name to inspect exact changes. |
| Safe earlier library, no export changes | Orange **Link library**, Sync | Opens the one-time link confirmation. Confirming links without starting unnecessary export work. |
| Safe earlier library with pending changes | Orange change count, Sync | Opens **Link [drive] to this library?**, showing staged selection and changes. **Link and Sync** verifies continuity, links and syncs. |
| USB whose music/playlists are absent from this library | Orange **Different library**, Sync | Explains the missing track/playlist count and asks for its original music/playlists. No USB writes occur. |
| No Deckhand manifest | **Set up USB**, Sync | Opens setup; no automatic initialization. |
| Read failure | **USB unavailable**, Sync | Shows the actual read error; a corrupt manifest is never treated as a blank USB. |

These conditions describe library compatibility and export work separately. A compatibility check
must not masquerade as pending music changes. The Sync button retains its label in all conditions.

## Checkbox regression

A checkbox previously routed an earlier-library USB into the link sheet. It now stages its choices:

- A folder selects or deselects every descendant leaf playlist, including nested folders.
- Partial selection has the existing mixed checkbox state.
- The orange count updates from the sync evaluator. No sheet opens and no sync starts.
- Choices for an earlier-library USB are saved locally, scoped to this library and that USB's device
  identity. They survive refresh/restart and do not affect another USB.
- Explicit linking applies the staged choice together with the ownership change. Checking boxes alone
  never links the USB or exports music/playlists. Existing linked-drive selection preferences continue
  to be saved in its manifest for the next explicitly requested sync.

Native QA clicked Weekend on the disposable DH_SYNC image. RB Set and Saturday both became checked,
the toolbar changed from **1 change to sync** to **2 changes to sync**, and no sheet opened. A comparison
of the USB's managed files before and after found them unchanged. The disposable image was ejected.

Regression tests cover nested selection, mixed/unselected states, All Tracks staging, restart/refresh,
separate device identities, explicit linking retaining staged choices, clean startup, mismatch safety,
ownership continuity, and sync status. **61 tests in nine suites passed.**

The installed regular app was reopened and visually checked after startup completed: DECKHAND shows
no pending label and a disabled Sync button. Its launch log confirms two evaluations with zero pending
changes and zero unknown tracks. Only the regular app remains open.

Evidence: [regular app with clean DECKHAND](../../images/library-evidence/40-regular-library-clean-usb.png),
[final launch log](validation-evidence/regular-library-final-launch.log),
[folder selected without an overlay](../../images/library-evidence/39-folder-checkbox-staged.png),
[unchanged test USB](validation-evidence/folder-checkbox-staging-usb-check.json),
[final tests](validation-evidence/usb-state-final-tests.log),
[read-only engine audit](validation-evidence/usb-state-audit.log),
[DJTEST validation](validation-evidence/djtest-validation.log),
[DECKHAND status](validation-evidence/deckhand-status.log).

## Selected-row checkbox contrast

Checked and mixed USB selection icons previously used the same accent color as the selected sidebar
row, making them disappear into its background. Playlist, folder and All Tracks controls now receive
the row selection state: checked/mixed icons use white on a selected row; unchecked outlines use
white at 65% opacity. Other rows retain the existing blue/secondary colors.

The build and signature verification passed, and the regular app was reopened. An offscreen native
SwiftUI render of the actual USBSelectionButton component verified checked, mixed and unchecked
states against the blue background; [render evidence](../../images/library-evidence/41-checkbox-contrast-states.png).
The installed app was also visually checked with its selected unchecked row and clean USB state.
The native automation connector could not bind the regular app (it resolved an obsolete bundle ID),
so a checked row was verified in the component render rather than by toggling the user's USB selection.
