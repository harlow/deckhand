#!/usr/bin/env python3
"""Train Deckhand's key model and regenerate Sources/Analysis/KeyModelWeights.swift.

Training data:
  * human-labelled EDM key datasets (Beatport EDM Key, Faraldo/Camhi; Zenodo 1101082), and
  * the user's library labelled by Mixed In Key, weighted by MIK's own key confidence
    (MIK is wrong ~1 in 10; low-confidence labels count less).
GiantSteps Key (Zenodo 1095691 + github.com/GiantSteps/giantsteps-key-dataset) is used only for
evaluation; library tracks whose titles appear in it are excluded from training.

1. Dump features (chromagrams via the shipping KeyAnalyzer path):
     swift build -c release --product deckhand-eval
     .build/release/deckhand-eval key-features ~/Music/Music/Media.localized/Music lib/
     .build/release/deckhand-eval key-features-dataset <beatport>/audio <beatport>/keys bp/
     .build/release/deckhand-eval key-features-dataset <giantsteps>/audio <giantsteps>/keys_gs+ gs/
2. Export MIK confidences as JSON [{"path", "conf"}] (mik.json).
3. python3 Scripts/train-key-model.py lib/ mik.json --human bp/ [--eval gs/ [--eval-labels <dir of .key files>]]
   (needs numpy, scipy)

Model: one linear weight vector per mode over the 72-band √-mean chroma, applied to the chroma
rotated to each of 12 candidate tonics (rotation-equivariant multinomial logistic regression).
Library held-out split: album folders whose MD5 ≡ 0 (mod 5). The shipped model trains on everything.
"""
import argparse, hashlib, json, os, re
import numpy as np
from scipy.optimize import minimize

SCALE, L2 = 30, 1e-3
OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "Analysis", "KeyModelWeights.swift")
PCS = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
MINOR = {"minor", "aeolian", "dorian", "phrygian", "locrian"}
MAJOR = {"major", "ionian", "mixolydian", "lydian"}
WEIGHT = {"exact": 1, "fifth": .5, "relative": .3, "parallel": .2, "other": 0}


def camelot(s):
    n, minor = int(s[:-1]), s[-1] == "A"
    rel = ((n - 8) % 12) * 7 % 12
    return ((rel + 9) % 12 if minor else rel) * 2 + int(minor)


def parse_label(text):
    """'F minor', 'Eb major', 'C# minor aeolian' -> class; None for unknown, ambiguous or modal-only labels."""
    t = text.strip()
    if not t or "|" in t or "/" in t or t.upper() in ("X", "-"):
        return None
    parts = t.replace(",", " ").split()
    m = re.fullmatch(r"([A-Ga-g])([#b]?)", parts[0])
    if not m or len(parts) < 2:
        return None
    pc = PCS[m.group(1).upper()] + {"#": 1, "b": -1}.get(m.group(2), 0)
    mode = parts[1].lower()
    if mode not in MINOR | MAJOR:
        return None
    return (pc % 12) * 2 + int(mode in MINOR)


def relation(p, t):
    (pt, pm), (tt, tm) = divmod(p, 2), divmod(t, 2)
    if p == t: return "exact"
    if pm != tm and ((not tm and pt == (tt + 9) % 12) or (tm and pt == (tt + 3) % 12)): return "relative"
    if pm == tm and (pt - tt) % 12 in (5, 7): return "fifth"
    if pm != tm and pt == tt: return "parallel"
    return "other"


def report(name, pred, truth):
    if not truth:
        return
    rel = [relation(p, t) for p, t in zip(pred, truth)]
    n = len(rel)
    cols = " ".join(f"{k} {100 * rel.count(k) / n:5.1f}" for k in WEIGHT)
    print(f"{name:16s} n={n:4d} {cols}  MIREX {100 * sum(WEIGHT[r] for r in rel) / n:5.1f}")


def profile(root, i):
    a = np.fromfile(f"{root}/{i}.f32", dtype=np.float32).reshape(-1, 72).astype(np.float64)
    v = np.sqrt(a).mean(0)
    return v / (np.linalg.norm(v) + 1e-12) * SCALE


def rotations(X):
    return np.stack([np.roll(X, -k, axis=1) for k in range(12)], 1)


