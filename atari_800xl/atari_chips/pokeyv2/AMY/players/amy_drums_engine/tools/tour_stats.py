#!/usr/bin/env python3
"""Per-instrument level and brightness of the kit tour (first hit of each)."""
import sys
import numpy as np
from scipy.io import wavfile
names = ["Kick", "808", "Snare", "Rim", "Clap", "CHH", "OHH", "TomH", "TomM", "TomL", "Ride", "Cow", "Crash"]
cnt = [3, 2, 3, 3, 3, 6, 2, 1, 1, 1, 4, 4, 1]
GAPS = {'old': [450, 900, 450, 300, 450, 160, 650, 300, 300, 800, 330, 220, 2200],
        'new': [440, 900, 440, 300, 440, 160, 640, 300, 300, 800, 320, 220, 2200]}


def stats(path, gaps):
    fs, y = wavfile.read(path); y = y.astype(float).mean(1) / 32768
    first = np.argmax(np.abs(y) > 1e-3)
    t = first; out = []
    for nm, c, g in zip(names, cnt, gaps):
        s = int(t); seg = y[s:s + int(min(g, 300) / 1000 * fs)]
        pk = 20 * np.log10(np.abs(seg).max() + 1e-9)
        rms = 20 * np.log10(np.sqrt((seg ** 2).mean()) + 1e-9)
        sp = np.abs(np.fft.rfft(seg * np.hanning(len(seg)))) ** 2; f = np.fft.rfftfreq(len(seg), 1 / fs)
        cen = (sp * f).sum() / sp.sum()
        e = np.abs(y[s:s + int(g / 1000 * fs)])
        e = np.convolve(e, np.ones(160) / 160, 'same')
        dur = np.nonzero(e > e.max() * 10 ** (-40 / 20))[0]
        out.append((nm, pk, rms, cen, (dur[-1] / fs * 1000) if len(dur) else 0))
        t += c * g / 1000 * fs
    return out


if __name__ == '__main__':
    tabs = [stats(p, GAPS[k]) for k, p in zip(('old', 'new'), sys.argv[1:3])]
    print('%-6s %22s   %22s' % ('', 'old: peak  rms  centroid  -40dB', 'new: peak  rms  centroid  -40dB'))
    for a, b in zip(*tabs):
        print('%-6s %6.1f %6.1f %6.0f %5.0f   %6.1f %6.1f %6.0f %5.0f' % (a[0], *a[1:], *b[1:]))
