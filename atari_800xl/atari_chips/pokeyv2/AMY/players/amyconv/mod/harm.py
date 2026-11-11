"""harmonic analysis of a tonal MOD sample with a known pitch: per-harmonic level curves"""
import numpy as np, math, modplay

def cpb_of(semis160):
    return 261.6256 * 2 ** (semis160 / 12) / (modplay.PAL / 160)

def play_bytes(sm, n):
    """the sample's bytes as played for n bytes (looping)"""
    x = list(sm['pcm'])
    if sm['loop']:
        lp = x[sm['ls']:sm['ls'] + sm['ll']]
        while len(x) < n: x += lp
    return np.array(x[:n], float) / 128.0

def curves(sm, semis160, dur_bytes=None, hop_cycles=1.0, win_cycles=4, K=8):
    c = cpb_of(semis160)
    P = 1 / c
    n = dur_bytes or max(len(sm['pcm']), int(40 * P))
    x = play_bytes(sm, n + int(win_cycles * P) + 2)
    W = int(round(win_cycles * P)); hop = max(1, int(round(hop_cycles * P)))
    w = np.hanning(W); w /= w.sum() / 2
    t = np.arange(W)
    basis = [np.exp(-2j * np.pi * c * (k + 1) * t) for k in range(K)]
    out = []
    for a in range(0, n, hop):
        seg = x[a:a + W]
        if len(seg) < W: break
        out.append([abs((seg * w * b).sum()) for b in basis])
    return np.array(out), hop          # [frame, harmonic] amplitude (1.0 = full-scale sine)

def db(a): return 20 * np.log10(np.maximum(a, 1e-5))
