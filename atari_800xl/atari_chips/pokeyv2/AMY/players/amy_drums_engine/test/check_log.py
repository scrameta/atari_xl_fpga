#!/usr/bin/env python3
"""Sanity checks on the chip log the engine model expands (render.py *.chip.txt):
 1. no $34-$3F command while the extension unlock is not active
 2. no harmonic held at a non-zero level with zero slope for > 1.5 s
 3. frequency destinations within 13 bits, LHP layout as intended"""
import sys, importlib.util, numpy as np
spec = importlib.util.spec_from_file_location('m', 'tools/amy_model.py'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
ev = np.loadtxt(sys.argv[1], dtype=np.int64)
amy = m.Amy(np.random.default_rng(0)); amy.legacy_noise = np.ones((1, 64, 32))
errors = 0; locked_ext = 0; ms_prev = -1
held_since = np.full(64, -1)
for t, r, v in ev:
    t = int(t); r = int(r); v = int(v)
    if r == 0 and 0x34 <= v < 0x40 and not amy.ext:
        locked_ext += 1
    if r == 0 and 0x08 <= v < 0x10 and ((amy.b << 8) | amy.c) > 8191:
        print('freq out of range at', t); errors += 1
    if t != ms_prev:
        # advance envelopes to t (coarse: per log ms)
        for ms in range(max(ms_prev, 0), t):
            amy.render_block(ms * 32) if amy.run else None
            held = (amy.astp == 0) & (amy.aprop == 0) & (amy.acur >= 32)   # proportional: moving; < 1 step: silent
            held_since[~held] = -1
            held_since[held & (held_since < 0)] = ms
            stuck = held & (ms - held_since > 1500)
            if stuck.any():
                print('stuck harmonic(s)', np.nonzero(stuck)[0], 'at', ms / 1000, 'levels', amy.acur[stuck] / 32)
                errors += 1; held_since[stuck] = ms
        ms_prev = t
    amy.write(r, v)
print('ext commands while locked:', locked_ext)
print('final LHP pairs set:', list(np.nonzero(amy.lhp)[0]))
print('max level remaining after the song:', amy.acur.max() / 32)
sys.exit(1 if errors or locked_ext else 0)
