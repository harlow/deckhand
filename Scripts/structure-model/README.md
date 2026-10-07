# Song-structure model

Trains `Sources/Analysis/StructureModelData.swift` against Rekordbox's phrase analysis (PSSI) from
the local Rekordbox library (read-only). Sections: intro / build ("Up") / breakdown ("Down") /
drop ("Chorus") / outro. Mid/low-mood tracks map verse → build, bridge → breakdown.

```sh
venv/bin/python -I Scripts/structure-model/export-pssi.py pssi.json            # PSSI + Rekordbox grids
swift build -c release --product deckhand-structure-eval
.build/release/deckhand-structure-eval dump pssi.json dump.jsonl               # per-beat features
SWIFT_OUT=Sources/Analysis/StructureModelData.swift venv/bin/python -I Scripts/structure-model/train.py dump.jsonl
.build/release/deckhand-structure-eval eval-dump dump.jsonl                    # Swift parity (bar-level, = train.py)
.build/release/deckhand-structure-eval eval pssi.json                          # full pipeline + named cues + cost
```

Bump `StructureAnalyzer.version` after retraining. Feature/decoder code in `StructureAnalyzer.swift`
mirrors `train.py`. Held-out set: album folders hashing into bucket 0–3 of 20 (`isHeldOut`), never trained on.
