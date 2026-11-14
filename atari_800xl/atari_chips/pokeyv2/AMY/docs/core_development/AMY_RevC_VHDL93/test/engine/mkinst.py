"""Instrument tables for amybox.c.  Levels in AMY amplitude units (1/4 dB), rates in dB/s.
AMY amplitude slope byte: bit 7 sign, bits 6-5 exponent (step every 128/32/8/2 samples),
bits 4-0 mantissa (two's complement with the sign: -m is (32-m)), one step = 1/128 dB."""
import math
FS = 3546895.0 / 256        # 2 x PHI2 (PAL), 64 harmonics: 13.85 kHz (set by build())
PERIOD = {0: 128, 1: 32, 2: 8, 3: 2}

def slope(rate, neg=False):
    """slope byte for |rate| dB/s"""
    best = None
    for e in (0, 1, 2, 3):
        unit = FS / PERIOD[e] / 128.0          # dB/s per mantissa step
        m = int(round(rate / unit))
        if 1 <= m <= 31:
            err = abs(m * unit - rate) / rate
            if best is None or err < best[0] - 1e-9: best = (err, e, m)
            if err < 0.03: break
    if best is None:                            # out of range: clamp
        e, m = (3, 31) if rate > 1 else (0, 1)
    else:
        _, e, m = best
    return (0x80 | (e << 5) | ((32 - m) & 31)) if neg else ((e << 5) | m)

def rate_of(b):
    e = (b >> 5) & 3; m = b & 31
    if b & 0x80: m = -((32 - m) & 31 or 32)
    return m * FS / PERIOD[e] / 128.0

OFF = 255
def db(x): return OFF if x is None else min(254, int(round(-4 * x)))   # dB (<=0) -> units below peak

def saw(k, p=1.0): return -20 * p * math.log10(k + 1)

INSTR = []
DEFS = []
def inst(name, lvl, atk=None, dec=None, sus=None, rel=100, gain=0):
    """lvl: dB per harmonic (None = off); atk: rise dB/s per harmonic (None = jump);
    dec/sus: decay dB/s and sustain dB below peak (None = to silence) per harmonic,
    pluck instruments only (jump attack); rel: release dB/s"""
    if dec is not None: assert atk is None, 'decay needs a jump attack'
    INSTR.append(dict(name=name,
        lvl=[db(None if l is None else l + gain) for l in lvl],
        atk=[0 if atk is None else slope(atk[k]) for k in range(16)],
        dec=[0 if dec is None else slope(dec[k], True) for k in range(16)],
        sus=[OFF if (sus is None or sus[k] is None) else db(sus[k]) for k in range(16)],
        hasdec=dec is not None,
        rel=slope(rel, True), relq=rel * 4 / 60.0))   # 1/4 dB per frame, at 60 Hz (an under-estimate)

def define():
    INSTR.clear()
    K = range(16)
    inst('PIANO',  [saw(k, 1.1) - (2.5 * (k - 7) if k > 7 else 0) for k in K],
         dec=[7 * (1 + 0.55 * k) for k in K], rel=150)
    inst('MUSICBOX', [0, -9, -20, -11, -26, -30, -33, -24] + [None] * 8,
         dec=[4, 12, 22, 16, 34, 40, 46, 36] + [50] * 8, rel=22, gain=-1)
    inst('ORGAN', [0, -2, -6, -5, None, -10, None, -12, None, -18] + [None] * 6,
         atk=[1600] * 16, rel=400, gain=-5)
    inst('BRASS', [saw(k, 0.75) for k in K],
         atk=[1000 / (1 + 0.45 * k) for k in K], rel=260, gain=-4)
    inst('CLARINET', [0 if k == 0 else (-4 - 3.4 * k if k % 2 == 0 else -34) for k in K],
         atk=[700] * 16, rel=240, gain=-3)
    inst('STRINGS', [saw(k, 1.0) for k in K],
         atk=[170 / (1 + 0.12 * k) for k in K], rel=70, gain=-4)
    inst('SYNTH', [saw(k, 0.6) for k in K],
         dec=[30 + 15 * k for k in K], sus=[-6 - 2 * k for k in K], rel=120, gain=-6)

ENSEMBLES = [('PIANO', ['PIANO'] * 4),
             ('BAND', ['BRASS', 'CLARINET', 'ORGAN', 'PIANO']),
             ('MUSIC BOX', ['MUSICBOX'] * 4),
             ('ORGAN', ['ORGAN'] * 4),
             ('STRINGS', ['STRINGS', 'STRINGS', 'STRINGS', 'PIANO']),
             ('SYNTH', ['SYNTH', 'BRASS', 'SYNTH', 'SYNTH'])]

