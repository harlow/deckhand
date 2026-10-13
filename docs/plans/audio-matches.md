# Audio-based Matches: first pass

Matches now combines key/tempo/energy/genre metadata with lightweight audio descriptors.
The existing M, J/K, L, A and Esc workflow remains the interface. All computation runs
locally, using cached analysis; no cloud service, external model or new install dependency.

**Save as Playlist** turns a Matches session into a regular local playlist. The naming
sheet starts with “Matches — [seed title]”; Enter saves and Esc cancels. The seed is first,
followed by every result in its ranked order, regardless of the category/search currently
shown. Saving opens the new playlist without changing playback or the original playlist.
It is a fixed snapshot, not a live recommendation list. USB export uses the usual playlist
selection and explicit Sync action. Playlist creation and membership commit atomically;
duplicate/blank names keep the sheet open so the name can be corrected.

## Signals and ranking

- **Band balance:** relative power of the cached low/mid/high envelopes in the track body.
  Vector reductions use all frames to avoid sampling repeatedly between drum hits.
- **Groove:** beat-relative accents at eight subdivisions of each beat in a four-beat bar.
  Similarity compares active bands with energy weighting and tolerates a one-beat
  downbeat offset. Near-flat bands supply no rhythmic evidence.
- **Energy shape:** an eight-part, gain-independent contour of the summed band envelopes.
  Overall energy differences still come from Deckhand's existing 1–10 energy estimate.

Only similarity above a neutral baseline earns an audio bonus. Missing evidence earns
neither a bonus nor a penalty. Metadata remains the fallback. Very strong joint audio
evidence can connect differently tagged songs, but the existing tempo bounds remain.

Smooth requires compatible key/tempo and no strong audio contrast. Lift additionally
requires an energy increase. Change Direction holds the other supported alternatives.
Reserve up to eight candidates from each group, then fill the remaining places by score.
Prefer other artists after three selections by one artist; small collections still fill
available places. Results stay deterministic and exclude the seed, unavailable files,
duplicate paths and duplicate content hashes.

Explanations include “similar groove,” “similar band balance,” “similar energy shape,”
energy movement, and key/tempo relationships. These are envelope-based descriptors,
not claims of recognized instruments, vocals, semantic mood or guaranteed transitions.

## Cache and lifecycle

Descriptors have their own version and live as optional data in the analysis index.
Existing analysis versions and audio JSON files remain unchanged. A bad or future
descriptor cannot invalidate normal analysis summaries. Sync's analysis revision
deliberately excludes descriptors, preventing this upgrade from creating USB changes.

New analysis creates descriptors when its index entry is built. Older entries warm in
four background workers after the normal analysis fields have loaded. Group duplicate
hashes, merge only descriptors into current rows, periodically persist progress, and
cancel warming when the library closes. Imports arriving during warming request another
pass. An open Matches session stays fixed so keyboard selection cannot jump underneath it.

App/CLI saves use a file lock and merge only changed index hashes. Failed writes retain
pending changes for retry. Index construction and persistence stay outside the state lock
and off the UI thread for background upgrades.

## Validation

- 293 release-configuration tests passed across 58 suites, including Save as Playlist.
- Controlled fixtures verify gain/tempo tolerance, contrasting accents and band balance,
  downbeat offsets, missing/invalid evidence, artist variety, and group coverage.
- Cache tests cover legacy backfill without rewriting analysis, stale writers, corrupt
  optional descriptors, failed-save retry, and normal analysis-summary consistency.
- Existing Matches tests cover pinned seeds, playback, deduplicated playlist additions,
  restart persistence, sidebar changes and returning to the original view.
- Saving Matches tests cover seed-first ordering, all-result membership while filtering,
  name validation, original-playlist preservation, view selection and restart persistence.
  A storage failure test verifies atomic rollback and ordered membership deduplication.
- Native walkthrough of the installed app: Hello (Original Mix) previously returned
  50 Smooth matches; the new ranking returns 39 Smooth, 1 Lift and 10 Change Direction.
  J/L previews a different selected result and Esc restores Deep Tech without editing
  its contents. Needs Analysis remains zero and all 2,226 cached analysis JSON files
  have identical aggregate content before and after the descriptor upgrade.
- After the user approved macOS removable-volume access for the rebuilt ad-hoc app,
  RATS finished reading and displayed normal capacity and sync status. During active
  listening/rating, it showed nine pending changes; a read-only comparison of the local
  library with the USB database confirmed nine rating differences (rated locally,
  unrated on USB). No sync was performed during verification. Unit tests additionally
  verify that descriptor backfill leaves the analysis revision unchanged.
- Read-only evaluation over 20 seeds and 2,175 analyzed candidates: mean ranking 25.1 ms,
  maximum 30.1 ms; first descriptor read/extraction 5.5 seconds. 2,162 tracks supplied a
  usable groove descriptor. The top ten shared an average 2.05 results with the metadata-only
  baseline using the same group/diversity rules. This establishes changed behavior and
  latency; it does **not** establish improved listening preference.

Aggregate benchmark: [audio-match-evaluation.json](validation-evidence/audio-match-evaluation.json).

Run the optional collection evaluation without saving the cache or editing the library:

```sh
DECKHAND_AUDIO_MATCH_REPORT=/tmp/audio-matches.json \
  swift test -c release --scratch-path .build-standalone --filter AudioMatchEvaluationTests
```

## Remaining research

Listen to the changed recommendations before tuning weights. Further work may examine
specific mix-out/intro sections, vocal activity and learned embeddings. Half/double-time
tempo matching and personalized transition feedback are separate enhancements.

Research basis: [style, rhythm and vocals in an automated DJ system](https://link.springer.com/article/10.1186/s13636-018-0134-8),
[music-similarity and tagging models](https://essentia.upf.edu/models.html), and
[song/transition preferences](https://arxiv.org/abs/1401.1880).
