# Genre families (proposal, not built)

DJ libraries collect genre tags from many places, so the same idea shows up under several names. This is
the proposed grouping of tags into "families" for the Mac app's genre filter, plus notes for a later
clean-up tool. Nothing here is implemented yet.

## Why tags are messy

- **Beatport renames genres over time**, so one idea appears under several names:
  - "Indie Dance / Nu Disco" (older) vs "Indie Dance" + "Nu Disco / Disco" (newer).
  - "Garage / Bassline / Grime" vs "UK Garage / Bassline".
  - "Techno (Peak Time / Driving)" vs "Techno (Peak Time / Driving / Hard)".
  - "Electronica / Downtempo" vs "Electronica".
- **Apple Music's own names** ("Electronic", "Dance", "Hip-Hop/Rap", "R&B/Soul", "Pop", "Rock",
  "Alternative", "Jazz") are broad and overlap the Beatport ones.
- **A long tail** of tags with only a handful of tracks each.
- **Untagged tracks**, often a fifth of a library or more.

## Proposed families

The original tags stay untouched in Music; a family is just a grouping in Deckhand.

| Family | Tags |
|---|---|
| House | House, Funky / Groove / Jackin' House, Bass House, Future House, Funky House |
| Indie Dance & Disco | Indie Dance, Nu Disco / Disco, Edit House, Indie Dance / Nu Disco |
| Deep & Minimal | Deep House, Minimal / Deep Tech, Minimal |
| Tech House | Tech House, House / Tech House |
| Electronica & Downtempo | Electronica, Electronic, Electronica / Downtempo |
| Pop, Dance & Mainstage | Dance / Electro Pop, Dance, Dance / Pop, Mainstage, Electro House, Pop, Big Room, Hard Dance / Hardcore |
| Melodic & Progressive | Melodic House & Techno, Progressive House, Trance |
| Hip-Hop & R&B | Hip-Hop/Rap, Hip-Hop / R&B, Trap / Hip-Hop / R&B, R&B/Soul |
| Afro & Organic | Afro House, Organic House / Downtempo |
| Garage, Bass & Breaks | UK Garage / Bassline, Garage / Bassline / Grime, Drum & Bass, Leftfield Bass, Breaks, Breaks / Breakbeat / UK Bass, Dubstep, 140 / Deep Dubstep / Grime, Bass / Club, Trap / Future Bass |
| Techno | Techno (Peak Time / Driving), Techno (Peak Time / Driving / Hard), Leftfield House & Techno, Techno (Raw / Deep / Hypnotic), Electro (Classic / Detroit / Modern) |
| Other | DJ Tools, Jazz, Rock, Mix CD, Other, Alternative, Acid Jazz |
| *(no genre)* | — |

Every known tag maps to exactly one family. A tag the mapping doesn't know (e.g. a new Beatport genre)
shows as its own entry under Other until it's added.

### Judgment calls

- **Edit House** → Indie Dance & Disco: mostly disco and classic edits.
- **Electronic** and **Dance** are Apple's catch-alls, mapped to Electronica & Downtempo and to Pop, Dance &
  Mainstage. The tracks under them may really be anything.
- **Bass House** → House rather than Garage, Bass & Breaks.
- **Electro House, Big Room, Mainstage, Hard Dance** → Pop, Dance & Mainstage (the "EDM" end).
- **Trance** → Melodic & Progressive; **Electro (Classic / Detroit)** → Techno.
- **DJ Tools and Mix CD** sit in Other; they could be their own "Tools" family so they're easy to exclude.

## In the app

- **Filter:** the Genre filter lists families with counts, and each expands to its original tags.
- **Drive option:** a per-drive setting to write the family instead of the original tag to the drive, so
  browsing by genre on the deck is clean. Off by default.
- **Mapping:** stored as data (family → tags), editable without code changes.

## Later

- **Clean-up screen:** every tag with its count; select several and "Rename to…" to rewrite them in Music
  (the same AppleScript path as ratings). Each merge is the user's call; obvious Beatport renames would be
  pre-suggested. "Indie Dance / Nu Disco" can't be resolved automatically: it's Indie Dance or Nu Disco per
  track.
- **Untagged tracks:**
  - **Hand-tagging:** a "No Genre" view plus multi-select rename.
  - **Suggestions:** compare each untagged track's audio with the tagged ones and suggest the nearest
    family, which the user accepts or rejects. That learns the library's own taxonomy. Expect
    family-level accuracy only (House vs Techno vs Hip-Hop, not Deep vs Melodic House).
