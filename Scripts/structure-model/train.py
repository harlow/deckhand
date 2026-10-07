"""Trains Deckhand's song-structure model against Rekordbox phrase analysis (PSSI).

Input: deckhand-structure-eval dump output (per-beat features on Deckhand's grid + PSSI phrases on
Rekordbox's grid). Each 4-beat block (bar) starting from the first downbeat gets features; a
gradient-boosted classifier gives per-bar section posteriors; Viterbi decoding (section changes cheap
on 4-bar phrase lines from the first downbeat, penalized elsewhere; learned transition grammar) turns
them into sections.

Feature and decoding code must match StructureAnalyzer.swift exactly.

Usage: SWIFT_OUT=Sources/Analysis/StructureModelData.swift python3 -I Scripts/structure-model/train.py dump.jsonl
Env: ITERS (100), LR (0.12), LEAVES (24).
"""
import base64, json, os, struct, sys

import numpy as np
from sklearn.ensemble import HistGradientBoostingClassifier

EPS = 1e-4
N_ENV, N_BAND = 6, 10
CTX = [-16, -8, -4, 4, 8, 16]
KINDS = ["intro", "build", "breakdown", "drop", "outro"]
PHRASE = 4   # bars; section changes only every PHRASE bars


def pssi_kind(k, mood):
    if k == 1: return 0
    if mood == 1:
        return {2: 1, 3: 2, 5: 3, 6: 4}.get(k)
    if 2 <= k <= 7: return 1
    return {8: 2, 9: 3, 10: 4}.get(k)


def transform(F, R=None):
    """Per-beat matrix: CueFeatures rows (log where linear) plus RhythmFeatures columns."""
    G = np.array(F, float).copy()
    G[:, :N_ENV] = np.log(G[:, :N_ENV] + EPS)
    G[:, N_ENV + N_BAND:] = np.log(G[:, N_ENV + N_BAND:] + EPS)
    if R is not None:
        R = np.array(R, float)[:len(G)]
        G = np.hstack([G, R])
    return G


def first_downbeat(bars):
    return next((i for i, b in enumerate(bars) if b == 1), 0)


def blocks(n_beats, fd):
    """Bar start indices: whole bars from the first downbeat; a leading partial bar if fd > 0."""
    starts = ([0] if fd > 0 else []) + list(range(fd, n_beats - 3, 4))
    return starts


def bar_matrix(G, starts, n):
    return np.array([G[s:min(n, s + 4)].mean(0) for s in starts])


def features(G, bars):
    n = len(G)
    fd = first_downbeat(bars)
    starts = blocks(n, fd)
    B = bar_matrix(G, starts, n)                       # bars x 18
    m = len(B)
    med = np.median(B, 0)
    sd = B.std(0) + 1e-6
    Z = (B - med) / sd
    top = np.percentile(B[:, 3], 90)                   # loud-section reference for rms
    rows = []
    for i in range(m):
        ctx = []
        for w in CTX:
            a, b = (i + w, i) if w < 0 else (i + 1, i + 1 + w)
            a, b = max(0, a), min(m, b)
            seg = Z[a:b].mean(0) if b > a else Z[i]
            ctx.append(seg - Z[i])
        prev = Z[i] - Z[i - 1] if i > 0 else np.zeros(Z.shape[1])
        k = i - (1 if fd > 0 else 0)
        rows.append(np.concatenate([
            Z[i], B[i] - med, prev, *ctx,
            [i / m, (m - i) / m, np.log1p(i), np.log1p(m - i), B[i, 3] - top,
             float(k % 4 == 0), float(k % 8 == 0), float(k % 16 == 0)],
        ]))
    return np.array(rows), starts


def labels(t, starts, beats):
    rb = t["rbBeatsMs"]
    ph = [(rb[b - 1], pssi_kind(k, t["mood"])) for b, k in t["phrases"] if 0 < b <= len(rb)]
    ph = [(ms, k) for ms, k in ph if k is not None]
    if not ph:
        return None
    end_ms = rb[min(len(rb), t["endBeat"]) - 1]
    y = []
    for i, s in enumerate(starts):
        e = starts[i + 1] if i + 1 < len(starts) else len(beats) - 1
        mid = 1000 * (beats[s] + beats[min(e, len(beats) - 1)]) / 2
        if mid < ph[0][0] or mid > end_ms:
            y.append(-1)
            continue
        y.append([k for ms, k in ph if ms <= mid][-1])
    return np.array(y)


def transitions(Y):
    """Phrase-boundary transition log-probs (5x5) from training label sequences, with grammar."""
    C = np.ones((5, 5))
    for y in Y:
        z = [v for v in y if v >= 0]
        for i in range(PHRASE, len(z), PHRASE):
            C[z[i - PHRASE], z[i]] += 1
    C[:, 0] = 1e-3          # never return to intro
    C[0, 0] += 50
    C[4, :4] = 1e-3         # outro is final
    P = C / C.sum(1, keepdims=True)
    start = np.array([0.80, 0.08, 0.04, 0.08, 1e-3])
    return np.log(P), np.log(start)


ALPHA, OFF_PHASE, PRIOR_W = 2.0, -2.0, 1.0


def decode(logpost, logprior, A, start, k0):
    """Viterbi over bars. Section changes are cheap on 4-bar phrase lines counted from the first
    downbeat (bar k0) and penalized elsewhere; emissions are posteriors divided by class priors."""
    m = len(logpost)
    emit = ALPHA * (logpost - PRIOR_W * logprior)
    Aoff = A.copy()
    Aoff[~np.eye(5, dtype=bool)] += OFF_PHASE
    V = start + emit[0]
    back = []
    for i in range(1, m):
        M = A if (i - k0) % PHRASE == 0 else Aoff
        S = V[:, None] + M
        back.append(S.argmax(0))
        V = S.max(0) + emit[i]
    path = [int(V.argmax())]
    for b in reversed(back):
        path.append(int(b[path[-1]]))
    return path[::-1]


