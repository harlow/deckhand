# S-KEY fine-tuning

Fine-tunes S-KEY's ChromaNet (Deezer, MIT) on human key labels and re-tunes Deckhand's key ensemble.
The architecture stays the same, so the Swift CQT front-end and Core ML export don't change.

The workspace defaults to `~/Data/deckhand-key` (override with `KEY_DATA`). It needs about 60 GB.

1. `./setup.sh` sets up the Python env, the deezer/skey and GiantSteps label checkouts, and Mixed In Key
   labels (`deckhand-eval mik-keys`). It also starts the downloads: GiantSteps+ (Zenodo 1095691),
   Beatport EDM Key (1101082) and FMAK (10719860), about 43 GB.
2. `nohup ./pipeline.sh > $KEY_DATA/pipeline.log &` unpacks each download as it arrives. It runs
   `manifest.py` (labels and splits), `prep.py` (per-clip 99-bin VQT for training) and
   `deckhand-eval key-dump`. The dump records the shipping Swift ensemble's inputs for test and
   validation tracks: linear log-probabilities, S-KEY probabilities, and the exact 84×646 clips.
   The pipeline stops by itself when everything is done.
3. Train: `python train.py runs/B.pt --epochs 40 --steps 200 --patience 10 --balance 1.0 --lr 3e-4 --seed 1`.
   This is the shipped configuration. It takes about 2 minutes per epoch on an M4 GPU and stops early
   on the validation score.
4. Tune the ensemble on validation only: `python evaluate.py runs/B.pt --val-only --tune --tune-bias`.
5. Test, once: `python evaluate.py runs/B.pt --alpha A --bias B`. Then export with
   `python ../export-skey.py $KEY_DATA/skey runs/B.pt`, set `KeyAnalyzer.skeyWeight`/`minorBias`, and
   bump `TrackAnalysis.currentVersion`. Check parity by running `key-dump` again with the new model.

Splits (see `manifest.py`):

- **Test, never trained or tuned on:** GiantSteps (original and + labels) and FMAK zips 060-069 and 110-124.
- **Validation:** 10% of Beatport and of the FMAK training zips, plus library album folders with
  MD5 ≡ 0 (mod 5).
- **Excluded from training:** Beatport tracks that overlap GiantSteps by ID or title.

The shipped linear model was trained on all of Beatport and the library. Its validation numbers on
those two sets are therefore optimistic, which is why α tuning also uses FMAK val.

Results from 2026-10-08 are in `docs/status.md`.
