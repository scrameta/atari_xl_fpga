#!/usr/bin/env python3
"""Kick weight: level, low bands and length of the tour's first kick, and the
song sections' peaks."""
import sys
import numpy as np
from scipy.io import wavfile


def kick(p):
    fs, y = wavfile.read(p); y = y.astype(float).mean(1) / 32768
    a = np.argmax(np.abs(y) > 1e-3); s = y[a:a + int(0.44 * fs)]
    sp = np.abs(np.fft.rfft(s)) ** 2; f = np.fft.rfftfreq(len(s), 1 / fs)
    e = np.convolve(np.abs(s), np.ones(160) / 160, 'same')
    t40 = np.nonzero(e > e.max() * 0.01)[0][-1] / fs * 1000
    band = lambda lo, hi: 10 * np.log10(sp[(f >= lo) & (f < hi)].sum() + 1e-12)
    return 20 * np.log10(np.abs(s).max()), 10 * np.log10((s ** 2).mean()), band(0, 80), band(80, 250), band(250, 1000), t40


print('%-10s %6s %6s %7s %8s %9s %6s' % ('', 'peak', 'rms', '<80 Hz', '80-250', '250-1k', '-40dB'))
for p in sys.argv[1:-1]:
    print('%-10s %6.1f %6.1f %7.1f %8.1f %9.1f %5.0f' % ((p.split('/')[-1][:10],) + kick(p)))
fs, y = wavfile.read(sys.argv[-1]); y = y.astype(float) / 32768
for n, a, b in [('Electro', 14.6, 32.5), ('Funk', 32.6, 53), ('Ride', 53, 62), ('Ext off', 62.3, 72.3), ('Rev C again', 72.4, 88)]:
    s = y[int(a * fs):int(b * fs)]
    print('%-12s peak %6.1f dBFS, clipped %.3f%%' % (n, 20 * np.log10(np.abs(s).max()), 100 * np.mean(np.abs(s) > 0.999)))
