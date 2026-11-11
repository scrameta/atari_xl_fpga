#!/usr/bin/env python3
"""tb_engine with the Rev C extensions (spec 6.8): the engine's pushes against
engmodel_x, both layouts, and the retrigger timing.

Kit: v0 PIANO + pitch envelope (+24 semitones, rate $67), trim, detune/diffusion and
proportional flags; v1 SYNTH as white noise with 3 retriggers 2 units apart; v2 ORGAN
with a negative pitch offset and 2 retriggers 1 unit apart, the second cancelled by a
note off; v3 BRASS with no extension data. Then a second v0 note (pitch envelope again)
and a v1 note whose retriggers a note off cancels before the first.
The same host writes with EXT = false must give exactly the legacy stream (engmodel).
usage: test_eng_ext.py workdir"""
import sys, os, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engmodel, engmodel_x

UNIT = 1 << 14                     # tb_engine: a tick every clock, UNIT_LOG2 = 14
EIGHTH = UNIT // 8


def xram_image():
    x = {}
    def hdr(i, vtype=0, rp=0, rc=0, trim=0, off=0, rate=0):
        x[i] = vtype | (rp << 2) | (rc << 4) | (trim << 8) | ((off & 255) << 16) | (rate << 24)
    hdr(0, trim=0x10, off=96, rate=0x67)
    hdr(6, vtype=3, rp=1, rc=3, trim=0x08)
    hdr(2, rp=0, rc=2, off=-8, rate=0x64)
    for i in (0, 6):
        for w in range(8):
            hw = []
            for k in (2 * w, 2 * w + 1):
                det = (3 * k - 8) & 63
                sto = (5 * k + i) & 63
                fa = 1 if k % 2 == 0 else 0
                fd = 1 if k % 3 == 0 else 0
                hw.append(det | (sto << 8) | (fa << 14) | (fd << 15))
            x[32 + 8 * i + w] = hw[0] | (hw[1] << 16)
    return x


