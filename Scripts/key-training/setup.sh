#!/bin/zsh
# Recreate the key-training workspace: Python env, S-KEY + GiantSteps checkouts, MIK labels, and the
# dataset downloads (~43 GB from Zenodo, 6 parallel connections, resumable). Then run pipeline.sh.
set -e
HERE=${0:A:h}
DATA=${KEY_DATA:-~/Data/deckhand-key}
mkdir -p $DATA/dl && cd $DATA
[ -d .venv ] || { uv venv -q -p 3.12 .venv && source .venv/bin/activate && uv pip install -q "torch==2.7.*" "torchaudio==2.7.*" \
  "numpy~=2.2.0" nnAudio==0.3.3 einops soundfile scipy tqdm coremltools; }
[ -d skey ] || git clone -q https://github.com/deezer/skey
[ -d giantsteps-key-dataset ] || git clone -q --depth 1 https://github.com/GiantSteps/giantsteps-key-dataset
(cd $HERE/../.. && swift build -c release --scratch-path .build-rel --product deckhand-eval)
[ -f mik.json ] || $HERE/../../.build-rel/release/deckhand-eval mik-keys mik.json
cd dl
B=https://zenodo.org/api/records
{
  for f in keys.zip audio.zip; do echo "$B/1095691/files/$f/content gs_$f"; echo "$B/1101082/files/$f/content bp_$f"; done
  echo "$B/10719860/files/fma_keys_metadata.csv/content fmak_meta.csv"
  for z in 000-019 020-039 040-049 050-059 060-069 070-079 080-089 090-099 100-109 110-124; do
    echo "$B/10719860/files/$z.zip/content fmak_$z.zip"
  done
} > urls.txt
nohup sh -c 'cat urls.txt | xargs -P 6 -L 1 sh -c '"'"'curl -sSL --retry 10 --retry-all-errors -C - -o "$1" "$0" && echo "done $1" || echo "FAILED $1"'"'"'; echo ALLDONE' > fetch.log 2>&1 &
echo "downloading into $DATA/dl (see fetch.log); now run: nohup $HERE/pipeline.sh > $DATA/pipeline.log &"
