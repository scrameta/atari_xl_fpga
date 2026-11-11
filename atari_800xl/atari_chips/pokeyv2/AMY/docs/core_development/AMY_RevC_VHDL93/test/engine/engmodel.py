"""amy1_engine helpers: instrument RAM image, song events, and a reference model.

  ram_image(clk4)            -> {word: value} for words 32..255 (globals, headers, instruments)
  song_events(song, ens)     -> [(frame, kind, voice, note, level, hm)] as amybox plays them
  expected(events, nows, ram) -> AMY register writes [(reg, value)] the engine must produce
"""
import math, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mkinst, mus

A440 = 0x138C
UNIT_TICKS = 1 << 14                       # engine time unit (UNIT_LOG2 = 14) at 2 x PHI2, internal clocks
UNIT_LOG2_OF = {'2x': 14, '4x': 15, 'clk8': 15}   # ~9.2 ms at every clock: the engine's UNIT_LOG2

def clock(clk):
    """'2x', '4x', 'clk8' (mkinst.CLOCKS); False / True mean '2x' / '4x'"""
    return {False: '2x', True: '4x'}.get(clk, clk)
class _U(dict):
    def __missing__(self, k): return UNIT_LOG2_OF[clock(k)]
UNIT_LOG2 = _U()
def internal_hz(clk):
    return mkinst.CLOCKS[clock(clk)][0] / 2
def fcorr(clk, ntsc=False):
    return mkinst.CLOCKS[clock(clk)][2 if ntsc else 1]
HMAX_LO = -16

def instruments(clk4):
    mkinst.FS = mkinst.clock_fs(clock(clk4))
    mkinst.define()
    return list(mkinst.INSTR)

def hmax(clk4):
    return mkinst.hmax_table(HMAX_LO, 48, mkinst.clock_nyq(clock(clk4)))

def ram_image(clk4=False):
    ram = {}
    ram[40] = (A440 + fcorr(clk4) - 73 * 64) & 0x1FFF        # frequency word of note code 0 (PAL)
    unit_s = (1 << UNIT_LOG2[clk4]) / internal_hz(clk4)
    for i, ins in enumerate(instruments(clk4)):
        rel_dbs = -mkinst.rate_of(ins['rel'])
        drop = min(31, int(math.floor(rel_dbs * unit_s * 4)))       # 1/4 dB per unit, rounded down
        hdr = ins['rel'] | (0 << 8) | (drop << 16) | ((1 if ins['hasdec'] else 0) << 23) | (0 << 24)
        ram[48 + i] = hdr
        for k in range(16):
            ram[64 + 16 * i + k] = ins['lvl'][k] | (ins['atk'][k] << 8) | (ins['dec'][k] << 16) | (ins['sus'][k] << 24)
    for v in range(8):
        ram[32 + v] = 0 | (1 << 4)                             # instrument 0, released, ceiling 0
    return ram

def song_events(path, ens_inst, frames=None, clk4=False):
    """Port of amybox's JCODE player: events with the frame they happen in.
    note codes are amybox's (64 = C4); level = $B8 + vel/4."""
    import mksongs
    blob = mksongs.encode(path)
    tempo, ndur = blob[0], blob[1]
    durtab = blob[2:2 + 2 * ndur]
    o = 2 + 2 * ndur
    vp = [blob[o + 2 * v] | (blob[o + 2 * v + 1] << 8) for v in range(4)]
    vstate = [0] * 4; von = [0] * 4; vgap = [0] * 4; vbase = [128] * 4; vrest = [0] * 4
    ev = []; frame = 0; tacc = 0; treg = 1; playing = True
    hm = hmax(clk4)
    ev += [(0, 'inst', v, ens_inst[v], 0, 0) for v in range(4)]
    while playing and (frames is None or frame < frames):
        frame += 1
        tacc += 1457
        while tacc >= 1000:
            tacc -= 1000
            treg -= 1
            if treg != 0 or not playing:
                continue
            treg = tempo
            alive = False
            for v in range(4):
                if vstate[v] == 0:
                    p = vp[v]
                    while blob[p] == 1:
                        vbase[v] = blob[p + 1]; p += 2
                    b = blob[p]
                    if b == 0:
                        vp[v] = p; vstate[v] = 3
                    else:
                        d = blob[p + 1]
                        von[v], vgap[v] = durtab[2 * d], durtab[2 * d + 1]
                        vrest[v] = b == 2
                        if not vrest[v]:
                            code = b & 0x7F
                            vel = vbase[v] + (16 if b & 0x80 else 0)
                            k = code - 64 - HMAX_LO
                            ev.append((frame, 'on', v, code, (0xB8 + (vel >> 2)) & 0xFF, hm[min(k, len(hm) - 1)]))
                        vp[v] = p + 2
                        vstate[v] = 1
                if vstate[v] == 1:
                    von[v] -= 1
                    if von[v] == 0:
                        if not vrest[v]:
                            ev.append((frame, 'off', v, 0, 0, 0))
                        vstate[v] = 2
                elif vstate[v] == 2:
                    vgap[v] -= 1
                    if vgap[v] == 0:
                        vstate[v] = 0
                if vstate[v] != 3:
                    alive = True
            if not alive:
                playing = False
    return ev

