# Small USB edits should stay small

October 11, 2026: a ratings-only sync appeared stuck at “Saving playlists.”

The pending-change count already described the edits. Before swapping in the updated
database, the executor separately ran a full validator that loaded every DAT, EXT,
and 2EX file. The connected library had about 1.8 GB of analysis data. Validation
only needed section headers and embedded audio paths, not the waveform payloads.

## Change

- Normal syncs reuse the manifest's prior analysis proof for unchanged audio at the
  same USB path. New, moved, changed, or unproven analysis is inspected again.
- All database references and the presence of audio, analysis, and artwork files
  are still checked. The staged database is still validated before the atomic swap.
- A missing/replaced database or forced rebuild gets a full inspection. The CLI
  `validate` command also continues to inspect every analysis file.
- Full inspection seeks between headers and reads the embedded path, skipping
  waveform payloads. It also rejects invalid header and path lengths.
- The UI says “Saving library,” covering ratings as well as playlists. Phase
  timings now persist in the system log for diagnosis after an app restart.

## Verification

Read-only benchmarks on the same 2,175-track USB:

| Check | Elapsed |
| --- | ---: |
| Previous full-file validation | 32.24 s |
| Repeated previous validation | 31.76 s |
| New full header/path inspection | 10.52 s |
| New unchanged-analysis validation used for small edits | 0.216 s |

These measure validation, not total sync duration. No USB files were changed by
the benchmarks. Database creation, writing and flushing still take additional time.

266 tests passed across 51 suites, including full sync/recovery scenarios, metadata
updates without audio/analysis rewrites, trust invalidation, missing files, malformed
framing and paths. A byte-count test validates an 8 MB waveform fixture by reading
less than 256 bytes. Full and file-backed parsers agree on malformed fixtures.
