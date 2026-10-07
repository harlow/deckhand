# Cue / energy model

Trains `Sources/Analysis/CueModelData.swift` against Mixed In Key's cue points and energy levels
(read-only from MIK 11's database via `MixedInKeyLibrary`).

```sh
swift build -c release --product deckhand-cue-eval
.build/release/deckhand-cue-eval dump features.jsonl          # per-beat features + MIK labels, all MIK tracks
python3 -m venv venv && venv/bin/pip install numpy scikit-learn
venv/bin/python Scripts/cue-model/model3.py features.jsonl     # trains, prints held-out metrics,
                                                               # writes cue_model.b64 / energy_model.b64
# paste the two base64 strings into Sources/Analysis/CueModelData.swift, bump CueAnalyzer.version
.build/release/deckhand-cue-eval eval-dump features.jsonl     # Swift parity check (should match Python)
.build/release/deckhand-cue-eval eval 120                      # full pipeline from audio, with timing
```

`feats3.py` must stay in sync with the feature code in `CueAnalyzer.swift`. The held-out set
(~20%, by path hash in `deckhand-cue-eval`) is never used for training.
