# Genres (2026-10-09)

Snapshot of the Apple Music library: 2,201 tracks, 57 distinct genre tags, and 459 tracks (21%) with no genre.
Nothing here has been applied yet. This is the proposed grouping for the Mac app's genre filter, plus notes
for a later clean-up.

## Where the tags come from

- **Beatport, from several years.** Beatport renamed and split genres over time, so one idea appears under
  several names:
  - "Indie Dance / Nu Disco" (older) vs "Indie Dance" + "Nu Disco / Disco" (newer).
  - "Garage / Bassline / Grime" vs "UK Garage / Bassline".
  - "Techno (Peak Time / Driving)" vs "Techno (Peak Time / Driving / Hard)".
  - "Electronica / Downtempo" vs "Electronica".
- **Apple Music's own names:** "Electronic", "Dance", "Hip-Hop/Rap", "R&B/Soul", "Pop", "Rock", "Alternative",
  "Jazz". These are broad and overlap the Beatport ones.
- **Long tail:** 25 tags have 5 tracks or fewer, and 13 have one or two.

## Families

Twelve families that the genre filter (and optionally the drive) would use. The original tags stay
untouched in Music; a family is just a grouping in Deckhand. Track counts are in brackets.

| Family | Tracks | Tags |
|---|---:|---|
| House | 366 | House (344), Funky / Groove / Jackin' House (9), Bass House (9), Future House (3), Funky House (1) |
| Indie Dance & Disco | 368 | Indie Dance (136), Nu Disco / Disco (127), Edit House (70), Indie Dance / Nu Disco (35) |
| Deep & Minimal | 214 | Deep House (140), Minimal / Deep Tech (54), Minimal (20) |
| Tech House | 159 | Tech House (158), House / Tech House (1) |
| Electronica & Downtempo | 129 | Electronica (64), Electronic (39), Electronica / Downtempo (26) |
| Pop, Dance & Mainstage | 117 | Dance / Electro Pop (67), Dance (29), Dance / Pop (8), Mainstage (5), Electro House (3), Pop (2), Big Room (2), Hard Dance / Hardcore (1) |
| Melodic & Progressive | 98 | Melodic House & Techno (76), Progressive House (21), Trance (1) |
| Hip-Hop & R&B | 98 | Hip-Hop/Rap (61), Hip-Hop / R&B (33), Trap / Hip-Hop / R&B (3), R&B/Soul (1) |
| Other | 62 | DJ Tools (21), Jazz (15), Rock (13), Mix CD (5), Other (4), Alternative (3), Acid Jazz (1) |
| Afro & Organic | 60 | Afro House (57), Organic House / Downtempo (3) |
| Garage, Bass & Breaks | 41 | UK Garage / Bassline (12), Garage / Bassline / Grime (10), Drum & Bass (5), Leftfield Bass (4), Breaks (3), Breaks / Breakbeat / UK Bass (3), Dubstep (1), 140 / Deep Dubstep / Grime (1), Bass / Club (1), Trap / Future Bass (1) |
| Techno | 30 | Techno (Peak Time / Driving) (14), Techno (Peak Time / Driving / Hard) (8), Leftfield House & Techno (6), Techno (Raw / Deep / Hypnotic) (1), Electro (Classic / Detroit / Modern) (1) |
| *(no genre)* | 459 | — |

Every tag in the library maps to exactly one family. A tag the mapping doesn't know (e.g. a new Beatport
genre) would show as its own entry under Other until it's added.

### Judgment calls to review

- **Edit House (70)** → Indie Dance & Disco: mostly disco and classic edits. Move it if it's used more broadly.
- **Electronic (39)**, Apple's catch-all → Electronica & Downtempo. These tracks may really be anything;
  worth a look by hand.
- **Dance (29)**, also Apple's → Pop, Dance & Mainstage. Same caveat.
- **Bass House (9)** → House rather than Garage, Bass & Breaks.
- **Electro House, Big Room, Mainstage, Hard Dance** → Pop, Dance & Mainstage (the "EDM" end).
- **Trance (1)** → Melodic & Progressive; **Electro (Classic / Detroit) (1)** → Techno.
- **Techno is small (30)**; it could merge with Melodic & Progressive if a 30-track family isn't useful.
- **DJ Tools and Mix CD** are in Other; they could be their own "Tools" family so they're easy to exclude.

## In the app (not built yet)

- **Filter:** the Genre filter lists families with counts, and each expands to its original tags.
- **Drive option:** a per-drive setting to write the family instead of the original tag to the stick, so
  browsing by genre on the deck is clean. Off by default.
- **Mapping:** stored as data (family → tags), editable later without code changes.

## Later

- **Clean-up screen:** every tag with its count; select several and "Rename to…" to rewrite them in Music
  (the same AppleScript path as ratings). Each merge is the user's call. Obvious Beatport renames would be
  pre-suggested. "Indie Dance / Nu Disco" can't be resolved automatically: it's Indie Dance or Nu Disco per
  track.
- **The 459 untagged tracks:** nothing in the files says what they are.
  - **Hand-tagging:** a "No Genre" view plus multi-select rename.
  - **Suggestions:** compare each untagged track's audio with the 1,742 tagged ones and suggest the nearest
    family, which the user accepts or rejects. That would learn this library's own taxonomy. Expect
    family-level accuracy only (House vs Techno vs Hip-Hop, not Deep vs Melodic House).
