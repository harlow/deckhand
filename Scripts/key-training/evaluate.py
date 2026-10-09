"""Evaluate Deckhand's key ensemble on the Swift dumps (deckhand-eval key-dump), optionally with a
fine-tuned ChromaNet in place of the shipped one.

usage: python evaluate.py [checkpoint.pt] [--alpha A] [--tune] [--bias B]
  The ensemble is log p_linear + α · log p_skey (+ B added to minor keys' scores).
  --tune picks α (and B with --tune-bias) on the validation dumps (Beatport val + library val).
Test sets: GiantSteps (orig labels), GiantSteps+, FMAK test zips; library: agreement with Mixed In Key
(confidence ≥ 0.8, held-out album folds).
"""
import argparse, json, os, sys

import numpy as np
import torch

ROOT = os.environ.get("KEY_DATA", os.path.expanduser("~/Data/deckhand-key"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from train import logits, mirex  # noqa: E402

# S-KEY index -> Deckhand index (tonic * 2 + minor, tonic 0 = C); same as SKey.deckhandIndex.
D = [((9 + i) % 12) * 2 if i < 12 else ((11 + i - 12) % 12) * 2 + 1 for i in range(24)]
S = [D.index(d) for d in range(24)]  # Deckhand index -> S-KEY index


def load_dump():
    rows = {}
    for line in open(os.path.join(ROOT, "dump/index.jsonl")):
        r = json.loads(line)
        rows[r["path"]] = r
    return rows


def skey_probs(net, rows, device):
    """Fine-tuned ChromaNet on the exact clips Swift fed the shipped model; Deckhand order."""
    out = {}
    net.eval()
    with torch.no_grad():
        for path, r in rows.items():
            if not r["clips"]:
                continue
            a = np.fromfile(os.path.join(ROOT, "dump", r["file"]), dtype=np.float16).reshape(r["clips"], 1, 84, 646)
            p = torch.softmax(logits(net, torch.from_numpy(a.astype(np.float32)).to(device)), -1).mean(0).cpu().numpy()
            out[path] = p[S]
    return out


def predict(row, skey, alpha, bias):
    s = np.array(row["linear"], dtype=np.float64)
    p = skey.get(row["path"]) if skey is not None else (np.array(row["skey"]) if row["skey"] else None)
    if p is not None:
        s = s + alpha * np.log(np.maximum(p, 1e-6))
    s[1::2] += bias
    return int(s.argmax())


def metrics(pairs):
    """pairs of (pred, truth) in Deckhand index."""
    n = max(1, len(pairs))
    to_s = lambda d: S[d]
    exact = sum(p == t for p, t in pairs) / n
    mx = sum(mirex(to_s(p), to_s(t)) for p, t in pairs) / n
    maj = [(p, t) for p, t in pairs if t % 2 == 0]
    mnr = [(p, t) for p, t in pairs if t % 2 == 1]
    rec = lambda xs: sum(p == t for p, t in xs) / max(1, len(xs))
    return {"n": len(pairs), "exact": exact, "mirex": mx, "major": rec(maj), "minor": rec(mnr)}


def groups(manifest, rows):
    g = {}
    for i in manifest:
        if i["path"] not in rows:
            continue
        truth = D[i["label"]]
        if i["split"] == "test":
            name = {"gs": "GiantSteps", "gs+": "GiantSteps+", "fmak": "FMAK test"}[i["source"]]
        elif i["source"] == "lib" and i["split"] == "val":
            name = "MIK agree (conf>=0.8, held-out)" if i.get("conf", 0) >= 0.8 else "MIK agree (conf<0.8, held-out)"
        elif i["source"] == "bp" and i["split"] == "val":
            name = "Beatport val"
        elif i["source"] == "fmak" and i["split"] == "val":
            name = "FMAK val"
        else:
            continue
        g.setdefault(name, []).append((rows[i["path"]], truth))
    return g


def evaluate(g, skey, alpha, bias):
    return {k: metrics([(predict(r, skey, alpha, bias), t) for r, t in v]) for k, v in g.items()}


VAL = ("Beatport val", "FMAK val", "MIK agree (conf>=0.8, held-out)")


def val_score(res):
    """The shipped linear model trained on all of Beatport and the library, so those two flatter it;
    FMAK val is clean."""
    return 0.4 * res["Beatport val"]["mirex"] + 0.3 * res["FMAK val"]["mirex"] + 0.3 * res["MIK agree (conf>=0.8, held-out)"]["exact"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("checkpoint", nargs="?")
    ap.add_argument("--alpha", type=float, default=0.7)
    ap.add_argument("--bias", type=float, default=0.0)
    ap.add_argument("--tune", action="store_true")
    ap.add_argument("--tune-bias", action="store_true")
    ap.add_argument("--val-only", action="store_true", help="don't look at the test sets")
    args = ap.parse_args()
    manifest = json.load(open(os.path.join(ROOT, "manifest.json")))
    rows = load_dump()
    skey = None
    if args.checkpoint:
        sys.path.insert(0, os.path.join(ROOT, "skey"))
        from skey.key_detection import load_checkpoint, load_model_components
        _, net, _ = load_model_components(load_checkpoint(None), torch.device("cpu"))
        net.load_state_dict(torch.load(args.checkpoint, map_location="cpu")["chromanet"])
        device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
        skey = skey_probs(net.to(device), rows, device)
    g = groups(manifest, rows)
    if args.val_only:
        g = {k: v for k, v in g.items() if k in VAL}
    alpha, bias = args.alpha, args.bias
    if args.tune:
        val = {k: v for k, v in g.items() if k in VAL}
        grid = [(a, b) for a in np.arange(0, 6.01, 0.2) for b in (np.arange(-1, 1.01, 0.1) if args.tune_bias else [bias])]
        alpha, bias = max(grid, key=lambda ab: val_score(evaluate(val, skey, *ab)))
    res = evaluate(g, skey, alpha, bias)
    print(f"{'checkpoint ' + args.checkpoint if args.checkpoint else 'shipped S-KEY'}  α={alpha:.1f} bias={bias:+.1f}")
    for k in sorted(res):
        m = res[k]
        print(f"  {k:34s} n={m['n']:4d}  exact {100 * m['exact']:5.1f}  MIREX {100 * m['mirex']:5.1f}  "
              f"major {100 * m['major']:5.1f}  minor {100 * m['minor']:5.1f}")


if __name__ == "__main__":
    main()
