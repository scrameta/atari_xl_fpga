#!/usr/bin/env python3
"""Full system with the Rev C extensions (spec 6.8): amy1_top at 8.192 MHz (STEP 3/7),
ENGINE, unlocked through $D2C7, the test_eng_ext kit driven through the engine.
Checks
  - the chip writes against engmodel_x (EXT_VATT/HDET/HSTOCH execute in amy1_top, so
    their command bytes never reach the chip; their A and C writes do)
  - every harmonic jump: the next write to that harmonic at least a sample later
  - the kick's pitch envelope, read back from the chip with the engine idle: a jump
    to +24 semitones, then the proportional fall of A = $67 (k = 7, every 2 samples)
The engine's unit is 2^11 internal clocks (0.5 ms) to keep the run short.
usage: sys_eng_x.py workdir [hpv8]"""
import sys, os, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engmodel, engmodel_x, test_eng_ext

US = 200                          # tb_top time units (5 ns) per microsecond
UNIT = 500 * US                   # engine unit: 2^11 internal clocks at 4.096 MHz
EIGHTH = UNIT // 8
SAMPLE = 6250                     # 5 ns units per 32 kHz sample


def main(wd, hpv8):
    ram = engmodel.ram_image(False)
    xram = test_eng_ext.xram_image()
    c = []; t = 2000
    def w(a, d, gap=8 * 40):
        nonlocal t
        c.append((t, a, d)); t += gap
    cfg = 3 if hpv8 else 1
    insts = (0, 6, 2, 3)
    w(16 + 15, cfg)
    words = [40] + sorted(set([48 + i for i in insts] + [64 + 16 * i + k for i in insts for k in range(16)]))
    for x in words:
        v = ram[x]
        w(16 + 12, x); w(16 + 8, v & 255); w(16 + 9, (v >> 8) & 255); w(16 + 10, (v >> 16) & 255); w(16 + 13, (v >> 24) & 255)
    w(16 + 15, cfg | 4)
    for x in range(128):                                     # every word: the page is not cleared by reset
        v = xram.get(x, 0)
        w(16 + 12, x); w(16 + 8, v & 255); w(16 + 9, (v >> 8) & 255); w(16 + 10, (v >> 16) & 255); w(16 + 13, (v >> 24) & 255)
    w(16 + 15, cfg)
    w(7, 0xA5); w(7, 0x5A)                                   # unlock
    T0 = t + 4000
    ev = [(T0 + 2000 * v, ('inst', v, i)) for v, i in enumerate(insts)]
    ev += [(T0 + 60000, ('on', 0, 50, 0xD8, 16)),
           (T0 + 120000, ('on', 1, 40, 0xD0, 8)),
           (T0 + 220000, ('on', 3, 45, 0xD8, 16)),
           (T0 + 900000, ('on', 2, 60, 0xC8, 12)),
           (T0 + 1050000, ('off', 2)),
           (T0 + 1200000, ('off', 0)),
           (T0 + 1300000, ('on', 1, 42, 0xD8, 8)),
           (T0 + 1340000, ('off', 1)),
           (T0 + 1450000, ('on', 0, 55, 0xE0, 16))]
    for at, job in ev:
        assert at > t
        t = at
        if job[0] == 'on':
            w(16 + 8, job[2]); w(16 + 9, job[3]); w(16 + 10, job[4]); w(16 + 11, 0x90 + job[1])
        elif job[0] == 'off':
            w(16 + 11, 0x80 + job[1])
        else:
            w(16 + 8, job[2]); w(16 + 11, 0xA0 + job[1])
    # the kick's pitch: read voice 0's frequency with the engine idle
    t0r = T0 + 1550000
    t = t0r
    reads = 0
    while t < t0r + 400000:
        start = t
        w(0, 0x18); w(8 + 2, 0); w(8 + 3, 0)
        t = start + 10000; reads += 1
    stop = t + 10000
    # predicted retriggers, as in test_eng_ext
    jobs = list(ev)
    for at, job in ev:
        if job[0] != 'on':
            continue
        xh = xram.get(insts[job[1]], 0)
        n, p = (xh >> 4) & 15, (xh >> 2) & 3
        nxt = min([a for a, j in ev if j[1] == job[1] and a > at] + [1 << 40])
        for j in range(1, n + 1):
            due = (at // EIGHTH) * EIGHTH + j * 8 * (p + 1) * EIGHTH
            if due < nxt:
                jobs.append((due + EIGHTH // 2, ('rt', job[1])))
    jobs.sort(key=lambda e: e[0])
    for (a, ja), (b, jb) in zip(jobs, jobs[1:]):
        if 'rt' in (ja[0], jb[0]):
            assert b - a > 40000, ('too close', a, b)

    open(os.path.join(wd, 'sysx_cmds.txt'), 'w').write(''.join('%d %d %d\n' % x for x in c))
    r = subprocess.run(['ghdl', '--elab-run', '--std=08', '-frelaxed', 'tb_top', '-gENGINE=true',
                        '-gSTEP_NUM=3', '-gSTEP_DEN=7', '-gUNIT_LOG2=11',
                        '-gCMD_FILE=sysx_cmds.txt', '-gCHIP_FILE=sysx_chip.txt', '-gOUT_FILE=sysx_samp.txt',
                        '-gPCM_FILE=sysx_pcm.txt', '-gREAD_FILE=sysx_reads.txt', '-gSTOP=%d' % stop,
                        '-gMEM_FILE=amy1_mem.hex'], cwd=wd, capture_output=True, text=True)
    if r.returncode:
        print(r.stdout[-500:], r.stderr[-500:])
    got = []; when = []; samples = []; rn = []; wn = []
    for l in open(os.path.join(wd, 'sysx_chip.txt')):
        f = l.split()
        if f[0] == 'W':
            if (int(f[2]), int(f[3])) == (0, 0x18):
                continue                                     # the host's read commands
            got.append((int(f[2]), int(f[3]))); when.append(int(f[1]))
        elif f[0] == 'S':
            samples.append(int(f[1]))
        elif f[0] == 'r':
            rn.append(int(f[1]))
        else:
            wn.append(int(f[1]))
    exp = [x for x in engmodel_x.expected_x([j for _, j in jobs], rn, wn, ram, xram, hpv8)
           if x not in ((0, 0x34), (0, 0x35), (0, 0x36))]
    first = next((i for i, (a, b) in enumerate(zip(got, exp)) if a != b), None)
    ok = got == exp
    lay = '8x8' if hpv8 else '16x4'
    print('system ext %s: chip writes %d expected %d, %s%s' % (lay, len(got), len(exp),
          'IDENTICAL' if ok else 'DIFFER', '' if ok or first is None else ' at %d: %s vs %s' % (first, got[first:first+4], exp[first:first+4])))
    # jumps
    per = sorted(b - a for a, b in zip(samples, samples[1:]))[len(samples) // 2]
    A = None; last_jump = {}; nearest = []; jumps = 0
    for (r_, x), s in zip(got, when):
        if r_ == 1: A = x
        elif r_ == 0 and 0x40 <= x < 0x80:
            h = x & 63
            if h in last_jump:
                nearest.append((s - last_jump.pop(h)) / per)
            if A == 0:
                last_jump[h] = s; jumps += 1
    lost = sum(1 for g in nearest if g < 1.0)
    print('   jumps %d, next write to the same harmonic after %.2f samples at the least; closer than a sample: %d'
          % (jumps, min(nearest) if nearest else 0, lost))
    # pitch envelope
    rd = [l.split() for l in open(os.path.join(wd, 'sysx_reads.txt')) if l.strip()]
    vals = []
    for a, b in zip(rd[0::2], rd[1::2]):
        vals.append((int(a[0]), (int(a[4], 16) & 31) << 8 | int(b[4], 16)))
    f = (ram[40] + 55 * 64) & 0x1FFF
    d = [(tt, v - f) for tt, v in vals]
    # k = 7 every 2 samples: delta x (127/128)^(dt / 2 samples), in 1/64 semitone
    import math
    (ta, da), (tb, db) = d[0], d[-1]
    meas = math.log(db / da) / ((tb - ta) / (2 * SAMPLE)) if da > 0 and db > 0 else 0
    rates = [meas]
    want = math.log(127 / 128)
    pitch_ok = bool(rates) and all(b[1] <= a[1] for a, b in zip(d, d[1:])) and abs(meas / want - 1) < 0.05 \
        and 0 < d[0][1] <= 1536
    print('   kick pitch: %d reads, %+d .. %+d (1/64 semitone) above the note, decay per update %.5f (k = 7: %.5f): %s'
          % (len(d), d[0][1], d[-1][1], meas, want, 'ok' if pitch_ok else 'WRONG'))
    pcm = [tuple(map(int, l.split())) for l in open(os.path.join(wd, 'sysx_pcm.txt'))]
    peak = max(max(abs(a), abs(b)) for a, b in pcm) if pcm else 0
    print('   samples %d, peak %d' % (len(pcm), peak))
    return ok and lost == 0 and pitch_ok


if __name__ == '__main__':
    ok = main(sys.argv[1], 'hpv8' in sys.argv[2:])
    print('SYSTEM EXT', 'PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)
