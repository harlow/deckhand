"""Fine-tune S-KEY's ChromaNet on labelled keys (architecture unchanged).

usage: python train.py <out.pt> [--epochs N] [--lr X] [--sources bp,fmak,lib] [--balance 1.0] [--seed S]

Inputs: manifest.json (manifest.py) and cqt/<sha1(path)>.npy (prep.py, [clips, 99, 646] raw dB).
Each step draws one random 15 s clip per track and a random transposition: rows t..t+84 of the 99-bin
VQT, which lowers the key by t semitones (checked against the pretrained model). The per-clip 80 dB
floor matches S-KEY / Deckhand's inference. Loss: cross-entropy weighted per source and by mode
(major/minor) frequency, `--balance` 0 (none) … 1 (equal total weight per mode). The final BatchNorm keeps
its pretrained statistics. Early stopping on the validation score (see `score`).
"""
import argparse, hashlib, json, math, os, random, sys, time

import numpy as np
import torch
import torch.nn.functional as F

ROOT = os.environ.get("KEY_DATA", os.path.expanduser("~/Data/deckhand-key"))
sys.path.insert(0, os.path.join(ROOT, "skey"))
from skey.key_detection import load_checkpoint, load_model_components  # noqa: E402

SOURCE_WEIGHT = {"bp": 1.0, "fmak": 0.5, "lib": 1.0}  # lib items already carry MIK_WEIGHT


def npy(path):
    return os.path.join(ROOT, "cqt", hashlib.sha1(path.encode()).hexdigest() + ".npy")


def logits(net, x):
    """ChromaNet.forward without the final softmax."""
    for cb, tb in zip(net.convnext_blocks, net.time_downsampling_blocks):
        x = cb(tb(x))
    x = net.batch_norm(net.classifier(net.global_average_pool(net.octave_pool(x))))
    return net.flatten(x) / net.temperature


def normalize(db):
    """[..., 99, 646] raw dB -> S-KEY input: 80 dB floor below each clip's max, mapped to db/80 + 1."""
    m = db.amax(dim=(-2, -1), keepdim=True)
    return torch.maximum(db, m - 80) / 80 + 1


