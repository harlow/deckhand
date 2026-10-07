"""Exports Rekordbox beat grids for grid evaluation (deckhand-grid-eval).

Every Rekordbox-analyzed MP3 whose file exists: path, BPM, full PQTZ grid (bar position, ms), ID3 TBPM.
Requires pyrekordbox + sqlcipher3 and ffprobe.
Usage: python3 Scripts/export-grid-groundtruth.py rekordbox-grids.json
"""
import json, os, struct, subprocess, sys

from pyrekordbox import MasterDatabase

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


def tag_bpm(path):
    raw = subprocess.run(["ffprobe", "-v", "quiet", "-show_entries", "format_tags=TBPM", "-of", "json", path],
                         capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout
    t = {k.upper(): v for k, v in json.loads(raw or "{}").get("format", {}).get("tags", {}).items()}
    try:
        return float(t["TBPM"]) if t.get("TBPM") else None
    except ValueError:
        return None


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
    rows.append(dict(path=c.FolderPath, bpm=c.BPM / 100, bars=[b[0] for b in beats], beatsMs=[b[2] for b in beats],
                     tempos=sorted(set(b[1] for b in beats))))
for r in rows:
    r["tagBpm"] = tag_bpm(r["path"])
json.dump(rows, open(sys.argv[1], "w"))
print(f"wrote {len(rows)} tracks to {sys.argv[1]}")
