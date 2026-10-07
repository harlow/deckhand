import json, sys, os, pickle, struct, base64, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from feats3 import *
from sklearn.ensemble import HistGradientBoostingClassifier, HistGradientBoostingRegressor

T = [json.loads(l) for l in open(sys.argv[1])]
T = [t for t in T if len(t['beats']) > 64 and t['feats'] and t['mikCues']]
train = [t for t in T if not t['heldOut']]
test = [t for t in T if t['heldOut']]


def mik_idx(t):
    ob = np.array(t['beats'])
    off = t.get('offset', 0.0)
    return [int(np.argmin(abs(ob - (c + off)))) for c, e in t['mikCues']]


def cue_rows(t):
    G = transform(t['feats'])
    X, cands = cue_features(G, t['bars'])
    lab = sorted(set(mik_idx(t)))
    y = np.array([int(any(abs(c - l) <= 1 for l in lab)) for c in cands])
    return X, y, cands, lab, G


def energy_rows(t, idx, G):
    td = track_desc(G, t['bpm'] or 120)
    rows = []
    for k, i in enumerate(idx):
        j = idx[k + 1] if k + 1 < len(idx) else min(len(G), i + 64)
        if j - i >= 4:
            rows.append(segment_features(G, i, j, td))
    return rows


# --- cue ranker
Xs, ys = [], []
for t in train:
    X, y, *_ = cue_rows(t)
    if len(X): Xs.append(X); ys.append(y)
X = np.vstack(Xs); y = np.concatenate(ys)
cue_model = HistGradientBoostingClassifier(max_iter=400, learning_rate=0.05, max_leaf_nodes=31, l2_regularization=1.0, random_state=0)
cue_model.fit(X, y)
print('cue features', X.shape[1])

# --- energy (segment) model, trained on MIK cue segments
Es, ey = [], []
for t in train:
    G = transform(t['feats'])
    idx = mik_idx(t); energies = [e for c, e in t['mikCues']]
    rows = energy_rows(t, idx, G)
    keep = [k for k in range(len(idx)) if (idx[k + 1] if k + 1 < len(idx) else min(len(G), idx[k] + 64)) - idx[k] >= 4]
    Es += rows; ey += [energies[k] for k in keep]
energy_model = HistGradientBoostingRegressor(max_iter=300, learning_rate=0.05, max_leaf_nodes=31, random_state=0)
energy_model.fit(np.array(Es), np.array(ey))
print('energy features', len(Es[0]))


def predict_track(t):
    G = transform(t['feats'])
    X, cands = cue_features(G, t['bars'])
    pred = select(cue_model.predict_proba(X)[:, 1], cands, len(G)) if len(X) else [0]
    segs = energy_rows(t, pred, G)
    e = np.clip(np.rint(energy_model.predict(np.array(segs))), 1, 10) if segs else np.array([6])
    srt = np.sort(e)
    track_e = srt[-2] if len(srt) > 1 else srt[-1]
    return pred, e, track_e


# --- evaluate
acc = {1: [0, 0, 0, 0], 4: [0, 0, 0, 0]}
cue_exact = cue_pm1 = cue_n = 0; te_exact = te_pm1 = 0; te_n = 0
for t in test:
    pred, e, track_e = predict_track(t)
    lab = mik_idx(t)
    for tol, a in acc.items():
        a[0] += sum(any(abs(p - l) <= tol for l in lab) for p in pred); a[1] += len(pred)
        a[2] += sum(any(abs(p - l) <= tol for p in pred) for l in lab); a[3] += len(lab)
    # energy of predicted cues that match a MIK cue (±1 beat)
    for p, pe in zip(pred, e):
        m = [k for k, l in enumerate(lab) if abs(p - l) <= 1]
        if m:
            me = t['mikCues'][m[0]][1]; cue_n += 1; cue_exact += pe == me; cue_pm1 += abs(pe - me) <= 1
    if t['mikEnergy']:
        te_n += 1; te_exact += track_e == t['mikEnergy']; te_pm1 += abs(track_e - t['mikEnergy']) <= 1
for tol, (TP, P, H, L) in acc.items():
    pr, rc = TP / P, H / L
    print(f'cues ±{tol} beat(s): precision {pr:.3f} recall {rc:.3f} F1 {2*pr*rc/(pr+rc):.3f} cues/track {P/len(test):.2f} (MIK {L/len(test):.2f})')
print(f'cue energy (matched cues): exact {cue_exact/cue_n:.3f} ±1 {cue_pm1/cue_n:.3f}')
print(f'track energy: exact {te_exact/te_n:.3f} ±1 {te_pm1/te_n:.3f}')

pickle.dump((cue_model, energy_model), open('model3.pkl', 'wb'))


# --- export trees: per node <f32 threshold-or-value, i32 feature (-1 leaf), i32 left, i32 right>
def export(model):
    blob = bytearray()
    trees = [p[0] for p in model._predictors]
    blob += struct.pack('<id', len(trees), float(np.ravel(model._baseline_prediction)[0]))
    for tr in trees:
        nodes = tr.nodes
        blob += struct.pack('<i', len(nodes))
        for nd in nodes:
            if nd['is_leaf']:
                blob += struct.pack('<fiii', float(nd['value']), -1, 0, 0)
            else:
                blob += struct.pack('<fiii', float(nd['num_threshold']), int(nd['feature_idx']), int(nd['left']), int(nd['right']))
    return base64.b64encode(bytes(blob)).decode()


open('cue_model.b64', 'w').write(export(cue_model))
open('energy_model.b64', 'w').write(export(energy_model))
# reference predictions for Swift parity tests
ref = test[0]
G = transform(ref['feats']); X, cands = cue_features(G, ref['bars'])
json.dump({'path': ref['path'], 'scores': cue_model.predict_proba(X)[:5, 1].tolist(), 'X0': X[0].tolist()}, open('parity.json', 'w'))
