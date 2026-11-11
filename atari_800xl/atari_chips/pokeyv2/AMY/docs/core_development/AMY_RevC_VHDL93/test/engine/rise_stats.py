"""Attacks that rise vs jump, at real time (2 x PHI2 PAL), engine model vs amybox's logs."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engmodel, mkinst
FRAME_CLK = 1773447.0 / 50
def count(out):
    j = r = 0
    for (r1, x), (r2, y) in zip(out, out[1:]):
        if r1 == 1 and r2 == 3 and y:
            if x == 0: j += 1
            elif x < 0x80: r += 1
    return j, r
names = [i['name'] for i in engmodel.instruments(False)]
ram = engmodel.ram_image(False)
song = sys.argv[1] if len(sys.argv) > 1 else 'CANTINA'
for e, (en, insts) in enumerate(mkinst.ENSEMBLES):
    ev = engmodel.song_events(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'songs', song + '.MUS'), [names.index(x) for x in insts])
    nows = [int(f * FRAME_CLK / engmodel.UNIT_TICKS) & 255 for (f, k, *_ ) in ev]
    rn = [n for n, e2 in zip(nows, ev) if e2[1] != 'inst']
    out = engmodel.expected([x[1:] for x in ev], rn, nows, ram)
    j, r = count(out)
    print('%-10s engine: jumps %5d rises %5d' % (en, j, r))
