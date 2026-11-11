"""Wrong-way slopes over whole amyconv tunes: the engine model's chip writes (build.chip_log),
with render8's envelope stepping (jumps immediate, as the fixed chip), checking every harmonic
and frequency breakpoint against the current value. No audio.  usage: AMYCONV=<amyconv folder> dircheck.py"""
import sys, os, numpy as np
AC = os.environ.get('AMYCONV', 'amyconv')       # amyconv's source folder (amyconv_src.zip)
sys.path.insert(0, AC)
import arrange, build, render8, instruments as I
TUNES = [('Draconus.sap', 0, 8985), ('Zybex.sap', 4, 6545), ('Warhawk.sap', 0, 10870)]
FS, FPS = render8.FS, 50.0
for sap, song, fr in TUNES:
    hdr, ev, vi, st = arrange.arrange(os.path.join(AC, 'sap', sap), song, fr)
    log = build.chip_log(ev, I.ram_image(build.FREQ0))
    by = {}
    for f, r, v in log: by.setdefault(f, []).append((r, v))
    A = B = C = 0
    cur = np.zeros(64); dst = np.zeros(64); rt = np.zeros(64)
    fw = np.zeros(8); fdst = np.zeros(8); frt = np.zeros(8)
    bad = []; nh = nf = 0; spf = FS / FPS
    for f in range(fr + 100):
        for r, v in by.get(f, []):
            if r == 1: A = v
            elif r == 2: B = v
            elif r == 3: C = v
            elif r == 0 and 0x40 <= v < 0x80:
                h = v & 63; dst[h] = C * 32; nh += 1
                if A & 31 == 0: cur[h] = dst[h]; rt[h] = 0
                else:
                    rt[h] = render8.rate(A)
                    if (rt[h] > 0) != (dst[h] > cur[h]) and dst[h] != cur[h]: bad.append(('harmonic', f, h, cur[h] / 32, C, hex(A)))
            elif r == 0 and 0x08 <= v < 0x10:
                vv = v & 7; fdst[vv] = ((B & 31) << 8 | C) * 32.0; nf += 1
                if A & 31 == 0: fw[vv] = fdst[vv]; frt[vv] = 0
                else:
                    frt[vv] = render8.rate(A)
                    if (frt[vv] > 0) != (fdst[vv] > fw[vv]) and fdst[vv] != fw[vv]: bad.append(('voice', f, vv, fw[vv] / 32, fdst[vv] / 32, hex(A)))
        n = spf
        c = cur + rt * n; cur = np.where(rt > 0, np.minimum(c, dst), np.maximum(c, dst))
        g = fw + frt * n; fw = np.where(frt > 0, np.minimum(g, fdst), np.maximum(g, fdst))
    print('%-13s %5.1f s: %6d harmonic and %5d frequency breakpoints, %d wrong-way' % (sap, fr / FPS, nh, nf, len(bad)))
    for b in bad[:5]: print('   ', b)
