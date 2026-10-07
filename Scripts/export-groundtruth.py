"""Exports Rekordbox-analyzed MP3s (BPM, key, beat grid) plus ID3 TBPM/TKEY as ground truth for deckhand-eval.

Requires pyrekordbox + sqlcipher3 (pip install pyrekordbox sqlcipher3-wheels) and ffprobe.
Usage: python3 Scripts/export-groundtruth.py out.json [count]
"""
import json, os, random, struct, subprocess, sys

from pyrekordbox import MasterDatabase

out, count = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 150
db = MasterDatabase()
share = os.path.expanduser("~/Library/Pioneer/rekordbox/share")


def pqtz(path):
    b = open(path, "rb").read()
    off = 28
    while off < len(b):
        tag, _, length = struct.unpack(">4sII", b[off:off + 12])
        if tag == b"PQTZ":
            n = struct.unpack(">I", b[off + 20:off + 24])[0]
            return [struct.unpack(">HHI", b[off + 24 + 8 * i:off + 32 + 8 * i]) for i in range(n)]
        off += length
    return None


def tags(path):
    raw = subprocess.run(["ffprobe", "-v", "quiet", "-show_entries", "format_tags=TBPM,TKEY", "-of", "json", path],
                         capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout
    t = {k.upper(): v for k, v in json.loads(raw or "{}").get("format", {}).get("tags", {}).items()}
    try:
        bpm = float(t["TBPM"]) if t.get("TBPM") else None
    except ValueError:
        bpm = None
    return bpm, (t.get("TKEY") or "").strip() or None


rows = []
for c in db.get_content().all():
    if not (c.BPM and c.FolderPath and c.AnalysisDataPath and c.FileType == 1 and os.path.exists(c.FolderPath)):
        continue
    if "PioneerDJ/Demo" in c.FolderPath or "Sampler" in c.FolderPath:
        continue
    dat = share + c.AnalysisDataPath
    beats = pqtz(dat) if os.path.exists(dat) else None
    if not beats:
        continue
    rows.append(dict(path=c.FolderPath, bpm=c.BPM / 100, key=c.Key.ScaleName if c.Key else None,
                     firstBeatMs=beats[0][2], firstBar=beats[0][0], beatTimesMs=[b[2] for b in beats[:64]]))

random.seed(7)
random.shuffle(rows)
rows = rows[:count]
for r in rows:
    r["tagBpm"], r["tagKey"] = tags(r["path"])
json.dump(rows, open(out, "w"))
print(f"wrote {len(rows)} tracks to {out}")
