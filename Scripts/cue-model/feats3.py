# Shared feature definitions for cue ranking and energy (mirrored in Swift CueAnalyzer.swift).
import numpy as np

EPS = 1e-4
WIN = [4, 8, 16, 32]
STEP = 4
N_ENV = 6           # low mid high rms peak flux (linear) -> log
N_BAND = 10         # already log10 power
# cols 16,17: flatness, onsets (linear, positive) -> log


def transform(F):
    G = np.array(F, float).copy()
    G[:, :N_ENV] = np.log(G[:, :N_ENV] + EPS)
    G[:, N_ENV + N_BAND:] = np.log(G[:, N_ENV + N_BAND:] + EPS)
    return G


def boundary(G, c, n):
    out = []
    for w in WIN:
        a = G[max(0, c - w):c].mean(0)
        b = G[c:min(n, c + w)].mean(0)
        out.append(b - a)
        out.append(b)
    return np.concatenate(out)


def candidates(n):
    return list(range(STEP, n - 16, STEP))


def cue_features(G, bars):
    n = len(G)
    cands = candidates(n)
    if not cands:
        return np.zeros((0, 0)), cands
    B = np.array([boundary(G, c, n) for c in cands])
    mu, sd = B.mean(0), B.std(0) + 1e-6
    Z = (B - mu) / sd
    nov = np.abs(B[:, [0, 3, 2]]).sum(1)          # |Δlow|+|Δrms|+|Δhigh|, 1-bar window
    res = np.array([c % 16 for c in cands])
    cls = np.array([nov[res == r].mean() if (res == r).any() else 0.0 for r in range(16)])
    cls_rank = cls / (cls.max() + 1e-9)
    rms = G[:, 3]
    thr = np.log(0.1) + np.median(rms)
    fa = next((i for i, v in enumerate(rms) if v > thr), 0)
    numax = nov.max() + 1e-9
    fd = next((i for i, b in enumerate(bars[:n]) if b == 1), 0)
    X = []
    for j, c in enumerate(cands):
        r = c % 16
        X.append(np.concatenate([B[j], Z[j], [
            c / n, (c / n) ** 2, float(r == 0), float(r == 8), float(r % 4 == 0), float(c % 32 == 0),
            cls_rank[r], float(cls_rank[r] == 1.0), float((c - fa) % 16 == 0), nov[j] / numax,
            float(bars[c] == 1), float((c - fd) % 16 == 0), float((c - fd) % 32 == 0),
        ]]))
    return np.array(X), cands


def select(scores, cands, n, k=7, min_gap=32, max_pos=0.9):
    chosen = []
    for o in np.argsort(-np.asarray(scores), kind='stable'):
        c = cands[o]
        if c / n > max_pos:
            continue
        if all(abs(c - x) >= min_gap for x in chosen):
            chosen.append(c)
        if len(chosen) == k:
            break
    return sorted([0] + chosen)


def track_desc(G, bpm):
    out = []
    for j in range(G.shape[1]):
        out += list(np.percentile(G[:, j], [25, 50, 75, 90]))
    out += [np.log(bpm + 1)]
    return np.array(out)


def segment_features(G, a, b, td):
    seg = G[a:b]
    m = seg.mean(0)
    rel = m - td[1:4 * G.shape[1]:4]                # vs track medians
    return np.concatenate([m, seg[:, 3].max(keepdims=True), rel, [np.log(b - a)], td])
