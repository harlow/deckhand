# Playlist dragging and ordering

Implemented October 11, 2026.

## Interaction

- Drop onto another playlist's middle to copy its tracks. The destination gets a filled background and a `+N` count of new tracks. A playlist copy asks for confirmation, states that the original playlist keeps its tracks, and reports skipped duplicate entries. Track-table drags add tracks directly.
- Existing destination members and repeated incoming entries are skipped automatically. An already-included collection refuses a redundant copy. Missing audio does not remove saved playlist members from a playlist copy.
- Dropping a playlist onto itself leaves its selection unchanged, without a drop outline or copy proposal.
- Drop onto a folder's middle to move the playlist into that folder, after its existing children.
- Drop at a row's upper or lower edge to position the playlist at the thin insertion line. This works at the library's top level and within folders. The line's indentation identifies the destination level. Immediately below an expanded folder means before its first child; below a collapsed folder means after the folder at its own level.
- Moves and positioning preserve playlist identity, contents, subtree structure and USB selections. They reject self-placement, folder cycles and stale anchors. Ordering is stored locally and survives restart and re-import; the sync engine already compares playlist sequence changes.

## Implementation and verification

The hover preview uses an in-process payload cache for immediate cursor and count feedback. A completed drop reads the actual typed item providers and revalidates its destination before changing the library. The native track table also publishes these types while retaining its text representation for queue drops.

Playlist positioning commits parent, sibling order and local-placement provenance in one database transaction. A confirmation uses a snapshot of proposed additions, and the store deduplicates again if another edit occurs before confirmation.

A native mouse check exposed an insertion line remaining after a successful reorder. Completed drops now clear the drag payload immediately, all hover feedback clears when that payload ends, and row markers only render during an active drag. The user verified both the corrected reorder behavior and the copy confirmation in the separate QA app. Native UI capture below shows the cleared marker after reordering. Automated drag input began sessions but did not reliably reach the destination; mouse validation is explicitly human-assisted.

- Full suite: **236 tests in 43 suites passed**, including new copy/deduplication/persistence, top-level and folder positioning, re-import retention, and atomic rejection of invalid/stale/cyclic placement tests.
- [Test output](validation-evidence/playlist-drag-tests.log)
- [Production data fingerprint checks](validation-evidence/playlist-drag-user-data-check.json). Track, import and metadata records and all three USB files matched their pre-test fingerprints. The production playlist fingerprint changed because the user added a track to “Mixed in Bongoloco” (50 → 51), confirmed in chat. That edit was preserved.
- [Native screenshot after reordering](../images/library-evidence/34-playlist-reordering-after-drop.png)
- [Normal Deckhand library reopened with the new build](../images/library-evidence/35-playlist-drag-normal-library.png)

Testing uses an isolated library under `/tmp/deckhand-playlist-drag/Library`. No test import, copy, reordering or sync was performed on the user's library or USB.