def fit(R, y, w):
    n = len(y)
    w = np.asarray(w, float) / np.mean(w)
    Y = np.zeros((n, 24)); Y[np.arange(n), y] = 1
    def loss(th):
        W, b = th[:144].reshape(2, 72), th[144:]
        S = (np.einsum("nkd,md->nkm", R, W) + b).reshape(n, 24)
        S -= S.max(1, keepdims=True); P = np.exp(S); P /= P.sum(1, keepdims=True)
        G = (w[:, None] * (P - Y) / n).reshape(n, 12, 2)
        L = -(w * np.log(P[np.arange(n), y] + 1e-12)).mean() + 0.5 * L2 * (W ** 2).sum()
        return L, np.concatenate([(np.einsum("nkm,nkd->md", G, R) + L2 * W).ravel(), G.sum((0, 1))])
    th = minimize(loss, np.zeros(146), jac=True, method="L-BFGS-B", options={"maxiter": 2000}).x
    return th[:144].reshape(2, 72), th[144:]


def predict(R, W, b):
    return list((np.einsum("nkd,md->nkm", R, W) + b).reshape(len(R), 24).argmax(1))


def held(path):
    return int(hashlib.md5(os.path.dirname(path).encode()).hexdigest(), 16) % 5 == 0


def title(path):
    b = re.sub(r"^\d+\s+", "", os.path.splitext(os.path.basename(path))[0])
    b = re.sub(r"\(.*?\)|\[.*?\]", "", b)
    return re.sub(r"[^a-z0-9]", "", b.lower().split(" - ")[-1])


def load_dataset(root, labels_dir=None):
    """Entries (path, X, y) from a key-features-dataset dump; labels from the dump or a .key-file dir."""
    alt = {}
    if labels_dir:
        alt = {f.split(".")[0]: open(os.path.join(labels_dir, f)).read() for f in os.listdir(labels_dir) if f.endswith(".key")}
    out = []
    for e in json.load(open(f"{root}/index.json")):
        text = alt.get(os.path.basename(e["path"]).split()[0]) if labels_dir else e["label"]
        y = parse_label(text) if text else None
        if y is not None:
            out.append((e["path"], profile(root, e["i"]), y))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("library")
    ap.add_argument("mik")
    ap.add_argument("--human", action="append", default=[])
    ap.add_argument("--eval", action="append", default=[])
    ap.add_argument("--eval-labels")
    args = ap.parse_args()

    conf = {m["path"]: m["conf"] for m in json.load(open(args.mik))}
    lib = [(e["path"], profile(args.library, e["i"]), camelot(e["tag"]), conf.get(e["path"], 0.5))
           for e in json.load(open(f"{args.library}/index.json"))]
    human = [x for root in args.human for x in load_dataset(root)]
    evals = [(os.path.basename(os.path.normpath(r)), load_dataset(r, args.eval_labels)) for r in args.eval]
    eval_titles = {title(p) for _, ds in evals for p, _, _ in ds}
    lib = [t for t in lib if title(t[0]) not in eval_titles]
    human = [t for t in human if title(t[0]) not in eval_titles]

    def train(lib_part):
        X = np.array([x for _, x, _ in human] + [x for _, x, _, _ in lib_part])
        y = np.array([y for _, _, y in human] + [y for _, _, y, _ in lib_part])
        w = np.array([1.0] * len(human) + [max(0.1, c) for *_, c in lib_part])
        return fit(rotations(X), y, w)

    W, b = train([t for t in lib if not held(t[0])])
    test = [t for t in lib if held(t[0])]
    pred = predict(rotations(np.array([x for _, x, _, _ in test])), W, b)
    truth = [y for _, _, y, _ in test]
    report("library held-out", pred, truth)
    for name, keep in [("MIK conf>=0.8", lambda c: c >= 0.8), ("MIK conf<0.5", lambda c: c < 0.5)]:
        sel = [i for i, t in enumerate(test) if keep(t[3])]
        report(name, [pred[i] for i in sel], [truth[i] for i in sel])
    for name, ds in evals:
        report(name, predict(rotations(np.array([x for _, x, _ in ds])), W, b), [y for _, _, y in ds])

    W, b = train(lib)
    row = lambda v: "[" + ", ".join(f"{x:.6g}" for x in v) + "]"
    with open(OUT, "w") as f:
        f.write(f"""// Generated by Scripts/train-key-model.py. Do not edit by hand.
// Trained on {len(human)} human-labelled EDM tracks (Beatport EDM Key) and {len(lib)} library tracks labelled by
// Mixed In Key (weighted by MIK confidence); input: 72-band libKeyFinder chroma (C1–B6).
enum KeyModelWeights {{
    static let inputScale: Double = {SCALE}
    static let output: [[Double]] = [
        {row(W[0])},
        {row(W[1])},
    ]
    static let outputBias: [Double] = {row(b)}
}}
""")
    print(f"wrote {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
