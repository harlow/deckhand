# Matches header refinement

Implemented October 12, 2026. The user asked for more character in the pinned seed area, inspired by the website's warm/purple/blue record treatment, with fewer filters.

Matches now has a full-width coral → violet → blue background that fades down into the table. It reuses Deckhand's drop, breakdown and waveform-blue tokens. The eyebrow uses coral, the seed title is slightly larger, and the A destination sits beside the artist. The regular Key/BPM/Energy/Rating/Genre toolbar is absent in Matches; category chips and one search field share a row. The existing TrackToolsLayout wraps the search below categories when they cannot fit side by side. Empty categories are disabled and dimmed. Ordinary playlist views retain their normal filters.

The gradient is static, contains no image assets, and does not capture pointer input. Seed playback, keyboard controls, membership edits, matching/ranking, and USB behavior are unchanged.

## Validation

- Standalone release build passed signature, runtime/resource and dependency checks.
- [23 focused ranking, model, table-selection, help and keyboard tests passed](validation-evidence/matches-header-tests.log).
- Native QA with the isolated 62-track library: M opened Matches; / focused the single header search field, typing Match 12 filtered to that result, and the standard filter buttons were absent.
- Returned to the user's regular library and reproduced the original Peggy Gou seed. The native header is captured with the original playlist context, key, tempo, empty search and 50 results. No production playlist edits or USB writes were made.
- [Before/after comparison](../images/matches-header/comparison.jpg), [finished header](../images/matches-header/after.jpg).

The native visual comparison covers the supplied wide-window target. The narrower layout uses the existing adaptive workspace layout; no native narrow-window capture is claimed.
