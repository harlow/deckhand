# Actionable unavailable audio

Implemented October 11, 2026.

A read-only inspection of the regular library found that all 28 unavailable records were Apple Music tracks with `Protected (DRM) track; no exportable local file`, without a saved audio location. The old instruction to reconnect a disk was incorrect for these records.

All Tracks now shows a reason-aware summary and a **Review** action. Library Settings offers the same review. The right pane remains the playback queue; occasional file repairs use a dedicated sheet instead of another persistent warning area.

- Protected Apple Music tracks offer **Choose Audio File…**, which accepts a readable, unprotected local audio file. Deckhand cannot make a protected Apple Music download exportable.
- Imported tracks without local audio explain downloading in the original app and re-importing, or choosing a file.
- Missing/unreadable files show their saved path and **Locate File…**. **Recheck Files** handles reconnecting a disk or restoring the original file.

Choosing a file validates its format with AVFoundation before committing the saved location. The existing track identity, playlist membership, duplicates/order, and rating remain intact. A local location override survives restarting and re-importing the original source. Replacing audio clears the row's old analysis before checking the new file's cache; an in-flight cached result for another location cannot overwrite it. USB files are changed only through the existing explicit Sync action.

## Verification

67 persistence, library/model, export/sync, unavailable-audio and keyboard regression tests passed, followed by the new model repair/restart/re-import integration test. Tests cover protected and missing-file repairs, reconnection, invalid/empty/unreadable audio, unknown tracks, transaction rollback, unchanged playlist contents and persistent overrides.

Native testing used **Deckhand Audio QA**, a copy of the disposable two-track fixture library and its isolated cache. A protected Warmup record and a missing Closer path were seeded only in that copy. Review showed separate explanations and actions. Recheck left the still-missing file listed. Choosing Warmup.wav and locating Closer.wav removed both issues; reopening retained both repairs. Friday regained its three entries, including the repeated Warmup, and Closer retained five stars. A read-only comparison confirmed every playlist record was unchanged. No real track was repaired, analyzed, or synced during this test.

Evidence: [review and repair actions](../images/library-evidence/52-unavailable-audio-review.png), [reopened repaired fixture](../images/library-evidence/53-audio-repairs-after-reopen.png), [regression tests](validation-evidence/audio-repair-tests.log), [model integration test](validation-evidence/audio-repair-model-tests.log).

The final model/audio rerun passed all 31 tests after the toolbar-label follow-up. The regular app was installed and reopened, and the QA app was closed. A final read-only check still found exactly 28 protected records in the real library; no real audio repair or USB sync was performed.
