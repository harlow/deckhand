# Sync engine

How Deckhand decides what a sync changes, and how it keeps that decision honest. Code: `Sources/Sync`.

## One decision function

`SyncStatus.evaluate` is the only place that decides what a sync would change. It's pure (no I/O) and takes:

- the **library** (Apple Music playlists and tracks) and the **selection** (the drive's saved one by default);
- the drive's **manifest** (`/.deckhand/manifest*.json`): what Deckhand last wrote;
- **facts** per track (`TrackFacts`): the audio hash, size and mtime (or `unknown`, or `unavailable(reason)`),
  the analysis summary from the cache, and any recorded analysis failure;
- a **drive probe** (`DriveProbe`): which audio, analysis and artwork files exist, and the database's file id;
- the **output profile**: settings, ANLZ options, whether to analyze missing tracks and write art.

It returns a `ChangeSet`. Everything else reads that:

- `SyncPlanner.plan` gathers facts (hashes via the cache, synchronously) and probes the drive, then evaluates.
- `SyncExecutor.execute` carries out exactly the ChangeSet. Where a step learns something new (an analysis
  finishes or fails, a copy's real size, the art turns out unchanged), it recomputes the affected database rows
  with the same `SyncStatus.exportTrack` evaluate fingerprints, so the result is what evaluate would decide given
  those facts.
- `deckhand status [--json]`, `deckhand sync --dry-run` and the post-sync self-check print it. The app (phase 2)
  will compute it off the main thread.

The invariant, enforced by tests: **after a successful sync, reading the facts again, probing the drive again and
evaluating is clean.** `deckhand sync` does exactly that after writing, warns about anything still pending, and
prints a final `@result {...}` line (generation, clean, counts) for the app.

## Change categories

Per track (`ChangeSet.TrackChange`):

| Change | Means | Executor |
|---|---|---|
| `new` | not on the drive yet | copy |
| `audioChanged` | the source's audio changed | copy to a new path (same content ID); old copy deleted after commit |
| `missingOnDrive` | deleted from the drive behind Deckhand's back | copy again, same path |
| `adopt` | audio already on the drive: moved from elsewhere, or already at its path | move, or verify (size + audio hash) and keep |
| `analyze` | not analyzed, and the profile analyzes | analyze; then `analysisFiles` |
| `analysisFiles` | inputs changed, a file is missing, or a new path | rebuild; if the fingerprint differs or a file is missing, write the files whose bytes differ |
| `record` | the database row differs | (database rewritten) |
| `artworkCheck` | the track or file changed, or images are missing | re-read art; database rewritten only if the image changed |

Track statuses: `clean`, `pending(changes)`, `ineligible(reason)`, `retained(reason)`, `failed(reason)` (the
analyzer failed; not retried until it changes, or `--retry-failed`) and `unknown`. Only `pending` counts.
`unknown` is neither synced nor pending, and a ChangeSet with unknowns can't be executed.

Playlists compare field by field (`create`, `name`, `parent`, `sequence`, `contents`), folders included. Drive
changes: `settings`, `selection` (compared as a set; playlists deleted in Music drop out), `databaseMissing`,
`databaseChanged` (its SQLCipher salt isn't the one recorded: replaced, restored, or the last sync was cut short)
and `legacyManifest`.

The database is rewritten when a row's fingerprint changed, a track or playlist was added, changed or removed, or
the database is missing or replaced. A row fingerprint (`ExportTrack.fingerprint`) covers every column written,
as written (key name in the chosen format, colour by the chosen rule, the drive copy's size, the date as stored),
so settings that change rows show up as row changes and nothing goes stale.

## Retain policy

A track's audio and analysis files are never deleted because its source is unavailable right now (file missing or
unreadable, disk unmounted, cloud-only, DRM, unsupported format). Such a track that's on the drive is `retained`:
it keeps its manifest record, its database row (rebuilt from the Music metadata still in the library and the
drive copy's recorded size; analysis looked up by the audio hash the drive holds) and its playlist slots. Its
row, analysis files and missing art can still be updated. When the source comes back, nothing is copied.

Tracks leave the drive only when deselected (or deleted from Music), when their audio is superseded by changed
audio, or when they're unavailable and their drive copy is gone too (`lost`: forgotten, nothing deleted).
Unavailable tracks that were never synced are `ineligible` and not counted.

## Manifest concurrency

The manifest lives in two files written alternately in place (`manifest.json`, `manifest-b.json`); the one with
the higher `generation` wins and a torn write leaves the other intact.

- `Manifest.update(on:basedOn:)` re-reads both files, throws `manifestConflict` unless the newest is the
  generation the change was based on, and writes the file that doesn't hold the newest valid copy. A legacy
  single-file manifest is therefore never overwritten by the first save. Newer formats are refused.
- `Manifest.edit(on:)` is for the app's selection edits: it applies the change to the newest copy, retries on
  conflict, serializes edits within the process, and refuses while a sync holds the lock.
- `deckhand sync` takes `/.deckhand/sync.lock` (exclusive create; pid, host, start time) only once it has work,
  and plans again if the manifest moved since it was read. A lock is stale when its process is gone (by start
  time, so a reused pid doesn't count), it's from another Mac, or it's over 6 hours old. `SyncLock.current`
  tells the app whether a sync is running.
- Before replacing the database the executor checks the manifest is unchanged; at commit, edits the app made
  meanwhile (selection, entire library, settings) are merged in, and anything else fails cleanly. Settings are
  intent; what was written is in the per-track fingerprints, so merged edits can't hide stale output.
- The database is renamed into place before the manifest is saved. If a sync stops in between, the next
  evaluate sees `databaseChanged`, finds the new audio at its exact paths (`adopt`, verified, not copied), and
  keeps the content IDs that database gave them.

## Recipe versions

Each track's `anlzInputs` digests its cache entry's revision, the ANLZ-relevant settings and
`OutputProfile.recipe`, built from version constants. While inputs match and the files exist, a sync doesn't
decode anything. When they differ, the executor rebuilds the cues and phrases and compares the fingerprint; where
that differs, it compares the bytes with the files on the drive and writes only those that differ (the
fingerprint includes the analysis version, which doesn't always change the files). Bump by hand when output
changes:

| Constant | Bump when |
|---|---|
| `TrackAnalysis.currentVersion`, `CueAnalyzer.version`, `StructureAnalyzer.version` | analysis changes (also invalidates cached analysis) |
| `CueBuilder.version` | cues or phrases built from the same analysis change |
| `AnlzWriter.formatVersion` | the ANLZ bytes for the same analysis, cues and phrases change; also added to the fingerprint |
| `OneLibraryDatabase.formatVersion` | the database written for the same rows changes; part of every row fingerprint |

Bumping `CueBuilder.version` makes every drive check its analysis files once; bumping `AnlzWriter.formatVersion`
or `OneLibraryDatabase.formatVersion` rewrites them (or the database) once.

## Speed

The no-op path reads two small manifest files, walks `/Contents/Deckhand`, `/PIONEER/USBANLZ` and
`/PIONEER/Artwork` with `readdir` (no stat per file), reads 16 bytes of the database, stats each source file
once, and evaluates (about 0.2 s for 20k tracks in a release build). Nothing is written. FAT write optimizations
are unchanged: in-place writes for files the manifest doesn't vouch for yet (atomic only when rewriting files it
already vouches for), a locally built database renamed into place once, `._` cleanup.

Paths compare as FAT does: case-insensitively, after Unicode normalization (FAT lists names decomposed).
