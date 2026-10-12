# USB progress option 1 — design QA

final result: passed

## Target and evidence

Source visual truth:
`/Users/harlow/.codex/generated_images/01a126e5-c189-7d20-aa03-524fb9586dca/exec-beaef966-6953-4189-8388-93366722800a.png`

Implementation: [refined capture](docs/images/library-evidence/58-progress-beside-drive-refined.png).
Scope: native USB toolbar progress, not a redesign of the library/table. Dark theme, Weekend
selected, copying sample 6 of 11, drive and Cancel adjacent. Fixture tracks and DH_SYNC name differ
from the generated mock; those content differences are expected.

Viewport: 1440×900 app points. Source 1586×992 pixels is normalized to 1440×901.
Implementation 3104×2024 pixels includes OS shadow/margins; crop (112,76)-(2992,1876)
is 2880×1800 @2x, normalized to 1440×900. No browser/CSS viewport applies to this native app.

[Full-view comparison](docs/images/library-evidence/60-progress-full-refined-comparison.png)
and [focused toolbar comparison](docs/images/library-evidence/59-progress-toolbar-refined-comparison.png)
put source and implementation together. Both were visually inspected after normalization.
Additional native states: [1080×900](docs/images/library-evidence/61-progress-compact.png),
[saving](docs/images/library-evidence/62-progress-saving.png),
[checking](docs/images/library-evidence/63-progress-checking.png),
[completed](docs/images/library-evidence/64-progress-completed.png).

## Findings and iteration history

1. Initial comparison: blocked. [P2] Phase and count used caption (11pt), appearing too small next to
   toolbar controls. Evidence: [initial focused board](docs/images/library-evidence/56-progress-toolbar-comparison.png)
   and [initial full board](docs/images/library-evidence/57-progress-full-comparison.png).
   Fix: use callout (13pt) for the phase/count row.
2. Rebuilt and recaptured the same viewport/state. Refined full and focused boards above confirm
   readable text and the separate bar. No actionable P0/P1/P2 findings remain.

## Required fidelity surfaces

- Fonts: existing native SF system family and standard callout weight, 13pt phase/count;
  monospaced digits keep counter stable. Text stays on one line; accessibility/help include full details.
  Native antialiasing and generated-image raster text differ as expected.
- Spacing/layout: 200×28pt progress group, 4pt label/bar gap and 6pt capsule height; phase aligns
  left, count right, then drive and Cancel. Existing native chip padding/radius are preserved.
  Generated decorative separators and enlarged chrome were not part of the requested change.
  All persistent sync controls remain visible at minimum width; filters wrap below.
- Colors: current app accent blue for progress, dim gray remainder, white phase/secondary count,
  existing subdued drive chip. Capacity remains gray and is separate from action progress.
- Images/icons: existing native SF external-drive symbol stays crisp at Retina density. No new
  logos, artwork, raster assets or approximated illustrations are introduced in the scoped toolbar.
  Fixture waveforms elsewhere differ from source contents and are outside this change.
- Copy/content: “Copying tracks”, step-local “6 of 11”, drive name and “Cancel” match option 1's
  hierarchy. Additional phases say Saving playlists, Finishing USB, Checking USB; no stale item
  count remains for uncounted disk phases. Completed state returns to drive name + disabled Sync.

## Interaction checks and limitations

40 targeted tests passed. Native Cancel before engine execution preserved the USB manifest checksum.
Drive click opens job details; Escape closes it. Native sync ran the real engine on the disposable
image, wrote/committed its database and verified pending zero. Independent validation was clean.
The existing two audio files were retained, so this is metadata/analysis/database sync coverage,
not a throughput benchmark. The QA-only wrapper emitted the 6-of-11 sample and paused CLI output
at saving/checking for screenshots; no wrapper or delays ship in the regular bundle.
No production USB was synced. No browser console exists; build completed without errors and
native QA produced no application error dialog. Very long drive names were not separately tested.

## Implementation checklist

- [x] Separate phase/count/bar left of stable drive chip.
- [x] Preserve details, Cancel and completion behavior.
- [x] Clarify final phases and omit obsolete counters.
- [x] Correct typography and repeat source comparison.
- [x] Verify minimum width, real isolated sync and independent USB validation.

No open questions or blocking polish findings.

Installed the verified build, closed QA and ejected the disposable image. Only normal Deckhand
remains open; [regular-app evidence](docs/images/library-evidence/65-progress-regular-app.png).

---

# Matches header refinement — October 12, 2026

final result: passed

## Target and comparison

The supplied Matches screenshot and website record palette are the visual brief: make the pinned seed header feel special with color fading into the list, and simplify its filters. This is an intentional refinement, not a pixel-identical clone of the original gray header.

[Native before/after comparison](docs/images/matches-header/comparison.jpg) was opened and inspected as one comparison input. Both captures are 4038×2310 @2x, with the same Peggy Gou seed, JIMBO CHILL destination, 6A, 125 BPM, All 50 and empty search. The main-pane header crop is (580,103)–(3430,445), 2850×342 pixels. Changed height and control placement are intentional. The website record image provides palette guidance; the task did not request a record illustration or album-art asset.

## Required surfaces

- **Typography:** retains native SF text; slightly larger semibold seed title and coral, tracked eyebrow establish hierarchy. Seed/artist/destination remain readable and single-line. No font substitution.
- **Spacing/layout:** full-width background reaches both pane edges and fades before the table. Artist and A destination are grouped. Category chips and search align at the bottom. The removed filter row reduces clutter. Existing toolbar/table divider alignment is preserved.
- **Colors/tokens:** drop coral, breakdown violet and waveform blue are the existing website/app palette. Low-opacity diagonal tint plus vertical mask keeps the dark table and white text readable; no animation is added.
- **Image quality/assets:** native gradients and SF Symbol controls stay sharp at Retina density. No rasterized UI, new illustration or approximate brand mark was introduced.
- **Copy/content:** seed title, artist, destination, count, key and BPM agree with the original view. Empty categories are deliberately dimmed/disabled, rather than implying an available result.

## Findings and checks

No P0/P1/P2 findings remain in the wide native target. Search was verified in the isolated native library, with one text field and no extra filter buttons. The 23 focused keyboard/model/table regression tests and standalone build passed. The compact layout reuses the existing adaptive TrackToolsLayout; no narrow-window visual verification is claimed. The user's normal library/preferences are restored and the updated Applications app is open.
