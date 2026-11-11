#!/usr/bin/env python3
"""Check the proportional-mode read-backs (make_prop_vectors.py) against the
integer recursion of spec §7.6: step = (dest - cur) >> k, at least 1 towards dest.

The update rate is not assumed: each reading is placed on the recursion, a line
n(t) is fitted, and every reading must lie on the recursion within one update of
that line. The fitted rate must be the slope's interval (E=3: one update per 2
samples, 12500 time units), within 5%: the rate counter is the legacy one
and a 25000-unit read window sometimes holds a third update, as it does in
linear mode."""
import sys
from pathlib import Path
import numpy as np

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).parent / 'work' / 'output')
SAMPLE = 6250            # 5 ns units per 32 kHz sample
fails = 0


def check(cond, msg):
    global fails
    print(('  PASS ' if cond else '  FAIL ') + msg)
    fails += not cond


def reads(name):
    r = []
    for l in (OUT / f'prop_{name}.reads').read_text().split('\n'):
        if l.strip():
            t, _, reg, _, v = l.split()
            r.append((int(t), int(reg), int(v, 16)))
    return r


def freq_pairs(r):
    out = []
    for (t, a, b), (_, c, d) in zip(r[0::2], r[1::2]):
        assert a == 2 and c == 3
        out.append((t, (b & 31) << 8 | d))
    return out


def recursion(cur, tgt, k, shift, n):
    seq = [cur]
    for _ in range(n):
        d = tgt - cur
        st = d >> k
        if st == 0 and d > 0:
            st = 1
        cur += st
        seq.append(cur)
    return [s >> shift for s in seq]


def fit(name, pts, seq, interval):
    """Place readings (t, v) on seq; fit n(t); every reading within 1 update."""
    first, count = {}, {}
    for n, v in enumerate(seq):
        first.setdefault(v, n)
        count[v] = count.get(v, 0) + 1
    # the fit places each reading at the middle of its value's run on the
    # recursion; the final (destination) value has no end, so it is left out
    moving = [(t, first[v] + (count[v] - 1) / 2) for t, v in pts
              if v in first and v != seq[-1] and count[v] <= 4]
    tt, nn = np.array(moving, float).T
    a, b = np.polyfit(tt, nn, 1)
    worst = 0
    for t, v in pts:
        n = a * t + b
        lo = min(len(seq) - 1, max(0, int(np.floor(n)) - 1))
        hi = min(len(seq) - 1, int(np.ceil(n)) + 1)
        ok = v in seq[lo:hi + 1]
        worst += not ok
    check(worst == 0, f'{name}: {len(pts)} readings on the recursion ({worst} off)')
    per = 1 / a
    check(abs(per - interval * SAMPLE) < 0.05 * interval * SAMPLE,
          f'{name}: one update per {per / SAMPLE:.2f} samples (expected {interval})')


def segments(pts, starts):
    """Split readings at the jumps (a reading equal to each start value)."""
    out, cur = [], None
    it = iter(starts)
    want = next(it, None)
    for t, v in pts:
        if want is not None and v == want and (cur is None or cur[-1][1] != v):
            cur = []; out.append(cur); want = next(it, None)
            continue                           # the jump's own reading
        if cur is not None:
            cur.append((t, v))
    return out


def arrival(seq):
    return seq[:seq.index(seq[-1]) + 1]


# 1. frequency: 4000 -> 5000 (k = 4), then 5000 -> 4900 (k = 2) to arrival
f = freq_pairs(reads('freq'))
up, down = segments(f, (4000, 5000))
fit('freq up k=4', up, recursion(4000 << 5, 5000 << 5, 4, 5, 200), 2)
dseq = recursion(5000 << 5, 4900 << 5, 2, 5, 200)
fit('freq down k=2', down, dseq, 2)
check(down[-1][1] == 4900 and down[-4][1] == 4900, f'freq: arrives at 4900 and stays (last {[v for _, v in down[-4:]]})')

# 2. amplitude: 40 -> 200 (k = 4), then 200 -> 0 (k = 2) to arrival
a = [(t, v) for t, reg, v in reads('amp')]
rise, fall = segments(a, (40, 200))
fit('amp rise k=4', rise, recursion(40 << 5, 200 << 5, 4, 5, 200), 2)
fseq = recursion(200 << 5, 0, 2, 5, 200)
fseq = fseq[:fseq.index(0) + 1]               # the arrival compare stops it in the 0 band
fit('amp decay k=2', fall, fseq, 2)
check(fall[-1][1] == 0 and fall[-4][1] == 0, f'amp: decays to 0 and stays (last {[v for _, v in fall[-4:]]})')

# 3. locked: B bit 7 ignored (linear +4 at bit 0 per update); EXT_RESET clears the flag
l = freq_pairs(reads('lock'))
v0 = [p for p in l if True]
# voice 0 reads come first: until the value jumps back to 4000 (voice 1's jump)
split = next(i for i in range(1, len(v0)) if v0[i][1] < v0[i - 1][1])
locked, v1 = v0[:split], v0[split:]
# linear: +4 at bit 0 of 18 every update = one read-back unit per 8 updates (4 reads)
span = (locked[-1][0] - locked[0][0]) / (2 * SAMPLE)
want = span * 4 / 32
got = locked[-1][1] - locked[0][1]
check(locked[0][1] == 4000 and abs(got - want) <= 1,
      f'locked: B bit 7 ignored, linear (+{got} in {span:.0f} updates, linear +{want:.1f})')
gain = [v1[i + 1][1] - v1[i][1] for i in range(len(v1) - 1)]
early, late = max(gain[:3]), max(gain[-8:])
check(early > 40, f'unlocked voice 1 glides proportionally (first steps {gain[:3]})')
check(late <= 1, f'after EXT_RESET it is linear (last steps {gain[-8:]})')

print('check_prop:', 'PASS' if not fails else f'{fails} FAIL')
sys.exit(1 if fails else 0)
