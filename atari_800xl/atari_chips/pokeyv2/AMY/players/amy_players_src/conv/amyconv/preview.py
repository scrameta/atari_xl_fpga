#!/usr/bin/env python3
"""Preview a tune as amyconv plays it, Rev C features on or off.
The player's register writes (set-up, unlock, engine and extension upload, start_tune, per frame
vibrato then events) -> engine.py (the note engine, with the 6.8 extensions) -> chip writes ->
render8.py (Rev C off: bit-exact original noise) or amy_model.py (Rev C on: white noise,
proportional mode, detune, diffusion).
usage: preview.py SET TUNE on|off out.wav [secs] [voice mask]"""
import sys, os, subprocess
H = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, H)
os.environ.setdefault('AMYCONV_SET', sys.argv[1])
import mkconv, arrange, build, instruments as I, engine, render8

def player_log(ev, revc, frames):
    w = []; t = 0
    def put(r, v): w.append((t, r, v & 255))
    put(0, 0); put(0, 0x24)
    for r, v in build.init_writes(): put(r, v)
    put(4, build.LEFT); put(5, build.RIGHT); put(6, 0xF0)
    put(15, 3)
    for a, x in sorted(I.ram_image(build.FREQ0).items()):
        if a < 40: continue
        for r, v in ((12, a), (8, x), (9, x >> 8), (10, x >> 16), (13, x >> 24)): put(r, v)
    put(15, 7)
    for a, x in sorted(I.ext_image().items()):
        for r, v in ((12, a), (8, x), (9, x >> 8), (10, x >> 16), (13, x >> 24)): put(r, v)
    put(15, 3)
    if revc:
        for r, v in ((7, 0xA5), (7, 0x5A), (1, 0), (2, 0), (3, 0), (0, 0x39)): put(r, v)
    for h in range(64):
        for r, v in ((1, 0), (2, 0), (3, 0), (0, 0x40 + h)): put(r, v)
    by = {}
    for e in ev: by.setdefault(e[0], []).append(e)
    note = {}; depth = {}
    for f in range(frames):
        t = (f + 2) * 20
        for v in range(8):
            if f % 2 and depth.get(v) and v in note:
                fw = (build.FREQ0 + note[v] * 64 + int(round(depth[v] * build.LFO[f % 8]))) & 0x1FFF
                for r, x in ((3, fw & 255), (2, fw >> 8), (1, 0), (0, 0x08 + v)): put(r, x)
        for e in by.get(f, []):
            k, v = e[1], e[2]
            if k == 'vib': depth[v] = e[3]
            elif k == 'on':
                note[v] = e[3]
                if len(e) > 6: seq = ((8, e[3]), (9, e[4]), (11, 0x90 + v))
                else: seq = ((8, e[3]), (10, e[5]), (9, e[4]), (11, 0x90 + v))
                for r, x in seq: put(r, x)
            elif k == 'off':
                note.pop(v, None); put(11, 0x80 + v)
            elif k == 'inst':
                put(8, e[3]); put(11, 0xA0 + v)
    return w

if __name__ == '__main__':
    tune = int(sys.argv[2]); revc = sys.argv[3] == 'on'; out = sys.argv[4]
    secs = float(sys.argv[5]) if len(sys.argv) > 5 else None
    mask = int(sys.argv[6], 0) if len(sys.argv) > 6 else None
    name, who, sap, song, fr = mkconv.TUNES[tune]
    if secs: fr = min(fr, int(secs * 50))
    hdr, ev, vi, st = arrange.arrange(os.path.join(mkconv.SAP, sap), song, fr)
    eng = engine.Engine()
    for t, r, v in player_log(ev, revc, fr):
        eng.write(t, r, v)
    chip = eng.finish((fr + 2) * 20 + 2000)
    if mask is not None:                       # solo some voices
        chip = [(t, r, mask if r in (4, 5) else v) for t, r, v in chip]
    base = os.path.splitext(out)[0]
    if revc:
        open(base + '.chip.txt', 'w').write(''.join('%d %d %d\n' % x for x in chip))
        subprocess.run([sys.executable, os.path.join(H, 'amy_model.py'), base + '.chip.txt', out] +
                       (['--to', str(secs)] if secs else []), check=True)
    else:
        open(base + '.log', 'w').write(''.join('%d %d %d\n' % (t // 20, r, v) for t, r, v in chip))
        render8.render(base + '.log', out, secs=secs, left=build.LEFT if mask is None else mask,
                       right=build.RIGHT if mask is None else mask)
