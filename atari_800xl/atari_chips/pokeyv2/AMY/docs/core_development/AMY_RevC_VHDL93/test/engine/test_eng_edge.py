"""tb_engine edge cases against engmodel: glide (legato up/down), rise vs jump by
release age, partial band limits and levels, a burst that fills the queue,
instrument changes, a header rewritten between notes, 8 x 8 layout.
usage: test_eng_edge.py workdir"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engmodel, run_eng

def events(nv):
    ev = []
    for v in range(nv):
        ev.append((0, 'inst', v, [0, 3, 5, 6, 1, 4, 2, 0][v], 0, 0))
    f = 2
    for v in range(nv):                       # legato up, legato down, release, quick retrigger
        ev += [(f, 'on', v, 50 + v, 0xD8, 16), (f + 3, 'on', v, 57 + v, 0xD8, 16),
               (f + 6, 'on', v, 45 + v, 0xC0, 9), (f + 9, 'off', v, 0, 0, 0),
               (f + 10, 'on', v, 52, 0xD8, 16), (f + 12, 'off', v, 0, 0, 0)]
    f += 80                                    # long after the release: attacks rise
    for v in range(nv):
        ev += [(f, 'on', v, 60, 0xE0, 5 + v), (f + 2, 'on', v, 61, 0x20, 16), (f + 8, 'off', v, 0, 0, 0)]
    f += 20                                    # a burst of 20 events in one frame (queue full)
    for i in range(20):
        v = i % nv
        ev.append((f, 'on' if i % 2 == 0 else 'off', v, 40 + i, 0xD8, 16))
    f += 30                                    # new instrument header between notes, new instrument
    ev.append((f, 'ram', 0, 48 + 3, 0x82 | (0x11 << 8) | (2 << 16) | (1 << 23) | (0x91 << 24), 0))
    ev.append((f, 'inst', 1, 3, 0, 0))
    ev += [(f + 1, 'on', 1, 30, 0xD8, 16), (f + 2, 'on', 1, 70, 0xD8, 16), (f + 3, 'on', 1, 20, 0xD8, 16),
           (f + 20, 'off', 1, 0, 0, 0)]
    ev.sort(key=lambda e: e[0])
    return ev

def main(wd):
    ok = True
    for hpv8 in (False, True):
        ram = engmodel.ram_image(False)
        for i in range(7):                     # glide slopes in every header: up $14, down $94
            ram[48 + i] |= (0x14 << 8) | (0x94 << 24)
        ev = events(8 if hpv8 else 4)
        c = run_eng.cmds_from(ram, ev, hpv8)
        r, got, exp = run_eng.run_cmds(c, ram, [e[1:] for e in ev], wd, 'edge%d' % hpv8, hpv8,
                                       'edge %s' % ('8x8' if hpv8 else '16x4'))
        glides = sum(1 for (r1, x), (r2, _) in zip(exp, exp[1:]) if r1 == 1 and r2 == 2 and x)
        rises = sum(1 for (r1, x), (r2, y) in zip(exp, exp[1:]) if r1 == 1 and r2 == 3 and y and 0 < x < 0x80)
        print('   glided frequencies %d, rising attacks %d' % (glides, rises))
        ok &= r
    print('EDGE', 'PASS' if ok else 'FAIL')

main(sys.argv[1])
