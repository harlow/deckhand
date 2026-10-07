"""Exports Rekordbox phrase analysis (PSSI) as ground truth for structure models.

For every track in the local Rekordbox library whose .EXT has a PSSI tag, writes
{path, mood, endBeat, phrases: [[startBeat, kind]], beatTimesMs: [...]} where beat numbers are
1-based indices into Rekordbox's own beat grid (PQTZ in the .DAT), whose times are included.

Usage: python3 -I Scripts/structure-model/export-pssi.py out.json   (needs pyrekordbox + sqlcipher3)
"""
import json, os, struct, sys

from pyrekordbox import MasterDatabase
from pyrekordbox.anlz import AnlzFile

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


rows = []
for c in MasterDatabase().get_content().all():
    if not (c.FolderPath and c.AnalysisDataPath and os.path.exists(c.FolderPath)):
        continue
    if "PioneerDJ/Demo" in c.FolderPath or "Sampler" in c.FolderPath:
        continue
    dat = share + c.AnalysisDataPath
    ext = dat[:-3] + "EXT"
    if not (os.path.exists(dat) and os.path.exists(ext)):
        continue
    tags = [t for t in AnlzFile.parse_file(ext).tags if t.type == "PSSI"]
    if not tags:
        continue
    p = tags[0].content
    beats = pqtz(dat)
    if not beats or not p.entries:
        continue
    rows.append(dict(path=c.FolderPath, mood=int(p.mood), endBeat=int(p.end_beat),
                     phrases=[[int(e.beat), int(e.kind)] for e in p.entries],
                     bars=[b[0] for b in beats], beatTimesMs=[b[2] for b in beats]))

json.dump(rows, open(sys.argv[1], "w"))
print(f"wrote {len(rows)} tracks")