# AMY clock options: name -> (AMY CLOCK in Hz, pitch correction PAL, NTSC)
#   2x:   2 x PHI2 (PAL 3.547 MHz)            locked to the Atari
#   4x:   4 x PHI2 (PAL 7.094 MHz)            locked to the Atari
#   clk8: PokeyMAX CLK / 8 = 57.344 MHz / 8 = 7.168 MHz, free running: the same
#         correction for PAL and NTSC (768 x log2(8 MHz / 7.168 MHz) = 121.7)
CLOCKS = {'2x': (2 * 1773447.0, 901, 891), '4x': (4 * 1773447.0, 133, 123), 'clk8': (57344000.0 / 8, 122, 122)}
def clock_fs(clk):            # sample rate, 64 harmonics
    return CLOCKS[clk][0] / 256
def clock_nyq(clk):           # band limit for hmax: 6400 Hz at 2 x PHI2, scaled
    return 6400.0 * CLOCKS[clk][0] / CLOCKS['2x'][0]

def hmax_table(lo=-16, hi=48, nyq=6400.0):
    t = []
    for n in range(lo, hi + 1):
        f = 261.6256 * 2 ** (n / 12.0)
        t.append(max(1, min(16, int(nyq / f))))
    return t

def tables(fs, nyq):
    global FS
    FS = fs; define()
    L = ['static const inst_t instr[NINST] = {']
    for i in INSTR:
        L.append('  { "%s", {%s},\n    {%s},\n    {%s},\n    {%s}, %d, %d, %d, %d },' % (
            i['name'], ','.join(map(str, i['lvl'])), ','.join(map(str, i['atk'])),
            ','.join(map(str, i['dec'])), ','.join(map(str, i['sus'])),
            int(i['hasdec']), i['rel'], max(1, int(i['relq'])), 255 // max(1, int(i['relq']))))
    L.append('};')
    L.append('static const unsigned char hmax[HMAX_N] = {%s};' % ','.join(map(str, hmax_table(-16, 48, nyq))))
    return L

def write(path):
    define()
    L = ['/* generated by mkinst.py: do not edit */',
         '#define NINST %d' % len(INSTR),
         'typedef struct { char name[10]; unsigned char lvl[16], atk[16], dec[16], sus[16];'
         ' unsigned char hasdec, rel, relq, relmax; } inst_t;   /* relmax = 255 / relq */',
         '#define HMAX_LO (-16)', '#define HMAX_N %d' % len(hmax_table(-16, 48))]
    L += ['#if defined(AMY_CLK8)   /* AMY at PokeyMAX CLK / 8 = 7.168 MHz: 28.0 kHz */']
    L += tables(clock_fs('clk8'), clock_nyq('clk8'))
    L += ['#elif defined(AMY_CLK4) /* AMY at 4 x PHI2: 27.7 kHz */']
    L += tables(clock_fs('4x'), clock_nyq('4x'))
    L += ['#else                   /* AMY at 2 x PHI2: 13.85 kHz */']
    L += tables(clock_fs('2x'), clock_nyq('2x'))
    L += ['#endif']
    names = [i['name'] for i in INSTR]
    L.append('#define NENS %d' % len(ENSEMBLES))
    L.append('static const char * const ens_name[NENS] = {%s};' % ','.join('"%s"' % e for e, _ in ENSEMBLES))
    L.append('static const unsigned char ens_inst[NENS][4] = {%s};' % ','.join(
        '{%s}' % ','.join(str(names.index(x)) for x in v) for _, v in ENSEMBLES))
    open(path, 'w').write('\n'.join(L) + '\n')

define()
if __name__ == '__main__':
    # self-check of the slope coder against the spec's examples (at 31.25 kHz... units only)
    assert abs(rate_of(slope(-rate_of(0xA4), True)) - rate_of(0xA4)) < 1e-6 and rate_of(0xA4) < 0
    assert abs(rate_of(slope(rate_of(0x24))) - rate_of(0x24)) < 1e-6 and rate_of(0xC4) * 8 / 128 * 128 / 13850.6 < 0
    for i in INSTR:
        print('%-9s rel %5.0f dB/s  atk %s' % (i['name'], -rate_of(i['rel']), [round(rate_of(b)) for b in i['atk'][:4]]))
    write('inst.h')