def expected(events, rnows, wnows, ram, hpv8=False, stats=None):
    """The engine's writes for events (in order). rnows: the engine's time when it
    read each on/off event's voice state; wnows: when it wrote each event's state.
    An event carries the host's word builder as it was: on writes W0..W2, an
    instrument event W0, an off event none."""
    ram = dict(ram)
    out = []
    rn = iter(rnows); wn = iter(wnows)
    w = [0, 0, 0]
    for (kind, v, note, lvl, hm) in events:
        if kind == 'ram':                     # host RAM write: word note <= lvl
            ram[note] = lvl
            continue
        if kind == 'on':
            w = [note, lvl, hm]
        elif kind == 'inst':
            w[0] = note
        note, lvl, hm = w[0] & 127, w[1], w[2] & 31
        now = next(rn) if kind != 'inst' else None
        wnow = next(wn)
        vs = ram.get(32 + v, 0)
        if kind == 'inst':
            ram[32 + v] = (w[0] & 15) | (1 << 4) | (wnow << 8) | (note << 24)
            continue
        inst = vs & 15
        legato = not (vs >> 4) & 1
        age = (now - ((vs >> 8) & 255)) & 255
        ceil = (vs >> 16) & 255
        hdr = ram.get(48 + inst, 0)
        rel = hdr & 255
        d = (hdr >> 16) & 31
        x = lvl - ceil                         # the ceiling falls by d per unit released
        n = age
        while x < 8 and not legato and n != 0:
            x += d; n -= 1
        rise = x >= 8
        cnew = lvl if (kind == 'on' and x >= 0) else (lvl - x) & 255
        if stats is not None and kind == 'on':
            stats['rise' if rise else 'jump'] += 1
        hpv = 8 if hpv8 else 16
        hb = v * hpv
        if kind == 'off':
            for k in range(hpv):
                out += [(1, rel), (3, 0), (0, 0x40 + hb + k)]
            ram[32 + v] = inst | (1 << 4) | (wnow << 8) | (cnew << 16) | (note << 24)
            continue
        up = note > ((vs >> 24) & 127)
        glide = 0
        if legato:
            glide = (hdr >> 8) & 255 if up else (hdr >> 24) & 255
        f = (ram.get(40, 0) + note * 64) & 0x1FFF
        out += [(1, glide), (2, f >> 8), (3, f & 255), (0, 0x08 + v)]
        decay = (hdr >> 23) & 1
        for pas in (0, 1) if decay else (0,):
            for k in range(hpv):
                wd = ram.get(((inst + 4) & 15) * 16 + k, 0)
                lo, atk, dec, sus = wd & 255, (wd >> 8) & 255, (wd >> 16) & 255, (wd >> 24) & 255
                p = lvl - lo
                inn = k < hm and lo != 255 and p > 0
                if pas == 0:
                    if inn:
                        out += [(1, atk if rise else 0), (3, p), (0, 0x40 + hb + k)]
                    else:
                        out += [(1, rel), (3, 0), (0, 0x40 + hb + k)]
                else:
                    if inn and (not rise or atk == 0):
                        out += [(1, dec), (3, max(0, p - sus)), (0, 0x40 + hb + k)]
        ram[32 + v] = inst | (0 << 4) | (wnow << 8) | (cnew << 16) | (note << 24)
    return out
