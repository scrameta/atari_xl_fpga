"""AMY instruments for the POKEY conversions, 8 harmonics x 8 voices, AMY Rev. C 8.192 MHz.
Each is an engine header + 16 harmonic words (only 8 are used in the 8 x 8 layout)."""
import sys, os, math
import mkinst, engmodel
CLK = 'clk8192'
mkinst.FS = mkinst.clock_fs(CLK)
UNIT_S = (1 << engmodel.UNIT_LOG2[CLK]) / engmodel.internal_hz(CLK)
FREQ0 = (engmodel.A440 + engmodel.fcorr(CLK) - 73 * 64) & 0x1FFF
OFF = 255

def db(x):                      # dB below the note level (<= 0) -> 1/4 dB units, None = off
    return OFF if x is None else min(254, int(round(-4 * x)))

class Inst:
    def __init__(self, name, lvl, atk=None, dec=None, sus=None, rel=150, glide=(0, 0)):
        """lvl: dB per harmonic; atk dB/s per harmonic (None = jump); dec dB/s and sus dB
        below the peak per harmonic (plucked: needs a jump attack); rel dB/s"""
        n = len(lvl)
        self.name = name
        self.lvl = [db(l) for l in lvl] + [OFF] * (16 - n)
        self.atk = [0 if atk is None else mkinst.slope(atk[k]) for k in range(n)] + [0] * (16 - n)
        self.dec = [0 if dec is None else mkinst.slope(dec[k], True) for k in range(n)] + [0] * (16 - n)
        self.sus = [OFF if (sus is None or sus[k] is None) else db(sus[k]) for k in range(n)] + [OFF] * (16 - n)
        self.hasdec = dec is not None
        self.rel = mkinst.slope(rel, True)
        self.drop = min(31, int(math.floor(-mkinst.rate_of(self.rel) * UNIT_S * 4)))
        self.glide = glide
    def header(self):
        return self.rel | (self.glide[0] << 8) | (self.drop << 16) | (int(self.hasdec) << 23) | (self.glide[1] << 24)
    def words(self):
        return [self.lvl[k] | self.atk[k] << 8 | self.dec[k] << 16 | self.sus[k] << 24 for k in range(16)]

def sq(k, warm=0.0):            # square wave, harmonic k+1: odd 1/n, even (AMY warmth) at warm dB
    n = k + 1
    return -20 * math.log10(n) if n % 2 else (None if warm is None else warm - 20 * math.log10(n))

