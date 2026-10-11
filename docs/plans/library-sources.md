# Dedicated Deckhand library and import sources

**Status:** Implemented and tested locally<br>
**Date:** October 10, 2026

## Decision

Deckhand owns one persistent library. Every imported playlist, locally created playlist, membership
edit, and rating is saved locally regardless of the source. All Tracks combines imported tracks.
Changing or disconnecting a source never removes the tracks or playlists already saved in Deckhand.
The default import connection determines what the Update command reads next. Additional imports do
not change that default. The library is never locked to a particular import.

Audio stays at its original location. “Import music” registers its metadata and file references; it
does not copy the entire collection into an application media directory. Missing audio remains
referenced by saved playlists and can be used again when the original path becomes available.

| Source | Incoming data | Local ownership | Explicit outgoing action |
| --- | --- | --- | --- |
| Apple Music / iTunes | Tracks, ratings, playlists and folders | Deckhand library | Sync selected playlists to copies in a Deckhand folder in Music |
| Rekordbox XML | Collection, ratings, playlists and folders | Deckhand library | Export XML, then import its playlists in Rekordbox |
| Folder on Computer | Recursive audio scan, tags, M3U/M3U8 playlists | Deckhand library | USB sync; folder playlist writeback is deferred |
| Start Empty | No initial import | Deckhand library | Add sources whenever ready |

Automatic local saves and explicit outgoing sync are separate operations. Background activation,
source selection, playlist edits, ratings, analysis, and USB sync never write to Music or Rekordbox.

## User experience

A fresh launch offers Apple Music / iTunes, Rekordbox, Folder on Computer, and Start Empty.
The sidebar always identifies the **Deckhand Library**. Library → **Add Music…** (⌥⌘L) opens an import
chooser. **Update from …** (⌘R) reads the default connection; without a default, **Refresh Library**
checks saved audio availability. The first successful import becomes the default. Later imports and
individual updates leave that default unchanged.

Settings → **Music Imports** (also available through the sidebar gear) lists connected imports, paths,
last update times and failures. Each can be updated or removed. The default picker changes only the
update target; **Manual imports** clears it. Removing a connection retains tracks, playlists, ratings,
source mappings and USB selections. Re-adding the same location resumes its existing mappings.
Connections and the default survive restart.

New playlists (⇧⌘N), add/remove, drag and drop, and ratings (⌥0–⌥5) save to Deckhand. A playlist can
contain tracks from multiple sources. Switching sources preserves playback, queue, filtering and
selected playlist. Running imports, writes, exports and jobs temporarily block switching.

**Sync USB** (⇧⌘S) in the toolbar and Library menu directly syncs the selected drive using its saved
playlists and All Tracks selection. Playlist positions remain stable when a USB connects; selection
and sync status appear beside each playlist. Folders indicate partial selection.

Library → **Export Playlists…** opens secondary outgoing actions:

- **Music:** select playlists and explicitly export their copies. Locally edited ratings are included.
- **Rekordbox:** choose an imported XML connection and export the whole Deckhand library to a new XML.

These destinations run independently. A failed outgoing operation leaves the local library intact.
This pass does not provide an atomic combined “Music + USB” operation.

## Import and conflict rules

Repeated imports use saved external-to-local ID mappings. Different source connections namespace
folder/XML identities. The same resolved, normalized file path shares one local track identity across
adapters; separate file copies remain distinct local tracks even when their audio bytes match.
The first importing connection supplies primary metadata; local rating overrides always win.

Untouched imported playlists accept updated source membership on refresh. The first local edit
establishes a persistent override. Later imports retain that edit; if the external baseline changes
and disagrees with the local copy, the app displays a conflict notice. There is no automatic merge.
Playlists and tracks deleted externally remain saved in Deckhand, including untouched playlists.
An import failure records the error and retains the last successful collection. An empty valid folder
is a successful import; invalid XML or an unreadable folder is a failure.

Folder scans cache metadata and use filesystem device/inode evidence for renames within that source.
Rekordbox XML preserves folder hierarchy, order and duplicate playlist entries. Its playlist identity
uses the hierarchy path, so renaming or moving an external playlist can create another imported
playlist while the previous copy remains saved.

## Persistence and migration

`DeckhandLibraryStore` owns `~/Library/Application Support/Deckhand/Library/library.sqlite`.
`DECKHAND_LIBRARY_DIR` overrides the directory for tests. SQLite stores metadata, tracks, playlists,
source mappings, file indexes, cached XML, edit flags, and Music export receipts. Transactions use
WAL and FULL synchronous durability. Only changed rows are saved; a star edit does not rewrite a
large source index. One app holds an advisory writer lock; CLI readers see committed WAL data using
an ordinary read transaction. Corrupt or newer-format databases are reported instead of replaced.
Removed connections are retained with a removal flag; existing databases without the flag treat
connections as enabled. Removal is transactional and never deletes saved collection records.