def build(hpv8):
    ram = engmodel.ram_image(False)
    xram = xram_image()
    cmds = []                                   # absolute (clock, reg, value)
    t = 0
    def w(r, val, gap=8):
        nonlocal t
        cmds.append((t, r, val)); t += gap
    cfg = 3 if hpv8 else 1
    w(7, cfg)
    for a in range(32, 256):
        x = ram.get(a, 0)
        w(4, a); w(0, x & 255); w(1, (x >> 8) & 255); w(2, (x >> 16) & 255); w(5, (x >> 24) & 255)
    w(7, cfg | 4)                                # XPAGE
    for a in range(128):
        x = xram.get(a, 0)
        w(4, a); w(0, x & 255); w(1, (x >> 8) & 255); w(2, (x >> 16) & 255); w(5, (x >> 24) & 255, 16)
    w(7, cfg)
    T0 = t + 2000
    ev = []                                      # (time, job)
    ev += [(T0 + 400 * v, ('inst', v, i)) for v, i in enumerate((0, 6, 2, 3))]
    ev += [(T0 + 10000, ('on', 0, 50, 0xD8, 16)),
           (T0 + 20000, ('on', 1, 40, 0xD0, 8)),
           (T0 + 60000, ('on', 3, 45, 0xD8, 16)),
           (T0 + 150000, ('on', 2, 60, 0xC8, 12)),
           (T0 + 170000, ('off', 2)),
           (T0 + 250000, ('off', 0)),
           (T0 + 270000, ('on', 0, 55, 0xE0, 16)),
           (T0 + 300000, ('on', 1, 42, 0xD8, 8)),
           (T0 + 310000, ('off', 1))]
    for at, job in ev:
        d = at - t
        assert d >= 8, 'events too close'
        t = at
        if job[0] == 'on':
            seq = [(0, job[2]), (1, job[3]), (2, job[4]), (3, 0x90 + job[1])]
        elif job[0] == 'off':
            seq = [(3, 0x80 + job[1])]
        else:
            seq = [(0, job[2]), (3, 0xA0 + job[1])]
        for r, val in seq:
            w(r, val)
    # predicted retriggers: each 'on' with count n arms them (period P), any later
    # event on the voice cancels those not yet due
    jobs = list(ev)
    for at, job in ev:
        if job[0] != 'on':
            continue
        xh = xram.get([0, 6, 2, 3][job[1]], 0)
        n, p = (xh >> 4) & 15, (xh >> 2) & 3
        nxt = min([a for a, j in ev if j[1] == job[1] and a > at] + [1 << 40])
        base = (at // EIGHTH) * EIGHTH
        for j in range(1, n + 1):
            due = base + j * 8 * (p + 1) * EIGHTH
            if due < nxt:
                jobs.append((due + EIGHTH // 2, ('rt', job[1])))
    jobs.sort(key=lambda e: e[0])
    for (a, ja), (b, jb) in zip(jobs, jobs[1:]):
        if 'rt' in (ja[0], jb[0]):                # host events keep their queue order
            assert b - a > 2500, ('jobs too close to order', a, b)
    return cmds, ram, xram, [j for _, j in jobs], ev


def legacy_events(ev):
    out = []
    for _, j in ev:
        if j[0] == 'inst':
            out.append(('inst', j[1], j[2], 0, 0))
        elif j[0] == 'on':
            out.append(('on', j[1], j[2], j[3], j[4]))
        else:
            out.append(('off', j[1], 0, 0, 0))
    return out


def run(wd, hpv8, ext, tag):
    cmds, ram, xram, jobs, ev = build(hpv8)
    rel = []; last = 0
    for at, r, v in cmds:
        rel.append((at - last, r, v)); last = at
    open(os.path.join(wd, tag + '_cmds.txt'), 'w').write(''.join('%d %d %d\n' % x for x in rel))
    for x in ('_out.txt', '_now.txt', '_time.txt'):
        p = os.path.join(wd, tag + x)
        if os.path.exists(p):
            os.remove(p)
    r = subprocess.run(['ghdl', '--elab-run', '--std=08', 'tb_engine', '-gCMD_FILE=' + tag + '_cmds.txt',
                        '-gOUT_FILE=' + tag + '_out.txt', '-gNOW_FILE=' + tag + '_now.txt',
                        '-gEXT=' + ('true' if ext else 'false'), '-gTIME_FILE=' + tag + '_time.txt'],
                       cwd=wd, capture_output=True, text=True)
    if r.returncode != 0:
        print(tag, 'ghdl failed:', r.stdout[-400:], r.stderr[-400:])
    got = [tuple(map(int, l.split())) for l in open(os.path.join(wd, tag + '_out.txt'))]
    nows = [l.split() for l in open(os.path.join(wd, tag + '_now.txt'))]
    rn = [int(x) for k, x in nows if k == 'r']; wn = [int(x) for k, x in nows if k == 'w']
    times = [tuple(map(int, l.split())) for l in open(os.path.join(wd, tag + '_time.txt'))]
    if ext:
        exp = engmodel_x.expected_x(jobs, rn, wn, ram, xram, hpv8)
    else:
        exp = engmodel.expected(legacy_events(ev), rn, wn, ram, hpv8)
    first = next((i for i, (a, b) in enumerate(zip(got, exp)) if a != b), None)
    ok = got == exp
    print('%-22s: writes %d expected %d, %s%s' % (
        tag, len(got), len(exp), 'IDENTICAL' if ok else 'DIFFER',
        '' if ok or first is None else ' at %d: %s vs %s' % (first, got[first:first + 4], exp[first:first + 4])))
    return ok, times, jobs


def check_times(times, tag):
    """v1: note + 3 retriggers 2 units apart; v2: note + 1 (the 2nd cancelled)."""
    ok = True
    for v, n, period in ((1, 3, 2 * UNIT), (2, 1, UNIT)):
        ts = [c for vv, c in times if vv == v]
        first = ts[0:n + 1]                     # the first note's read and its retriggers
        gaps = [b - a for a, b in zip(first, first[1:])]
        good = (len(gaps) == n and period - EIGHTH - 400 <= gaps[0] <= period + 400 and
                all(abs(g - period) <= 400 for g in gaps[1:]))
        print('  %s v%d retrigger gaps %s (period %d): %s' % (tag, v, gaps, period, 'ok' if good else 'WRONG'))
        ok &= good
    return ok


if __name__ == '__main__':
    wd = sys.argv[1] if len(sys.argv) > 1 else 'work'
    allok = True
    for hpv8 in (False, True):
        lay = '8x8' if hpv8 else '16x4'
        ok, times, jobs = run(wd, hpv8, True, 'ext_' + lay)
        allok &= ok
        allok &= check_times(times, 'ext_' + lay)
        ok, _, _ = run(wd, hpv8, False, 'locked_' + lay)
        allok &= ok
    print('EXT PASS' if allok else 'EXT FAIL')
    sys.exit(0 if allok else 1)