K8 = range(8)
INSTRUMENTS = [
    # POKEY distortion C bass: the poly-4 waveform's near-flat harmonics, a little softened
    Inst('BUZZ', [0, -0.5, -1.5, -2.5, -4, -5.5, -7.5, -9.5], dec=[24 + 3 * k for k in K8],
         sus=[-8 - 0.5 * k for k in K8], rel=160),
    # pure tone lead: square, plucked like the POKEY volume ramp
    Inst('LEAD', [sq(k, -18) for k in K8], dec=[22 + 4 * k for k in K8], sus=[-6 - k for k in K8], rel=140),
    # slow-attack pad: rounder square
    Inst('PAD', [sq(k, -22) - (1.5 * k) for k in K8], atk=[120 / (1 + 0.15 * k) for k in K8], rel=60),
    # hat (from the drum-kit experiment, refitted to 8 harmonics): noise voice on generator 0;
    # harmonics 3-8 of ~1.4 kHz (4.2-11 kHz) as bands of noise, gone in ~40 ms. The first two off.
    Inst('HAT', [None, None] + [-1.0 * (k - 3) for k in range(3, 9)],
         dec=[0, 0] + [900 + 40 * k for k in range(3, 9)], rel=900),
    # snare: the kit's "T3" hiss refitted to 8 harmonics: noise voice on generator 1,
    # harmonics 3-8 of ~1.3 kHz (3.9-10.4 kHz), ~150 ms
    Inst('SNARE', [None, None] + [-1.0 * (k - 3) for k in range(3, 9)],
         dec=[0, 0] + [260 + 20 * k for k in range(3, 9)], rel=500),
    # the long noise hit on the bass channel: a bigger, darker snare
    Inst('CLAP', [0, -0.5, -1, -2, -3, -4, -5, -6], dec=[55 + 12 * k for k in K8], rel=300),
    # tom: POKEY's falling tone, a soft square that glides down (a second, legato note)
    Inst('TOM', [sq(k, -20) - 2 * k for k in K8], dec=[28 + 8 * k for k in K8], rel=200, glide=(0, 0x80 | (3 << 5) | (32 - 3))),
    # kick (the drum-kit experiment's "kick 2"): a deep tone, 130 Hz gliding down to ~46 Hz at
    # AMY's fastest glide (a legato second note), a long low tail, and a beater click on
    # harmonics 5-8 that dies in a few ms
    Inst('KICK', [0, -6, -16, -26, -13, -15, -17, -19], dec=[55, 95, 200, 350, 1800, 1800, 1800, 1800],
         rel=300, glide=(0, 0x80 | (3 << 5) | (32 - 30))),
    # Set 1's swelling notes.  Both let go fast (600 dB/s), for two reasons.  A note-off then
    # dips the voice 12 dB a frame, so "off, and the next note a frame later" re-articulates a
    # run of notes the way POKEY's volume does (back to 1 or 2, then up again); a legato
    # note-on can't, it only moves the pitch.  And the engine then knows the voice has fallen
    # (release drop 19 a unit), so that next note gets its attack and not a jump.
    # SWELL, the quick one (Warhawk's lead: POKEY volume 2 3 4 7 8 9 in 0.1 s, then held, with
    # a deep vibrato): PAD's rounder square with a fast attack.  The attack byte $68 is +8
    # every 2 samples (1000 dB/s: there in under 50 ms) and, in proportional mode with the
    # Rev C extensions (EXT below), E 3 k 8: an exponential rise, tau 16 ms
    Inst('SWELL', [sq(k, -22) - (1.5 * k) for k in K8], atk=[1000] * 8, rel=600),
    # PAD2, the slow one (Draconus: 1 to 8 over 14 frames): PAD, but for the release
    Inst('PAD2', [sq(k, -22) - (1.5 * k) for k in K8], atk=[120 / (1 + 0.15 * k) for k in K8], rel=600),
]
NAMES = [i.name for i in INSTRUMENTS]

# AMY voice types per voice (0 harmonic, 1 noise generator 0, 2 generator 1): the drum voices
# of arrange.py are noise voices
VOICE_TYPE = [0, 0, 0, 0, 0, 1, 2, 0]                 # (v4, the kick, is a harmonic voice)
# (the generic arrangements use the same drum voices, v5 HAT and v6 SNARE)
# Noise RAM image (command address = row * 2 + generator), loaded once by chip_init: rows 0-14
# the pseudo-random registers (any non-zero value), rows 20-31 UD, B and S.  S sets the colour:
# 0x80F is the brightest that keeps the output word within +-1024 (S bit 11 set). Without bit 11
# ($00F) the noise bands are a little wider, but the word spans +-2048 and the noise has peaks of
# ~5x, which clipped the mix; with $80F the snare sounds much the same and its peaks stay ~1.5x.
NOISE_GENS = [dict(a=0x1234, b=0x4D2B, c=0x7A11, ud=0, bb=0, s=0x80F),     # hat
              dict(a=0x6E5F, b=0x0F0F, c=0x3333, ud=0, bb=0, s=0x80F)]     # snare
def noise_image():
    m = [0] * 64
    for g, d in enumerate(NOISE_GENS):
        for i in range(15):
            m[(14 - i) * 2 + g] = ((d['a'] >> i) & 1) << 2 | ((d['b'] >> i) & 1) << 1 | ((d['c'] >> i) & 1)
        for i in range(12):
            m[(20 + i) * 2 + g] = ((d['ud'] >> i) & 1) << 2 | ((d['bb'] >> i) & 1) << 1 | ((d['s'] >> i) & 1)
    return m