def smooth(path, min_run=4):
    """Absorbs runs shorter than min_run bars into the previous section."""
    p = list(path)
    i = 0
    while i < len(p):
        j = i
        while j < len(p) and p[j] == p[i]:
            j += 1
        if j - i < min_run and i > 0:
            p[i:j] = [p[i - 1]] * (j - i)
        i = j
    return p


def onsets(seq):
    """Section starts (bar index, kind), ignoring the first."""
    return [(i, k) for i, k in enumerate(seq) if i > 0 and k != seq[i - 1] and k >= 0]


class Metrics:
    def __init__(self):
        self.ok = self.n = 0
        self.b = [0, 0, 0, 0]
        self.o = {2: [0, 0, 0, 0], 3: [0, 0, 0, 0]}

    def add(self, pred, y):
        m = y >= 0
        self.ok += (pred[m] == y[m]).sum(); self.n += m.sum()
        lo, hi = np.argmax(m), len(m) - np.argmax(m[::-1])
        p, t = list(pred[lo:hi]), list(y[lo:hi])
        po, to = onsets(p), onsets(t)
        def acc(st, P, T):
            st[0] += sum(any(abs(i - j) <= 1 for j, _ in T) for i, _ in P); st[1] += len(P)
            st[2] += sum(any(abs(i - j) <= 1 for j, _ in P) for i, _ in T); st[3] += len(T)
        acc(self.b, po, to)
        for k in (2, 3):
            acc(self.o[k], [x for x in po if x[1] == k], [x for x in to if x[1] == k])

    def report(self, name):
        def f(st):
            p, r = st[0] / max(1, st[1]), st[2] / max(1, st[3])
            return f"P {p:.3f} R {r:.3f} F1 {2*p*r/(p+r+1e-9):.3f}"
        print(f"[{name}] bar acc {self.ok/self.n:.3f} | boundaries {f(self.b)} | breakdown {f(self.o[2])} | drop {f(self.o[3])}")


def export(model):
    blobs = []
    pred = model._predictors
    base = np.ravel(model._baseline_prediction)
    for k in range(len(KINDS)):
        blob = bytearray(struct.pack('<id', len(pred), float(base[k])))
        for it in pred:
            nodes = it[k].nodes
            blob += struct.pack('<i', len(nodes))
            for nd in nodes:
                if nd['is_leaf']:
                    blob += struct.pack('<fiii', float(nd['value']), -1, 0, 0)
                else:
                    blob += struct.pack('<fiii', float(nd['num_threshold']), int(nd['feature_idx']), int(nd['left']), int(nd['right']))
        blobs.append(base64.b64encode(bytes(blob)).decode())
    return blobs


def main():
    path = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) > 2 else "."
    tracks = [json.loads(l) for l in open(path) if l.strip()]
    train_X, train_y, tests = [], [], []
    for t in tracks:
        G = transform(t["feats"], t.get("rhythm"))
        X, starts = features(G, t["bars"])
        y = labels(t, starts, t["beats"])
        if y is None or len(X) < 16:
            continue
        rec = dict(t=t, X=X, y=y, starts=starts)
        if t["heldOut"]:
            tests.append(rec)
        else:
            train_X.append(X); train_y.append(y)
    print(f"train tracks {len(train_X)}  held-out tracks {len(tests)}  features {train_X[0].shape[1]}")
    params = dict(max_iter=int(os.environ.get("ITERS", 100)), learning_rate=float(os.environ.get("LR", 0.12)),
                  max_leaf_nodes=int(os.environ.get("LEAVES", 24)), l2_regularization=1.0, random_state=0)
    Xtr = np.vstack([x[y >= 0] for x, y in zip(train_X, train_y)]); ytr = np.concatenate([y[y >= 0] for y in train_y])
    model = HistGradientBoostingClassifier(**params).fit(Xtr, ytr)
    prior = np.bincount(ytr, minlength=5) / len(ytr)
    A, start = transitions(train_y)

    raw, dec = Metrics(), Metrics()
    for r in tests:
        lp = np.log(model.predict_proba(r["X"]) + 1e-9)
        k0 = 1 if first_downbeat(r["t"]["bars"]) > 0 else 0
        raw.add(lp.argmax(1), r["y"])
        dec.add(np.array(decode(lp, np.log(prior), A, start, k0)), r["y"])
    raw.report("held-out raw")
    dec.report("held-out decoded")

    blobs = export(model)
    def arr(v):
        return "[" + ", ".join(f"{x:.6f}" for x in v) + "]"
    swift = ["// Generated by Scripts/structure-model/train.py — do not edit.", "", "enum StructureModelData {",
             "    /// One gradient-boosted ensemble per class (intro, build, breakdown, drop, outro); softmax of raw scores.",
             "    static let classes: [String] = ["]
    swift += [f'        "{b}",' for b in blobs]
    swift += ["    ]", "    /// Log class priors over training bars.", f"    static let logPrior: [Double] = {arr(np.log(prior))}",
              "    /// Log start probabilities.", f"    static let logStart: [Double] = {arr(start)}",
              "    /// Log transition matrix at phrase boundaries (row = from, column = to).",
              "    static let logTransition: [[Double]] = ["]
    swift += [f"        {arr(row)}," for row in A]
    swift += ["    ]", "}", ""]
    out = os.environ.get("SWIFT_OUT", f"{outdir}/StructureModelData.swift")
    open(out, "w").write("\n".join(swift))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
