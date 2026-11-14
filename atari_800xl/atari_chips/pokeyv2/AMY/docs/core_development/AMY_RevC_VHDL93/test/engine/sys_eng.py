"""Full system: amy1_top (ENGINE = true, the real chip) driven through the engine.
Writes the commands for tb_top, runs it, then checks
  - the chip writes (from the chip bus) against engmodel
  - every jump: the next write to that harmonic comes at least a sample later
usage: sys_eng.py workdir [hpv8] [x4 | clk8]
  x4:   AMY at 4 x PHI2: a tick every 8 clocks, steps 2 apart, the 4 x PHI2 tables
  clk8: AMY at CLK / 8: STEP_NUM / STEP_DEN = 3 / 8, the CLK / 8 tables
  (both: engine UNIT_LOG2 = 15)"""
import sys, os, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engmodel

SPACE = 8 * 40                     # host writes 40 steps apart (5 ns units, 8 per step)

def main(wd, hpv8, clk='2x'):
    ram = engmodel.ram_image(clk)
    names = [i['name'] for i in engmodel.instruments(clk)]
    ens = [names.index(x) for x in ('PIANO', 'PIANO', 'ORGAN', 'BRASS')]
    if hpv8:
        ens += [names.index('MUSICBOX'), names.index('STRINGS'), names.index('SYNTH'), names.index('CLARINET')]
    for i in range(len(names)):
        ram[48 + i] |= (0x14 << 8) | (0x94 << 24)          # glide slopes
    words = [40] + sorted(set([48 + i for i in ens] + [64 + 16 * i + k for i in ens for k in range(16)]))
    c = []; t = 2000
    def w(a, d, gap=SPACE):
        nonlocal t
        c.append((t, a, d)); t += gap
    w(16 + 15, 3 if hpv8 else 1)                           # engine on
    for x in words:
        v = ram[x]
        w(16 + 12, x)
        w(16 + 8, v & 255); w(16 + 9, (v >> 8) & 255); w(16 + 10, (v >> 16) & 255); w(16 + 13, (v >> 24) & 255)
    nv = len(ens)
    ev = [('inst', v, ens[v], 0, 0) for v in range(nv)]
    def evw(e):
        k, v, a, b, h = e
        if k == 'on':
            w(16 + 8, a); w(16 + 9, b); w(16 + 10, h); w(16 + 11, 0x90 + v)
        elif k == 'off':
            w(16 + 11, 0x80 + v)
        else:
            w(16 + 8, a); w(16 + 11, 0xA0 + v)
    for e in ev:
        evw(e)
    seq = []
    for v in range(nv):
        seq.append(('on', v, 40 + 5 * v, 0xD8, 16))
    seq += [('on', 0, 47, 0xD0, 12), ('on', 1, 38, 0xD8, 16), ('off', 2, 0, 0, 0), ('on', 2, 50, 0xE0, 6),
            ('off', 3, 0, 0, 0), ('off', 0, 0, 0, 0)]
    for e in seq:
        evw(e); ev.append(e)
        t += 8 * 4000                                      # ~5 samples between events
    stop = t + 8 * 60000
    cf = os.path.join(wd, 'sys_cmds.txt')
    open(cf, 'w').write(''.join('%d %d %d\n' % x for x in c))
    r = subprocess.run(['ghdl', '--elab-run', '--std=08', '-frelaxed', 'tb_top', '-gENGINE=true',
                        '-gCMD_FILE=sys_cmds.txt', '-gCHIP_FILE=sys_chip.txt', '-gOUT_FILE=sys_samp.txt',
                        '-gPCM_FILE=sys_pcm.txt', '-gSTOP=%d' % stop, '-gMEM_FILE=amy1_mem.hex'] +
                       {'2x': [], '4x': ['-gTICK_EVERY=8', '-gSTEP_SPACING=2', '-gUNIT_LOG2=15'],
                        'clk8': ['-gSTEP_NUM=3', '-gSTEP_DEN=8', '-gUNIT_LOG2=15']}[clk],
                       cwd=wd, capture_output=True, text=True)
    if r.returncode:
        print(r.stdout[-500:], r.stderr[-500:])
    got = []; when = []; samples = []; rn = []; wn = []
    for l in open(os.path.join(wd, 'sys_chip.txt')):
        f = l.split()
        if f[0] == 'W':
            got.append((int(f[2]), int(f[3]))); when.append(int(f[1]))
        elif f[0] == 'S':
            samples.append(int(f[1]))
        elif f[0] == 'r':
            rn.append(int(f[1]))
        else:
            wn.append(int(f[1]))
    exp = engmodel.expected(ev, rn, wn, ram, hpv8)
    first = next((i for i, (a, b) in enumerate(zip(got, exp)) if a != b), None)
    ok = got == exp
    print('system %s%s: chip writes %d expected %d, %s%s' % ('8x8' if hpv8 else '16x4', ' ' + clk if clk != '2x' else '', len(got), len(exp),
          'IDENTICAL' if ok else 'DIFFER', '' if ok or first is None else ' at %d: %s vs %s' % (first, got[first:first+4], exp[first:first+4])))
    # jumps: the next write to the same harmonic at least one sample later
    per = sorted(b - a for a, b in zip(samples, samples[1:]))[len(samples) // 2]
    A = None; last_jump = {}; worst = None; jumps = 0; nearest = []
    for (r, x), s in zip(got, when):
        if r == 1: A = x
        elif r == 0 and 0x40 <= x < 0x80:
            h = x & 63
            if h in last_jump:
                gap = (s - last_jump.pop(h)) / per
                nearest.append(gap)
            if A == 0:
                last_jump[h] = s; jumps += 1
    lost = sum(1 for g in nearest if g < 1.0)
    print('   jumps %d, next write to the same harmonic after %.2f samples at the least; closer than a sample: %d'
          % (jumps, min(nearest) if nearest else 0, lost))
    pcm = [tuple(map(int, l.split())) for l in open(os.path.join(wd, 'sys_pcm.txt'))]
    peak = max(max(abs(a), abs(b)) for a, b in pcm) if pcm else 0
    print('   samples %d, peak %d' % (len(pcm), peak))
    return ok and lost == 0

if __name__ == '__main__':
    clk = '4x' if 'x4' in sys.argv[2:] else 'clk8' if 'clk8' in sys.argv[2:] else '2x'
    ok = main(sys.argv[1], 'hpv8' in sys.argv[2:], clk)
    print('SYSTEM', 'PASS' if ok else 'FAIL')