def ram_image(freq0):
    ram = {40: freq0}
    for i, ins in enumerate(INSTRUMENTS):
        ram[48 + i] = ins.header()
        for k, w in enumerate(ins.words()):
            ram[64 + 16 * i + k] = w
    for v in range(8):
        ram[32 + v] = 1 << 4
    return ram

# Rev C engine extensions (spec 6.8), per instrument, used while the extensions are unlocked
# (the player's OPTION key): voice type sent on select, trim (EXT_VATT, 1/4 dB), pitch
# envelope (start offset in 1/4 semitones, proportional rate), and per harmonic slot detune
# (k + 1 + d/64), diffusion (63: the slot is white noise) and the proportional-decay flag.
def PROP(e, k): return (e << 5) | k
EXT = {
    # the poly-4 buzz: a little grit on the upper harmonics
    'BUZZ':  dict(det=[0] * 8, sto=[0, 0, 2, 4, 6, 8, 10, 12]),
    # pads: a slow shimmer, more on the upper harmonics
    'PAD':   dict(det=[0, 0, 0, 0, 0, 0, 0, 0], sto=[0, 6, 8, 10, 12, 14, 16, 18]),
    # the quick swell: the same shimmer, and the attack eases in (proportional mode)
    'SWELL': dict(det=[0] * 8, sto=[0, 6, 8, 10, 12, 14, 16, 18], pfa=[1] * 8),
    'PAD2':  dict(det=[0] * 8, sto=[0, 6, 8, 10, 12, 14, 16, 18]),
    # hat and snare: Rev C white noise (voice type 3) instead of the original noise generators
    'HAT':   dict(vtype=3, trim=16),          # trims: white noise is ~4 dB louder than the originals
    'SNARE': dict(vtype=3, trim=16),
    # kick: an exponential pitch drop (tau 16 ms) from the arrangement's 130 Hz to its 46 Hz:
    # the second, legato note-on (KICK_LO) starts it at KICK_LO + 18 semitones = KICK_HI;
    # the beater click partials detuned and diffused, the last one a noise click
    'KICK':  dict(poff=4 * 18, prate=PROP(3, 8), det=[0, 0, 0, 0, 21, -17, 9, 0], sto=[0, 0, 0, 0, 48, 48, 48, 63]),
}
EXT_TRIM = {}                   # set by the level calibration (1/4 dB)

def ext_image():
    """the extension page, all 128 words (it is not cleared by reset)"""
    x = {a: 0 for a in range(128)}
    for i, ins in enumerate(INSTRUMENTS):
        e = EXT.get(ins.name, {})
        trim = EXT_TRIM.get(ins.name, e.get('trim', 0))
        x[i] = e.get('vtype', VOICE_TYPE_OF.get(ins.name, 0)) | (trim << 8) | ((e.get('poff', 0) & 255) << 16) | (e.get('prate', 0) << 24)
        det = e.get('det', [0] * 8); sto = e.get('sto', [0] * 8)
        pfa = e.get('pfa', [0] * 8); pfd = e.get('pfd', [0] * 8)      # proportional attack / decay
        half = [(det[k] & 0x3F) | (sto[k] << 8) | (pfa[k] << 14) | (pfd[k] << 15) for k in range(8)]
        for w in range(4):
            x[32 + 8 * i + w] = half[2 * w] | (half[2 * w + 1] << 16)
    return x

# with the extensions unlocked the select sends the voice type: the original noise types
# for instruments without a Rev C one
VOICE_TYPE_OF = {}

# set 4 (the MOD conversion) has its own 12 instruments, fitted to the module's samples
if os.environ.get('AMYCONV_SET') == '4':
    import mod_instruments as _M
    INSTRUMENTS = _M.INSTRUMENTS
    NAMES = _M.NAMES
    VOICE_TYPE = _M.VOICE_TYPE
    EXT = _M.EXT
