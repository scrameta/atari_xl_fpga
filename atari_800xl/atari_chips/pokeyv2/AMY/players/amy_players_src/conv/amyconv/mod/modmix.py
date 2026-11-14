#!/usr/bin/env python3
"""modmix.py - render modplay's tick states (a check of the player against libopenmpt,
and per-channel / per-sample stems for analysis). Nearest-sample, no interpolation;
Amiga panning L R R L.
usage: modmix.py file.mod out.wav [solo samples, comma list]"""
import sys, wave
import numpy as np
import modplay

FS = 32000


def render(m, ticks, solo=None, chans=(0, 1, 2, 3), stereo=True):
    n = int((ticks[-1][0] + 0.2) * FS)
    out = np.zeros((n, 2))
    pcm = [None] + [np.array(s['pcm'], float) / 128.0 for s in m.samples[1:]]
    for i, (t, sts) in enumerate(ticks):
        t1 = ticks[i + 1][0] if i + 1 < len(ticks) else t + 0.02
        a, b = int(t * FS), int(t1 * FS)
        for c in chans:
            s = sts[c]
            if not s['alive'] or not s['smp'] or not s['period'] or s['vol'] == 0:
                continue
            if solo and s['smp'] not in solo:
                continue
            smp = m.samples[s['smp']]
            step = modplay.PAL / s['period'] / FS
            p = s['pos'] + step * np.arange(b - a)
            if smp['loop']:
                end = smp['ls'] + smp['ll']
                over = p >= end
                p[over] = smp['ls'] + (p[over] - smp['ls']) % smp['ll']
            else:
                p = p[p < smp['len']]
            x = pcm[s['smp']][p.astype(int)] * (s['vol'] / 64.0)
            side = (0, 1, 1, 0)[c] if stereo else None
            if side is None:
                out[a:a + len(x), :] += x[:, None] * 0.5
            else:
                out[a:a + len(x), side] += x
    return out


def save(path, x, gain=0.5):
    y = np.clip(x * gain * 32767, -32768, 32767).astype(np.int16)
    w = wave.open(path, 'w'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(FS)
    w.writeframes(y.tobytes()); w.close()


if __name__ == '__main__':
    m, ticks = modplay.play(sys.argv[1])
    solo = set(map(int, sys.argv[3].split(','))) if len(sys.argv) > 3 else None
    x = render(m, ticks, solo)
    save(sys.argv[2], x)
    print(sys.argv[2], '%.1f s' % (len(x) / FS))
