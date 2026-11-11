"""amyconv.xex in py65: per tune, the events it posts and its vibrato writes against the
arrangement (arrange.py / build.py), and its cycles per frame."""
import sys, os, re
H = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, H)
sys.path.insert(0, os.path.join(H, '..', 'vbi'))
import bench as vb                         # the py65 rig of vbiplay
import arrange, build, instruments as I, mkconv

def main(xex):
    base = 0x2E00; ok = True; allc = []
    for t, (name, who, sap, song, fr) in enumerate(mkconv.TUNES):
        rig = vb.Rig(xex)
        chipw = []
        orig = rig.wr
        def wr(a, v, rig=rig):
            orig(a, v)
            if a - vb.AMY < 4: chipw.append((rig.frame, a - vb.AMY, v))
        rig.mem.subscribe_to_write(range(vb.AMY, vb.AMY + 4), wr)
        rig.call(base + 3)
        if t == 0:                                 # chip_init: voice types, silence, LHP, Noise RAM
            iw = [(r, x) for f, r, x in chipw]
            k = iw.index((3, 0)) if (3, 0) in iw else 0
            init_ok = iw[k:] == build.init_writes()
            print('chip_init writes from the voice types on: %d, %s' % (len(iw) - k, 'SAME' if init_ok else 'DIFFERENT'))
            ok &= init_ok
        base_w = {}; ext_w = {}
        def ewr(a, v, rig=rig):
            if a - vb.AMY == 13:
                (ext_w if rig.regs[15] & 4 else base_w)[rig.regs[12]] = rig.regs[8] | rig.regs[9] << 8 | rig.regs[10] << 16 | v << 24
        rig.mem.subscribe_to_write([vb.AMY + 13], ewr)
        rig.call(base + 6)
        want = {w: x for w, x in I.ram_image(build.FREQ0).items() if w >= 40}
        if t == 0:
            xok = ext_w == I.ext_image()
            print('engine RAM upload: %s, extension page (128 words): %s, CONFIG %d' % (
                'SAME' if base_w == want else 'DIFFERENT', 'SAME' if xok else 'DIFFERENT', rig.regs[15]))
            ok &= base_w == want and xok and rig.regs[15] == 3
        rig.call(base + 9, t)
        rig.log = []; chipw.clear()
        cyc = []
        for f in range(-2, fr):                    # (two quiet frames first)
            rig.frame = f
            c = rig.call(base + 12)
            if f >= 0: cyc.append(c)
        got = []
        for (f, v, w0, w1, w2) in rig.log:
            if v >= 0xA0: got.append((f, 'inst', v & 7, w0))
            elif v >= 0x90: got.append((f, 'on', v & 7, w0, w1, w2))
            else: got.append((f, 'off', v & 7))
        hdr, ev, vi, st = arrange.arrange(os.path.join(mkconv.SAP, sap), song, fr)
        exp = [e[:6] for e in ev if e[1] != 'vib' and e[0] < fr]
        vib_exp = [x for x in build.chip_log(ev, I.ram_image(build.FREQ0)) if x[1] < 4 and x[0] < fr]
        # the vibrato writes are the chip writes outside the engine: build's log has both, so
        # compare the player's direct writes with build's frequency jumps that aren't engine ones
        eng = set()
        same_ev = got == exp
        first = next((i for i, (a, b) in enumerate(zip(got, exp)) if a != b), None)
        worst = sorted(range(fr), key=lambda i: -cyc[i])[:3]
        print('          worst frames', [(w, cyc[w], sum(1 for g in got if g[0] == w)) for w in worst])
        print('%-9s frames %5d events %5d %s, direct writes %d, cycles/frame mean %5.1f max %4d%s' % (
            name, fr, len(got), 'SAME' if same_ev else 'DIFFER', len(chipw), sum(cyc) / len(cyc), max(cyc),
            '' if same_ev else ' at %s: %s vs %s' % (first, got[first:first + 2] if first is not None else got[len(exp):][:2], exp[first:first + 2] if first is not None else exp[len(got):][:2])))
        ok &= same_ev
        vb_ok = check_vib(chipw, ev, fr)
        ok &= vb_ok
        allc += cyc
    print('all: max %d cycles = %.1f scanlines of 114' % (max(allc), max(allc) / 114.0))
    print('BENCH', 'PASS' if ok else 'FAIL')

def check_vib(chipw, ev, fr):
    """the player's frequency jumps: per frame, for voices with vibrato and a note"""
    by = {}
    for e in ev: by.setdefault(e[0], []).append(e)
    exp = []; note = {}; depth = {}
    for f in range(fr):
        for v in range(8):
            if f % 2 and depth.get(v) and v in note:
                fw = (build.FREQ0 + note[v] * 64 + int(round(depth[v] * build.LFO[f % 8]))) & 0x1FFF
                exp += [(f, 3, fw & 255), (f, 2, fw >> 8), (f, 1, 0), (f, 0, 0x08 + v)]
        for e in by.get(f, []):
            if e[1] == 'vib': depth[e[2]] = e[3]
            elif e[1] == 'on': note[e[2]] = e[3]
            elif e[1] == 'off': note.pop(e[2], None)
    same = chipw == exp
    first = next((i for i, (a, b) in enumerate(zip(chipw, exp)) if a != b), None)
    print('          vibrato writes %d expected %d %s%s' % (len(chipw), len(exp), 'SAME' if same else 'DIFFER',
          '' if same else ' at %s: %s vs %s' % (first, chipw[first:first + 4] if first is not None else '', exp[first:first + 4] if first is not None else '')))
    return same

if __name__ == '__main__':
    m = re.search(r'al 00([0-9A-F]{4}) \.nexttune', open(sys.argv[2] if len(sys.argv) > 2 else 'amyconv.lbl').read())
    vb.nsaddr = int(m.group(1), 16)
    main(sys.argv[1] if len(sys.argv) > 1 else 'amyconv.xex')
