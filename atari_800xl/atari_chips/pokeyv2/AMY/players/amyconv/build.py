"""arrangement -> engine RAM image, the chip-write log the player + engine produce (engmodel),
and a preview render.  usage: build.py SAP song frames out_prefix [preview_secs]"""
import sys, os
H = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, H)
import arrange, instruments as I, render8
import engmodel
FREQ0 = I.FREQ0
UNIT_S = I.UNIT_S
LFO = [0, 1, 1, 0, 0, -1, -1, 0]                   # vibrato, 8 frames a cycle (POKEY's), written on odd frames
LEFT, RIGHT = 0xCB, 0x75

def now(f): return int(f * 0.02 / UNIT_S) & 255

def init_writes():
    """chip_init's writes from the voice types on: (reg, value)"""
    w = [(3, 0)]
    for v in range(8): w += [(1, I.VOICE_TYPE[v]), (0, 0x10 + v)]
    w += [(1, 0)]
    for h in range(64): w += [(0, 0x40 + h)]
    for i in range(32): w += [(0, 0x80 + 2 * i + (1 if i % 4 == 3 else 0))]
    w += [(0, 0x33)]
    for a, x in enumerate(I.noise_image()): w += [(1, x), (0, 0x80 + a)]
    w += [(0, 0x31)]
    return w

def chip_log(ev, ram):
    """(frame, reg, value): per frame the player's vibrato writes (before the events, while
    the engine is idle), then the engine's writes for the frame's events"""
    mev = [e for e in ev if e[1] != 'vib']
    evs = [(e[1], e[2], e[3] if len(e) > 3 else 0, e[4] if len(e) > 4 else 0, e[5] if len(e) > 5 else 0) for e in mev]
    rn = [now(e[0]) for e in mev if e[1] != 'inst']; wn = [now(e[0]) for e in mev]
    marks = []
    out = engmodel.expected(evs, rn, wn, ram, hpv8=True, marks=marks)
    marks.append(len(out))
    eng = {}
    for i, e in enumerate(mev):
        eng.setdefault(e[0], []).extend(out[marks[i]:marks[i + 1]])
    by = {}
    for e in ev: by.setdefault(e[0], []).append(e)
    log = [(0, r, x) for r, x in init_writes()] + [(0, 4, LEFT), (0, 5, RIGHT)]
    note = {}; depth = {}
    for f in range(max(by) + 1):
        for v in range(8):                         # vibrato: a jump to the note's pitch + LFO
            if f % 2 and depth.get(v) and v in note:
                fw = (FREQ0 + note[v] * 64 + int(round(depth[v] * LFO[f % 8]))) & 0x1FFF
                log += [(f, 3, fw & 255), (f, 2, fw >> 8), (f, 1, 0), (f, 0, 0x08 + v)]
        for e in by.get(f, []):
            if e[1] == 'vib': depth[e[2]] = e[3]
            elif e[1] == 'on': note[e[2]] = e[3]
            elif e[1] == 'off': note.pop(e[2], None)
        log += [(f, r, x) for r, x in eng.get(f, [])]
    return log

if __name__ == '__main__':
    sap, song, frames, outp = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    hdr, ev, vinst, st = arrange.arrange(sap, song, frames)
    ram = I.ram_image(FREQ0)
    log = chip_log(ev, ram)
    open(outp + '.log', 'w').write(''.join('%d %d %d\n' % x for x in log))
    print(hdr['NAME'][0], dict(st), 'chip writes', len(log))
    if len(sys.argv) > 5:
        render8.render(outp + '.log', outp + '.wav', secs=float(sys.argv[5]))
