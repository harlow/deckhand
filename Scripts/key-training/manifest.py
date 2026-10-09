"""Build manifest.json: every track with its key label, weight, source and split.

Splits
  test:  GiantSteps (original + GiantSteps+ labels), FMAK zips 060-069 and 110-124. Never trained or tuned on.
  val:   10% of Beatport EDM Key and of the FMAK training zips (by hash), library album folders with
         MD5 ≡ 0 (mod 5) (the split Scripts/train-key-model.py uses). Early stopping and α tuning.
  train: everything else. Beatport tracks whose Beatport ID or title is in GiantSteps are dropped, and so
         are library tracks whose title is in GiantSteps.
Labels: S-KEY index (0–11 major from A, 12–23 minor from B). Library labels are Mixed In Key's, with
confidence ≥ 0.8 only for training (weight `MIK_WEIGHT`); all MIK keys are kept for agreement evaluation.
"""
import csv, hashlib, json, os, re, zipfile

ROOT = os.environ.get("KEY_DATA", os.path.expanduser("~/Data/deckhand-key"))
PCS = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
MINOR = {"minor", "aeolian", "dorian", "phrygian", "locrian", "m"}
MAJOR = {"major", "ionian", "mixolydian", "lydian", ""}
FMAK_TEST = {"060-069", "110-124"}
MIK_WEIGHT = 0.5


def parse(text):
    """'G# major', 'Bb minor', 'Am', 'F#' -> (pitch class, minor) or None if ambiguous/unknown."""
    t = text.strip()
    if not t or "|" in t or "/" in t:
        return None
    m = re.fullmatch(r"([A-Ga-g])([#b♯♭]?)\s*(\w*).*", t)
    if not m:
        return None
    pc = (PCS[m.group(1).upper()] + {"#": 1, "♯": 1, "b": -1, "♭": -1}.get(m.group(2), 0)) % 12
    mode = m.group(3).lower()
    if mode in MINOR:
        return pc, True
    if mode in MAJOR:
        return pc, False
    return None


def skey_index(pc, minor):
    return 12 + (pc - 11) % 12 if minor else (pc - 9) % 12


def h(s, n=10):
    return int(hashlib.md5(s.encode()).hexdigest(), 16) % n


def norm_title(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())


items = []


def add(path, key, source, split, weight=1.0, **extra):
    if key is None:
        return
    items.append({"path": path, "label": skey_index(*key), "minor": key[1], "source": source, "split": split,
                  "weight": weight, **extra})


# GiantSteps: both label sets, test only.
gs_dir = os.path.join(ROOT, "gs/audio")
gs_ids, gs_titles = set(), set()
orig = os.path.join(ROOT, "giantsteps-key-dataset/annotations/key")
for f in sorted(os.listdir(gs_dir)):
    if not f.endswith(".mp3"):
        continue
    base = f[:-4]
    gid = base.split(" ")[0]
    gs_ids.add(gid)
    gs_titles.add(norm_title(base.split(" - ", 1)[-1]))
    plus = os.path.join(ROOT, "gs/keys_gs+", base + ".txt")
    if os.path.exists(plus):
        add(os.path.join(gs_dir, f), parse(open(plus, errors="replace").read()), "gs+", "test")
    o = os.path.join(orig, gid + ".LOFI.key")
    if os.path.exists(o):
        add(os.path.join(gs_dir, f), parse(open(o, errors="replace").read()), "gs", "test")

# Beatport EDM Key.
bp_dir = os.path.join(ROOT, "bp/audio")
if os.path.isdir(bp_dir):
    dropped = 0
    for f in sorted(os.listdir(bp_dir)):
        if not f.endswith(".mp3"):
            continue
        base = f[:-4]
        if base.split(" ")[0] in gs_ids or norm_title(base.split(" - ", 1)[-1]) in gs_titles:
            dropped += 1
            continue
        lab = os.path.join(ROOT, "bp/keys", base + ".txt")
        if os.path.exists(lab):
            add(os.path.join(bp_dir, f), parse(open(lab, errors="replace").read()), "bp", "val" if h(base) == 0 else "train")
    print(f"beatport: dropped {dropped} overlapping GiantSteps")

# FMAK: zip folder ranges; audio extracted to fmak/<folder>/<id>.mp3.
fmak_root = os.path.join(ROOT, "fmak")
ranges = {}
for z in os.listdir(os.path.join(ROOT, "dl")):
    m = re.fullmatch(r"fmak_(\d{3})-(\d{3})\.zip", z)
    if m:
        for folder in range(int(m.group(1)), int(m.group(2)) + 1):
            ranges[folder] = f"{m.group(1)}-{m.group(2)}"
for row in csv.DictReader(open(os.path.join(ROOT, "dl/fmak_meta.csv"))):
    tid = int(row["track_id"])
    folder = f"{tid // 1000:03d}"
    path = os.path.join(fmak_root, folder, f"{tid:06d}.mp3")
    if not os.path.exists(path):
        continue
    z = ranges.get(tid // 1000)
    split = "test" if z in FMAK_TEST else ("val" if h(str(tid)) == 0 else "train")
    add(path, parse(row["key_and_mode"]), "fmak", split)

# Library, labelled by Mixed In Key.
for r in json.load(open(os.path.join(ROOT, "mik.json"))):
    key = parse(r["key"])
    if key is None or not os.path.exists(r["path"]):
        continue
    album = os.path.dirname(r["path"])
    split = "val" if int(hashlib.md5(album.encode()).hexdigest(), 16) % 5 == 0 else "train"
    title = norm_title(os.path.splitext(os.path.basename(r["path"]))[0].split(" ", 1)[-1])
    if title in gs_titles:
        continue
    conf = r["conf"] or 0
    add(r["path"], key, "lib", split, weight=MIK_WEIGHT if conf >= 0.8 else 0.0, conf=conf)

json.dump(items, open(os.path.join(ROOT, "manifest.json"), "w"))
from collections import Counter
c = Counter((i["source"], i["split"]) for i in items)
for k in sorted(c):
    sub = [i for i in items if (i["source"], i["split"]) == k]
    print(k, c[k], f"minor {sum(i['minor'] for i in sub) / len(sub):.0%}")
