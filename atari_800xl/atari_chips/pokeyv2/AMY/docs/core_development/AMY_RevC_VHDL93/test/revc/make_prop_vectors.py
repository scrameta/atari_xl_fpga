#!/usr/bin/env python3
"""Bus traces for the Rev C proportional envelope mode (spec §7.6).

Each starts with cmds_quickclr_spec (voices set up, chip running), unlocks, then
reads the current value back at a steady cadence while one envelope runs:

  cmds_prop_freq   voice 0 frequency 4000 -> 5000, A = $64 (E=3, k=4), B bit 7 set;
                   then 5000 -> 4900 with A = $62 (k=2), to arrival
  cmds_prop_amp    harmonic 0 amplitude 40 -> 200 (A = $64), then 200 -> 0 (A = $62)
  cmds_prop_lock   the same frequency command after locking: B bit 7 must be ignored
                   (linear, +4 per update); then unlocked, a proportional glide on
                   voice 1 cut by EXT_RESET ($39), which must turn it linear
check_prop.py checks the read-backs against the integer recursion.
Lines: time (5 ns units), register, value; register 8+r reads r.
"""
from pathlib import Path
P = Path(__file__).resolve().parent
SRC = P.parent / 'cmds' / 'cmds_quickclr_spec.txt'
base = [tuple(map(int, l.split())) for l in SRC.read_text().splitlines() if l.strip()]

GAP = 2000
READ_EVERY = 25000


class Trace:
    def __init__(self):
        self.cmds = base[:]
        self.t = 160_000

    def w(self, *pairs):
        for a, v in pairs:
            self.cmds.append((self.t, a, v)); self.t += GAP

    def ffbp(self, v, a, t13, b7=0):
        self.w((1, a), (2, (t13 >> 8) | (0x80 if b7 else 0)), (3, t13 & 255), (0, 0x08 + v))

    def habp(self, h, a, c, b7=0):
        self.w((1, a), (2, 0x80 if b7 else 0), (3, c), (0, 0x40 + h))

    def reads(self, cmd, regs, until):
        while self.t < until:
            start = self.t
            self.w((0, cmd), *((8 + r, 0) for r in regs))
            self.t = max(self.t, start + READ_EVERY)

    def text(self):
        c = sorted(self.cmds)
        assert all(b[0] > a[0] for a, b in zip(c, c[1:])), 'overlapping commands'
        return ''.join(f'{t} {a} {v}\n' for t, a, v in c)


UNLOCK = [(7, 0xA5), (7, 0x5A)]

# frequency
t = Trace(); t.w(*UNLOCK)
t.ffbp(0, 0x00, 4000)
t.reads(0x18, (2, 3), t.t + 10_000)
t.ffbp(0, 0x64, 5000, b7=1)
t.reads(0x18, (2, 3), t.t + 600_000)
t.ffbp(0, 0x00, 5000)                            # then down to 4900 with k = 2: arrival
t.ffbp(0, 0x62, 4900, b7=1)
t.reads(0x18, (2, 3), t.t + 450_000)
(P / 'cmds_prop_freq.txt').write_text(t.text())
STOP_FREQ = t.t + 10_000

# amplitude, rise then decay
t = Trace(); t.w(*UNLOCK)
t.habp(0, 0x00, 40)
t.reads(0xC0, (3,), t.t + 10_000)
t.habp(0, 0x64, 200, b7=1)
t.reads(0xC0, (3,), t.t + 500_000)
t.habp(0, 0x00, 200)                             # then 200 -> 0 with k = 2: arrival
t.habp(0, 0x62, 0, b7=1)
t.reads(0xC0, (3,), t.t + 400_000)
(P / 'cmds_prop_amp.txt').write_text(t.text())
STOP_AMP = t.t + 10_000

# lock and EXT_RESET
t = Trace(); t.w(*UNLOCK)
t.ffbp(0, 0x00, 4000)
t.w((7, 0x00))                                   # lock
t.ffbp(0, 0x64, 5000, b7=1)
t.reads(0x18, (2, 3), t.t + 300_000)
t.w(*UNLOCK)
t.ffbp(1, 0x00, 4000)
t.ffbp(1, 0x64, 5000, b7=1)
t.reads(0x19, (2, 3), t.t + 150_000)
t.w((0, 0x39))                                   # EXT_RESET: the flag goes, linear from here
t.reads(0x19, (2, 3), t.t + 300_000)
(P / 'cmds_prop_lock.txt').write_text(t.text())
STOP_LOCK = t.t + 10_000

(P / 'prop_stops.txt').write_text(f'freq {STOP_FREQ}\namp {STOP_AMP}\nlock {STOP_LOCK}\n')
print('Generated proportional-mode traces; stops', STOP_FREQ, STOP_AMP, STOP_LOCK)
