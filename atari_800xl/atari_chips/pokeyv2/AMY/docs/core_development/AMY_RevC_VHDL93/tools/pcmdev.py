#!/usr/bin/env python3
"""pcmdev.py new_pcm old_pcm [max_shift]

Compare two amy1_top PCM logs ("left right" per sample) whose timing may differ by a few
chip clocks. Reports the differing runs and, for each, whether it is a time shift (the new
run equals the old one moved by k samples, |k| <= max_shift), or a transient (the
waveforms differ only for the run, then agree again).
"""
import sys

def load(p):
    return [tuple(map(int, l.split()[:2])) for l in open(p) if l.strip()]

a, b = load(sys.argv[1]), load(sys.argv[2])
ms = int(sys.argv[3]) if len(sys.argv) > 3 else 4
n = min(len(a), len(b))
runs, i = [], 0
while i < n:
    if a[i] != b[i]:
        j = i
        while j < n and a[j] != b[j]:
            j += 1
        runs.append((i, j))
        i = j
    else:
        i += 1

def shift_of(i, j):
    for k in range(-ms, ms + 1):
        if k and all(0 <= t + k < n and a[t] == b[t + k] for t in range(i, j)):
            return k
    return None

ndiff = sum(j - i for i, j in runs)
print(f"{n} samples ({len(a)} new, {len(b)} old), {ndiff} differ in {len(runs)} runs")
kinds = {}
for i, j in runs:
    k = shift_of(i, j)
    peak = max(max(abs(a[t][0] - b[t][0]), abs(a[t][1] - b[t][1])) for t in range(i, j))
    kind = f"shift {k:+d}" if k is not None else "transient"
    kinds[kind.split()[0]] = kinds.get(kind.split()[0], 0) + 1
    if len(runs) <= 40:
        print(f"  samples {i}..{j - 1} ({j - i}): {kind}, peak |diff| {peak}")
print("  kinds:", ", ".join(f"{v} {k}" for k, v in sorted(kinds.items())) or "none")
