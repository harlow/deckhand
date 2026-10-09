#!/bin/zsh
# Unpack downloads as they finish; keep prep.py (train/val) and the Swift key-dump (test + library val) fed.
HERE=${0:A:h}
cd ${KEY_DATA:-~/Data/deckhand-key}
source .venv/bin/activate
EVAL=${HERE:h:h}/.build-rel/release/deckhand-eval
while true; do
  for z in $(grep '^done ' dl/fetch.log | awk '{print $2}'); do
    [ -e "dl/.unzipped_$z" ] && continue
    case $z in
      bp_audio.zip|bp_keys.zip) unzip -q -o "dl/$z" -d bp ;;
      fmak_*.zip) unzip -q -o "dl/$z" -d fmak ;;
      *) touch "dl/.unzipped_$z"; continue ;;
    esac && touch "dl/.unzipped_$z" && echo "$(date +%T) unzipped $z"
  done
  python3 $HERE/manifest.py > manifest.log
  python3 -c "
import json; m=json.load(open('manifest.json'))
open('prep_paths.txt','w').write('\n'.join(sorted({i['path'] for i in m if i['split'] in ('train','val')}))+'\n')
open('dump_paths.txt','w').write('\n'.join(sorted({i['path'] for i in m if i['split'] in ('test','val')}))+'\n')"
  alive() { [ -f "$1" ] && kill -0 $(cat "$1") 2>/dev/null }
  if ! alive prep.pid; then
    echo "$(date +%T) prep start"; PREP_WORKERS=6 nohup python $HERE/prep.py prep_paths.txt cqt >> prep.log 2>&1 & echo $! > prep.pid
  fi
  if ! alive dump.pid; then
    echo "$(date +%T) dump start"; KEY_EVAL_WORKERS=3 nohup $EVAL key-dump dump_paths.txt dump >> dump.log 2>&1 & echo $! > dump.pid
  fi
  grep -q ALLDONE dl/fetch.log && [ $(grep -c '^done ' dl/fetch.log) -le $(/bin/ls -a dl | grep -c '^.unzipped_') ] && ! alive prep.pid && ! alive dump.pid && { echo "$(date +%T) PIPELINE DONE"; break; }
  sleep 120
done