Known folder/XML connections from the earlier per-source implementation migrate their cached
imports, local playlists, edited memberships, and cleared/changed ratings. Each connection migrates
atomically, including while its source is offline. Existing files under `Deckhand/Libraries/` remain
intact. Migration is idempotent. Music must be explicitly imported into a fresh dedicated library.

## Explicit sync to Music

Music export creates a Deckhand folder and managed copies of selected playlists. It preserves the
original imported playlists. Saved receipts retain destination playlist/track IDs and the last
exported membership, so repeated exports update copies and recover from a failure after object
creation without duplicating those objects.

Before mutating destinations, export checks existing managed membership and checks that tracks not
already in Music have available audio. It checks membership again before replacement. External
changes to a managed copy stop the export and show a conflict instead of silently overwriting them.
Order and duplicates are verified after replacement. Ratings are written only for explicitly edited
tracks in the selected playlists, then verified. Adding files can copy audio into Music's media
folder according to Music's own settings.

Cross-application writes are not transactional: a failure can leave a partial Music result. Local
playlists remain intact; receipts checkpoint completed steps. A partial membership write or failed
receipt save may require destination recovery rather than a blind retry. Destination conflict
resolution, folder hierarchy mirroring, and syncing directly into original Music playlists are deferred.

## Rekordbox exchange

Export a collection XML from Rekordbox and select it in Deckhand. Refresh reads that XML snapshot;
it does not ask Rekordbox to produce a new one. Export Playlists writes a separate XML file for manual
import of its playlists into Rekordbox. The source XML cannot be overwritten by this action.

The original XML bytes and local-to-external track mappings are cached in SQLite. Export works after
switching or disconnecting sources, including when the original XML is offline. Original TEMPO and
POSITION_MARK nodes are retained for matching tracks; local metadata, ratings and playlist membership
are written around them. Added tracks get collection nodes without invented cue/grid data.
Deckhand's playback and USB output continue to use Deckhand's own audio analysis.

## USB ownership

A drive belongs to the stable Deckhand library ID, not the currently selected import. Adding another
source leaves that ID unchanged. Saved selections and content IDs continue to work, and missing
source audio already on the drive is retained.

Older source-bound drives require an explicit **Use Deckhand Library** action. Adoption is offered
only when the previous source is known and every existing manifest track, playlist and selected
playlist ID survives in the shared library. Adoption changes manifest ownership and keeps selections
and files. Unrelated libraries remain blocked from taking over a populated drive.

## Architecture

- `MusicSource`: source connections, folder and XML adapters, Music readers/writers, normalized snapshots.
- `DeckhandLibrary`: dedicated SQLite store, merging/provenance, migration, Music export plans and receipts.
- `DeckhandApp`: imports and local edits through the store; explicit outgoing destination sheet.
- `Sync`: global source identity, device planning/execution and conservative legacy adoption checks.
- The app supplies a temporary JSON snapshot of the shared library to its bundled CLI for jobs.
- CLI `playlists`, `analyze`, `status` and `sync` default to the saved initialized library, falling back
  to Music before initialization. `--source-library` supplies a snapshot; `--music` on analyze/status/sync
  explicitly uses Music directly. Existing Music-only import/ratings commands retain their semantics.

## Validation and remaining work

See [the dedicated-library test report](dedicated-library-e2e.md) for regression and native UI evidence.
Real Rekordbox desktop import, Music writeback against a real Music library, and DJ hardware playback
remain integration checks. Automated Music export tests use a stateful destination to verify retries,
conflicts, ratings, ordering and explicit-only writes without changing a personal Music library.

Future work: file relocation, explicit conflict resolution/reset, playlist rename/delete/reorder,
M3U writeback, backup/restore UI for the dedicated database, and performance measurements with large
real collections. A 10,000-track regression checks that ratings do not rewrite source indexes; it is
not a benchmark of a full collection scan.

## Exchange references

- [Rekordbox collection XML export](https://rekordbox.com/en/support/faq/rekordbox7/#faq-84681).
- [Official XML exchange specification](https://cdn.rekordbox.com/files/20200410160904/xml_format_list.pdf).
- [Apple iTunes Library framework](https://developer.apple.com/documentation/ituneslibrary).