def shifted(label, t):
    return (label // 12) * 12 + (label % 12 - t) % 12


# Relation weights (MIREX) in S-KEY index space.
def to_pc(i):
    return ((i + 9) % 12, False) if i < 12 else ((i - 12 + 11) % 12, True)


def mirex(p, t):
    (pp, pm), (tp, tm) = to_pc(p), to_pc(t)
    if (pp, pm) == (tp, tm):
        return 1.0
    if pm == tm and (pp - tp) % 12 in (5, 7):
        return 0.5
    if pm != tm:
        rel = (tp + 3) % 12 if tm else (tp + 9) % 12  # relative major of minor / relative minor of major
        if pp == rel:
            return 0.3
        if pp == tp:
            return 0.2
    return 0.0


class Data:
    def __init__(self, items):
        self.items = [i for i in items if os.path.exists(npy(i["path"]))]
        self.arrays = [np.load(npy(i["path"]), mmap_mode="r") for i in self.items]

    def __len__(self):
        return len(self.items)


def eval_probs(net, data, device, clips=6):
    """Mean softmax over up to `clips` evenly spaced stored clips at offset 0, per track."""
    net.eval()
    out = []
    with torch.no_grad():
        for a in data.arrays:
            n = a.shape[0]
            idx = sorted({round(k * (n - 1) / max(1, clips - 1)) for k in range(min(clips, n))})
            x = normalize(torch.from_numpy(np.asarray(a[idx], dtype=np.float32)).to(device))[:, None, :84]
            out.append(F.softmax(logits(net, x), -1).mean(0).cpu())
    return torch.stack(out) if out else torch.zeros(0, 24)


def report(probs, data):
    pred = probs.argmax(1).tolist()
    labels = [i["label"] for i in data.items]
    n = max(1, len(labels))
    exact = sum(p == t for p, t in zip(pred, labels)) / n
    mx = sum(mirex(p, t) for p, t in zip(pred, labels)) / n
    maj = [(p, t) for p, t in zip(pred, labels) if t < 12]
    mnr = [(p, t) for p, t in zip(pred, labels) if t >= 12]
    rec = lambda xs: sum(p == t for p, t in xs) / max(1, len(xs))
    return {"n": len(labels), "exact": exact, "mirex": mx, "major": rec(maj), "minor": rec(mnr)}


def score(r):
    """Validation objective: EDM human labels first, then confident MIK agreement, then FMAK."""
    return 0.5 * r["bp"]["mirex"] + 0.3 * r["lib"]["exact"] + 0.2 * r["fmak"]["mirex"]


def batches(train, probs, batch, steps, rng, device):
    """Random (clip, transposition) batches, assembled on a background thread."""
    import queue, threading
    q = queue.Queue(maxsize=4)
    seeds = rng.integers(1 << 31, size=steps)

    def make(seed):
        r = np.random.default_rng(seed)
        idx = r.choice(len(train), size=batch, p=probs)
        xs = np.empty((batch, 99, 646), dtype=np.float32)
        ts = r.integers(16, size=batch)
        for k, i in enumerate(idx):
            a = train.arrays[i]
            xs[k] = a[r.integers(a.shape[0])]
        ys = [shifted(train.items[i]["label"], int(t)) for i, t in zip(idx, ts)]
        return xs, ts, ys

    def worker():
        for sd in seeds:
            q.put(make(sd))

    threading.Thread(target=worker, daemon=True).start()
    for _ in range(steps):
        xs, ts, ys = q.get()
        norm = normalize(torch.from_numpy(xs).to(device))
        x = torch.stack([norm[k, t:t + 84] for k, t in enumerate(ts.tolist())])[:, None]
        yield x, torch.tensor(ys, device=device)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--batch", type=int, default=64)
    ap.add_argument("--steps", type=int, default=150, help="steps per epoch")
    ap.add_argument("--sources", default="bp,fmak,lib")
    ap.add_argument("--balance", type=float, default=1.0)
    ap.add_argument("--patience", type=int, default=10)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--eval-only", action="store_true")
    args = ap.parse_args()
    random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")

    items = json.load(open(os.path.join(ROOT, "manifest.json")))
    sources = set(args.sources.split(","))
    train = Data([i for i in items if i["split"] == "train" and i["source"] in sources and i["weight"] > 0])
    val = {s: Data([i for i in items if i["split"] == "val" and i["source"] == s and (s != "lib" or i["conf"] >= 0.8)])
           for s in ("bp", "lib", "fmak")}
    print("train", len(train), {s: sum(i["source"] == s for i in train.items) for s in sources},
          "val", {s: len(v) for s, v in val.items()}, flush=True)

    _, net, _ = load_model_components(load_checkpoint(None), torch.device("cpu"))
    net = net.to(device)

    def validate():
        r = {s: report(eval_probs(net, v, device), v) for s, v in val.items()}
        return r, score(r)

    r0, s0 = validate()
    print("pretrained", json.dumps({k: {m: round(x, 3) for m, x in v.items()} for k, v in r0.items()}), f"score {s0:.4f}", flush=True)
    if args.eval_only:
        return

    # Per-item weights: source × item weight × mode balance.
    w = np.array([SOURCE_WEIGHT[i["source"]] * i["weight"] for i in train.items])
    minor = np.array([i["label"] >= 12 for i in train.items])
    f_minor = w[minor].sum() / w.sum()
    mode_w = np.where(minor, (0.5 / f_minor) ** args.balance, (0.5 / (1 - f_minor)) ** args.balance)
    w = w * mode_w
    print(f"weighted minor share before balance {f_minor:.2f}", flush=True)
    probs = w / w.sum()

    opt = torch.optim.AdamW(net.parameters(), lr=args.lr, weight_decay=1e-4)
    total = args.epochs * args.steps
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min(1, (s + 1) / 200) * 0.5 * (1 + math.cos(math.pi * min(1, s / total))))
    best, best_state, bad = s0, {k: v.clone() for k, v in net.state_dict().items()}, 0
    rng = np.random.default_rng(args.seed)
    for epoch in range(args.epochs):
        net.train()
        net.batch_norm.eval()  # keep pretrained output statistics
        t0, losses = time.time(), []
        for x, y in batches(train, probs, args.batch, args.steps, rng, device):
            loss = F.cross_entropy(logits(net, x), y, label_smoothing=0.05)
            opt.zero_grad()
            loss.backward()
            opt.step()
            sched.step()
            losses.append(loss.item())
        r, s = validate()
        flag = ""
        if s > best:
            best, best_state, bad, flag = s, {k: v.clone() for k, v in net.state_dict().items()}, 0, " *"
        else:
            bad += 1
        print(f"epoch {epoch + 1} loss {np.mean(losses):.4f} {time.time() - t0:.0f}s "
              + " ".join(f"{k}:{v['exact']:.3f}/{v['mirex']:.3f}/maj{v['major']:.2f}" for k, v in r.items())
              + f" score {s:.4f}{flag}", flush=True)
        if bad >= args.patience:
            break
    torch.save({"chromanet": best_state, "score": best, "args": vars(args)}, args.out)
    print(f"saved {args.out} (val score {best:.4f}, pretrained {s0:.4f})")


if __name__ == "__main__":
    main()
