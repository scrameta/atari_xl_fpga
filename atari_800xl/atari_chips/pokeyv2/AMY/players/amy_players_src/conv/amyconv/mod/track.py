"""spectral note tracker for the sampled chords/phrases: notes (semitones from middle C at
the analysis rate), with onsets, ends and levels"""
import numpy as np, math

def frames(x, sr, hop_s=0.01, win_s=0.06, fmin=120, fmax=2200):
    N = 1 << 15
    win = int(win_s * sr); hop = int(hop_s * sr)
    fr = np.fft.rfftfreq(N, 1 / sr)
    out = []
    for a in range(0, max(1, len(x) - win), hop):
        seg = x[a:a + win]
        X = np.abs(np.fft.rfft(seg * np.hanning(len(seg)), N)) / (win / 4)
        pk = []
        for j in range(2, len(X) - 2):
            if fr[j] < fmin: continue
            if fr[j] > fmax: break
            if X[j] >= X[j - 1] and X[j] >= X[j + 1] and X[j] == X[j - 3:j + 4].max():
                pk.append((X[j], fr[j]))
        out.append((a / sr, pk))
    return out

def notes_in(pk, top=3, rel_db=-14, absmin=0.01):
    """strongest peaks -> semitones, dropping harmonics (x2, x3, x4) of a stronger lower one"""
    if not pk: return {}
    pk = sorted(pk, reverse=True)
    mx = pk[0][0]
    keep = []
    for a, f in pk:
        if a < mx * 10 ** (rel_db / 20) or a < absmin: break
        if any(abs(f / g - round(f / g)) < 0.03 and round(f / g) in (2, 3, 4) and b >= a * 0.7 for b, g in keep):
            continue
        keep.append((a, f))
        if len(keep) >= top: break
    out = {}
    for a, f in keep:
        n = 12 * math.log2(f / 261.6256)
        r = round(n - 0.1)
        out[r] = max(out.get(r, 0), a)
    return out

def track(x, sr, top=3, min_len=0.04):
    fs = frames(np.asarray(x, float) / 128.0, sr)
    active = {}; done = []
    for t, pk in fs:
        ns = notes_in(pk, top)
        for n in list(active):
            if n not in ns:
                s, lv, last = active.pop(n)
                done.append((s, t, n, lv))
        for n, a in ns.items():
            if n in active:
                s, lv, last = active[n]
                # a re-attack: the level jumps up by 6 dB or more
                if a > last * 2 and t - s > 0.05:
                    done.append((s, t, n, lv)); active[n] = (t, a, a)
                else:
                    active[n] = (s, max(lv, a), a)
            else:
                active[n] = (t, a, a)
    tend = fs[-1][0] + 0.06 if fs else 0
    for n, (s, lv, last) in active.items():
        done.append((s, tend, n, lv))
    return sorted((s, e, n, lv) for s, e, n, lv in done if e - s >= min_len)
