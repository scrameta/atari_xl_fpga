#!/usr/bin/env python3
"""timedev.py <dir_new> <dir_old> <name> [frame]

The unaligned timing-deviation report for one amy1_top run, phase B (dir_new) against
phase A (dir_old):
  * command timing: the chip clock each command's busy starts, new minus old
  * audio: per frame of `frame` samples, the magnitude spectrum of the new output against
    the old (phase-independent: an oscillator started a few clocks earlier has the same
    spectrum), as the relative error ||A|-|B|| / |B|, and the frame RMS in dB
"""
import sys
import numpy as np

dn, do, name = sys.argv[1:4]
frame = int(sys.argv[4]) if len(sys.argv) > 4 else 64

def busy(d):
    """(chip clock, command) per busy start; N lines (Noise RAM writes) are skipped"""
    r = []
    for l in open(f"{d}/{name}_busy.txt"):
        f = l.split()
        if f and f[0] != "N":
            r.append((int(f[0]), f[1] if len(f) > 1 else ""))
    return r

def pcm(d):
    return np.array([list(map(int, l.split()[:2])) for l in open(f"{d}/{name}_pcm.txt") if l.strip()], float)

bn, bo = busy(dn), busy(do)
print(f"{name}: {len(bn)} commands")
if len(bn) == len(bo) and bn:
    if [c for _, c in bn] != [c for _, c in bo]:
        print("  COMMAND ORDER DIFFERS")
    d = np.array([t for t, _ in bn]) - np.array([t for t, _ in bo])
    print(f"  busy start, phase B - phase A: median {np.median(d):+.0f} chip clocks, "
          f"range {d.min():+d} .. {d.max():+d}; {np.sum(np.abs(d) <= 4)} of {len(d)} within 4")
else:
    print("  command counts differ")

a, b = pcm(dn), pcm(do)
n = min(len(a), len(b))
ident = int(np.sum(np.all(a[:n] == b[:n], axis=1)))
print(f"  samples: {n} compared, {ident} identical ({100 * ident / max(n, 1):.1f}%)")
w = np.hanning(frame)
errs, drms = [], []
for ch in (0, 1):
    for i in range(0, n - frame + 1, frame // 2):
        x, y = a[i:i + frame, ch], b[i:i + frame, ch]
        ry = np.sqrt(np.mean(y ** 2))
        X, Y = np.abs(np.fft.rfft(x * w)), np.abs(np.fft.rfft(y * w))
        if ry < 30 or not np.any(Y):     # skip near-silent frames (about -60 dB)
            continue
        errs.append(np.linalg.norm(X - Y) / np.linalg.norm(Y))
        rx = np.sqrt(np.mean(x ** 2))
        drms.append(20 * np.log10(max(rx, 1e-9) / ry))
if errs:
    e, r = np.array(errs), np.array(drms)
    print(f"  spectra ({len(e)} frames of {frame}): relative error median {np.median(e):.3f}, "
          f"90% {np.percentile(e, 90):.3f}, max {e.max():.3f}")
    print(f"  frame RMS, phase B - phase A: median {np.median(r):+.2f} dB, "
          f"90% |.| {np.percentile(np.abs(r), 90):.2f} dB, max |.| {np.abs(r).max():.2f} dB")
