"""Drive tb_engine with a song: setup + events, then compare its pushes with engmodel."""
import sys, os, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engmodel, mkinst
FRAME = 1108                               # clocks per frame at 1/32 time scale

def cmds_for(song, ens, frames=None, hpv8=False):
    names = [i['name'] for i in engmodel.instruments(False)]
    ens_inst = [names.index(x) for x in mkinst.ENSEMBLES[ens][1]]
    ram = engmodel.ram_image(False)
    ev = engmodel.song_events(song, ens_inst, frames)
    return cmds_from(ram, ev, hpv8), ram, [e[1:] for e in ev]

def cmds_from(ram, ev, hpv8=False):
    """host writes: engine on, RAM words 32..255, then events (frame, kind, v, a, b, c);
    kind 'ram' writes word a <= b at that frame (takes effect at once, not queued)"""
    c = [(4, 7, 3 if hpv8 else 1)]          # engine on
    for w in range(32, 256):                 # RAM upload, words 32..255
        x = ram.get(w, 0)
        c += [(8, 4, w), (8, 0, x & 255), (8, 1, (x >> 8) & 255), (8, 2, (x >> 16) & 255), (8, 5, (x >> 24) & 255)]
    clk = sum(d for d, _, _ in c)
    for (fr, kind, v, note, lvl, hm) in ev:
        at = 2000 + fr * FRAME
        d = max(8, at - clk)
        if kind == 'on':
            seq = [(0, note), (1, lvl), (2, hm), (3, 0x90 + v)]
        elif kind == 'off':
            seq = [(3, 0x80 + v)]
        elif kind == 'ram':
            x = lvl
            seq = [(4, note), (0, x & 255), (1, (x >> 8) & 255), (2, (x >> 16) & 255), (5, (x >> 24) & 255)]
        else:
            seq = [(0, note), (3, 0xA0 + v)]
        for i, (r, x) in enumerate(seq):
            c.append((d if i == 0 else 8, r, x))
            clk += d if i == 0 else 8
            d = 8
    return c

def run(song, ens, frames, workdir, tag, hpv8=False):
    c, ram, ev = cmds_for(song, ens, frames, hpv8)
    return run_cmds(c, ram, ev, workdir, tag, hpv8, os.path.basename(song) + ' ens %d' % ens)

def run_cmds(c, ram, ev, workdir, tag, hpv8=False, name=''):
    cf = os.path.join(workdir, tag + '_cmds.txt')
    open(cf, 'w').write('\n'.join('%d %d %d' % x for x in c) + '\n')
    for x in ('_out.txt', '_now.txt'):
        if os.path.exists(os.path.join(workdir, tag + x)):
            os.remove(os.path.join(workdir, tag + x))
    r = subprocess.run(['ghdl', '--elab-run', '--std=08', 'tb_engine', '-gCMD_FILE=' + tag + '_cmds.txt',
                        '-gOUT_FILE=' + tag + '_out.txt', '-gNOW_FILE=' + tag + '_now.txt'],
                       cwd=workdir, capture_output=True, text=True)
    if r.returncode != 0:
        print(tag, 'ghdl failed:', r.stdout[-300:], r.stderr[-300:])
    got = [tuple(map(int, l.split())) for l in open(os.path.join(workdir, tag + '_out.txt'))]
    nows = [l.split() for l in open(os.path.join(workdir, tag + '_now.txt'))]
    rn = [int(x) for k, x in nows if k == 'r']; wn = [int(x) for k, x in nows if k == 'w']
    exp = engmodel.expected(ev, rn, wn, ram, hpv8)
    n_on = sum(1 for e in ev if e[0] == 'on')
    first = next((i for i, (a, b) in enumerate(zip(got, exp)) if a != b), None)
    ok = got == exp
    print('%-16s: events %d (notes %d), writes %d expected %d, %s%s' % (
        name, len(ev), n_on, len(got), len(exp), 'IDENTICAL' if ok else 'DIFFER',
        '' if ok or first is None else ' at %d: %s vs %s' % (first, got[first:first + 3], exp[first:first + 3])))
    return ok, got, exp

if __name__ == '__main__':
    song, ens, frames = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else None
    run(song, ens, frames, sys.argv[4] if len(sys.argv) > 4 else '.', 'e%d' % ens)
