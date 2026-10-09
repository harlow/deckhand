"""Precompute S-KEY's 99-bin VQT (raw dB, before the per-clip 80 dB floor) for training.

usage: python prep.py <paths.txt> <out dir>
Writes <out>/<sha1(path)>.npy as float16 [clips, 99, 646]: consecutive 15 s clips (22.05 kHz, hop 512)
from 10% to 90% of the track, where Deckhand's inference clips come from, at most 12. Each clip's VQT
is computed on its own, as at inference. Resumable.
"""
import hashlib, os, subprocess, sys
from multiprocessing import Pool

import numpy as np
import torch

ROOT = os.environ.get("KEY_DATA", os.path.expanduser("~/Data/deckhand-key"))
sys.path.insert(0, os.path.join(ROOT, "skey"))
SR, CLIP, MAX_CLIPS = 22050, 15 * 22050, 12
_hcqt = None


def hcqt():
    global _hcqt
    if _hcqt is None:
        from skey.hcqt import VQT
        torch.set_num_threads(1)
        ckpt = torch.load(os.path.join(ROOT, "skey/skey/models/skey.pt"), map_location="cpu", weights_only=False)
        _hcqt = VQT(harmonics=[1], fmin=27.5, n_bins=99, verbose=False)
        _hcqt.load_state_dict({k.replace("hcqt.", ""): v for k, v in ckpt["stone"].items() if "hcqt" in k})
        _hcqt.eval()
    return _hcqt


def key(path):
    return hashlib.sha1(path.encode()).hexdigest()


def work(args):
    path, out = args
    dst = os.path.join(out, key(path) + ".npy")
    if os.path.exists(dst):
        return True
    try:
        raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                             capture_output=True, check=True).stdout
    except subprocess.CalledProcessError:
        return False
    x = np.frombuffer(raw, dtype=np.float32)
    if len(x) < SR * 10:
        return False
    peak = np.abs(x).max()
    if peak == 0:
        return False
    x = x / peak
    lo, hi = int(len(x) * 0.1), int(len(x) * 0.9)
    n = min(MAX_CLIPS, max(1, (hi - lo) // CLIP))
    start = max(0, (lo + hi) // 2 - n * CLIP // 2)
    seg = np.zeros(n * CLIP, dtype=np.float32)
    part = x[start:start + n * CLIP]
    seg[:len(part)] = part
    with torch.no_grad():
        # nnAudio VQT magnitude per clip; S-KEY's AmplitudeToDB(power) = 10·log10(max(|X|, 1e-10)).
        # Three clips at a time: nnAudio's intermediates take ~300 MB per clip.
        clips = torch.from_numpy(seg.reshape(n, CLIP))
        v = torch.cat([super(type(hcqt()), hcqt()).forward(c, "Magnitude", "librosa") for c in clips.split(3)])
        db = 10 * torch.log10(torch.clamp(v, min=1e-10))  # [n, 99, 646]
    np.save(dst, db.numpy().astype(np.float16))
    return True


if __name__ == "__main__":
    paths = [l.rstrip("\n") for l in open(sys.argv[1]) if l.strip()]
    out = sys.argv[2]
    os.makedirs(out, exist_ok=True)
    todo = [(p, out) for p in paths if not os.path.exists(os.path.join(out, key(p) + ".npy"))]
    print(f"{len(todo)} to do of {len(paths)}", flush=True)
    ok = 0
    with Pool(int(os.environ.get("PREP_WORKERS", "6"))) as pool:
        for i, r in enumerate(pool.imap_unordered(work, todo, chunksize=4)):
            ok += r
            if (i + 1) % 200 == 0:
                print(f"{i + 1}/{len(todo)}", flush=True)
    print(f"done: {ok} ok, {len(todo) - ok} failed", flush=True)
