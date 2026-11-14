"""tb_top command file for amyconv/Warhawk, real 50 Hz frames: chip_init, eng_init, start_tune,
the instrument events, then frames F0..F1 (vibrato state tracked from frame 0).
usage: AMYCONV=<amyconv folder> mkwh2.py out.txt F0 F1      (command-file units: 8 per 57.344 MHz clk)"""
import sys, os
AC = os.environ.get('AMYCONV', 'amyconv')       # amyconv's source folder (amyconv_src.zip)
sys.path.insert(0, AC)
import arrange, build, instruments as I
out, F0, F1 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
UNITS_CLK = 8; CLK = 57.344e6
us = lambda x: int(round(x * 1e-6 * CLK * UNITS_CLK))
FRAME = us(20000); CPUW = us(5 / 1.79)        # a 6502 store every ~5 cycles
c = []; t = us(1)
def w(a, d, gap):
    global t
    c.append((t, a, d & 255)); t += gap
w(0, 0x00, us(100)); w(0, 0x24, us(20))
for r, x in build.init_writes():
    w(r, x, us(200) if (r == 0 and x == 0x33) else us(20) if r == 0 else CPUW)
w(4, build.LEFT, CPUW); w(5, build.RIGHT, CPUW); w(6, 0xF0, CPUW)
ram = I.ram_image(build.FREQ0)
w(16 + 15, 3, CPUW)
for x in sorted(ram):
    if x < 32: continue
    v = ram[x]
    for r, d in ((12, x), (8, v), (9, v >> 8), (10, v >> 16), (13, v >> 24)): w(16 + r, d, CPUW)
for x in range(64):                               # start_tune: every harmonic jumps to 0
    w(1, 0, CPUW); w(3, 0, CPUW); w(0, 0x40 + x, us(40))
hdr, ev, vi, st = arrange.arrange(os.path.join(AC, 'sap', 'Warhawk.sap'), 0, 10870)
by = {}
for e in ev: by.setdefault(e[0], []).append(e)
base = t + 2 * FRAME
note = {}; depth = {}
def post(e):
    k = e[1]; v = e[2]
    if k == 'on':
        w(16 + 8, e[3], CPUW); w(16 + 10, e[5], CPUW); w(16 + 9, e[4], CPUW); w(16 + 11, 0x90 + v, CPUW)
    elif k == 'off': w(16 + 11, 0x80 + v, CPUW)
    elif k == 'inst': w(16 + 8, e[3], CPUW); w(16 + 11, 0xA0 + v, CPUW)
for f in range(0, F1 + 1):
    live = f == 0 or f >= F0
    if live: t = max(t, base + (0 if f == 0 else f - F0 + 1) * FRAME)
    if live and f % 2:                            # vibrato: odd frames, before the events
        for v in range(8):
            if depth.get(v) and v in note:
                fw = (build.FREQ0 + note[v] * 64 + int(round(depth[v] * build.LFO[f % 8]))) & 0x1FFF
                w(3, fw & 255, CPUW); w(2, fw >> 8 & 31, CPUW); w(1, 0, CPUW); w(0, 0x08 + v, CPUW)
    for e in by.get(f, []):
        if e[1] == 'vib': depth[e[2]] = e[3]; continue
        if e[1] == 'on': note[e[2]] = e[3]
        if e[1] == 'off': note.pop(e[2], None)
        if live and (f >= F0 or e[1] == 'inst'): post(e)
stop = base + (F1 - F0 + 2) * FRAME
open(out, 'w').write(''.join('%d %d %d\n' % x for x in c))
print('stop', stop, 'writes', len(c), 'frame units', FRAME)
