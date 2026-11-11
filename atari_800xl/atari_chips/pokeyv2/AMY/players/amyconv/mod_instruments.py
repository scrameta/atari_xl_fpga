"""AMY instruments for the MOD conversion (set 4: DJ Metune's Axel F), fitted to the module's
samples (mod/harm.py measures each tonal sample's harmonics over time). 12 instruments, the most
the engine RAM holds (headers 48-59, harmonic words 64-255; extension page 0-11 and 32-127).
Levels are dB per harmonic at the peak; dec dB/s and sus dB below the peak per harmonic."""
from instruments import Inst, PROP

K8 = range(8)
INSTRUMENTS = [
    # synth bass (samples 3 5 7 8 9 13-16): strong fundamental, odd harmonics, the top falling
    # away in ~100 ms to a darker sustain
    Inst('BASS', [0, -13, -11, -13, -26, -14, -20, -16],
         dec=[45, 60, 80, 90, 120, 140, 160, 180], sus=[-6, -8, -9, -10, -12, -14, -15, -16], rel=220),
    # the lead (sample 24): an analogue brass patch, fundamental-heavy; Rev C adds its chorus
    # (detune and a little diffusion). The sample is at full level within 20 ms, like the pad
    # and organ samples: 2000 dB/s. (300 dB/s is 0.15 s from silence: each phrase's first note
    # came in late. The pad at 90 and the organ at 120 took 0.5 s.)
    Inst('LEAD', [0, -14, -15, -15, -19, -17, -19, -20], atk=[2000] * 8, rel=160),
    # bell / chip (samples 11 28, and the 236-byte tick 4): a sustained fundamental with a
    # bright ping on harmonics 6 and 8 that dies in a few tens of ms
    Inst('BELL', [0, -20, None, None, -32, -6, None, -6], dec=[25, 60, 0, 0, 500, 700, 0, 700],
         sus=[-4, -8, None, None, -40, -50, None, -50], rel=200),
    # pluck (sample 25, and the sampled phrases 29 30, the riser 1): soft square-ish, decaying
    Inst('PLUCK', [0, -10, -12, -16, -17, -20, -23, -23], dec=[60, 90, 110, 130, 150, 170, 190, 210],
         sus=[-10, -20, -28, -24, -24, -32, -30, -30], rel=180),
    # the pad (sample 26) is a sampled sus4 chord: at the pitch of its long note its partials
    # are Eb4 F4 Bb4 Eb5 F5 Bb5 (312 352 469 625 705 939 Hz; F4 the strongest, no Bb3 under
    # them). Two voices, each an octave under its note: PAD on Eb (harmonics 2 3 4 6 = Eb Bb Eb
    # Bb) and PADF on F (2 4 8 = F F F), 3 dB louder. (One voice on Bb gave Bb F Bb: no Eb, and
    # the F an octave up.)
    Inst('PAD', [None, 0, -3, -6, None, -6, None, None], atk=[2000] * 8, rel=90),
    # organ / flute (sample 27): octave-heavy, soft attack
    Inst('ORGAN', [-12, 0, None, -9, -12, -13, None, -15], atk=[2000] * 8, rel=100),
    # chord stab (samples 21 22 23 2: major triads). Harmonics 4 5 6 8 of a voice are a major
    # triad in close position with its octave (just intonation): root, third, fifth, root.
    # mod2amy.py plays up to three such voices a stab: two octaves under the root (the triad
    # where the samples have it: F4 A4 C5 for sample 21), one octave under (the same an
    # octave up) and at the root (two octaves up), at the levels each sample has them.
    # (It was one voice an octave under the root with harmonics 2-6 and 8: root, fifth, root,
    # third: the third only an octave up, and nothing above 4 x the root.)
    Inst('STAB', [None, None, None, -1, -3, 0, None, -6], dec=[0, 0, 0, 90, 100, 110, 0, 130],
         sus=[None, None, None, -14, -15, -16, None, -18], rel=220),
    # kick (sample 18): 185 Hz gliding to 65 Hz, a beater click on harmonics 5-8 (Rev C:
    # proportional pitch drop, the click detuned and diffused); also the low body inside the
    # snare (133 Hz) and clap (69 Hz) samples
    # The sample is level for 60 ms and then falls 600 dB/s: a slow decay, a note-off after
    # 3 frames, and the release.
    # Harmonics 2-4 are 8 dB lower than they were: the sample is nearly a pure sweep (its
    # 250-1000 Hz band is 35 dB under the low band after the first 10 ms).
    Inst('KICK', [0, -18, -28, -36, -12, -12, -12, -6], dec=[40, 110, 220, 350, 1800, 1800, 1800, 1800],
         rel=600, glide=(0, 0x80 | (3 << 5) | (32 - 30))),
    # snare (sample 19): broadband noise, 0.25 s. The sample's noise is 5 dB up for its first
    # 10 ms (the crack), level to 80 ms and then falls about 125 dB/s: a fast decay to a sustain 5 dB
    # down, a note-off after 4 frames, and the release (110 dB/s)
    Inst('SNARE', [None, None, 0, 0, -2, -6, -9, -12],
         dec=[0, 0] + [300] * 6, sus=[None, None] + [-5, -5, -5, -6, -6, -7], rel=110),
    # hat (the loops 6 10 20 31): noise bands 4-11 kHz. Each hit in the loops is level for
    # about 50 ms and then falls 400 dB/s: held to a note-off where the plateau ends, and the
    # release (decaying from the start, it was over 45 ms too soon)
    Inst('HAT', [None, None] + [-1.0 * (k - 3) for k in range(3, 9)], rel=400),
    # noise: held until the off. The gated white noise (sample 17) and the riser (sample 1),
    # whose level follows the samples' in steps, and the clap (sample 12: mid noise, level for
    # 50 ms, then 300-400 dB/s: a note-off after 2 frames)
    Inst('NOISE', [None, None, -2, 0, 0, -2, -5, -8], rel=400),
    # the pad's F voice (see PAD)
    Inst('PADF', [None, 0, None, -7, None, None, None, -11], atk=[2000] * 8, rel=90),
]
NAMES = [i.name for i in INSTRUMENTS]

# voices: v0 bass, v1-v3 and v7 the tonal pool, v4 snare/clap (noise generator 1), v5 hat/noise
# (generator 0), v6 kick: the kick and bass on v0 and v6, the voices in both output channels
VOICE_TYPE = [0, 0, 0, 0, 2, 1, 0, 0]

EXT = {
    'LEAD':  dict(det=[0, 1, -1, 2, -2, 3, -3, 4], sto=[0, 1, 2, 3, 4, 5, 6, 8]),
    # (a little detune only: the two pad voices are a chord)
    'PAD':   dict(det=[0, 1, -1, 2, 0, -3, 0, 0], sto=[4, 8, 10, 12, 14, 16, 18, 20]),
    'PADF':  dict(det=[0, -1, 0, 2, 0, 0, 0, -3], sto=[4, 8, 10, 12, 14, 16, 18, 20]),
    'STAB':  dict(det=[0, 0, 0, -1, 1, -1, 0, 2], sto=[0, 0, 0, 2, 4, 4, 0, 6]),
    'BELL':  dict(det=[0, 0, 0, 0, 0, 3, 0, -5]),
    'HAT':   dict(vtype=3, trim=16),
    'SNARE': dict(vtype=3, trim=16),
    'NOISE': dict(vtype=3, trim=16),
    'KICK':  dict(poff=4 * 18, prate=PROP(3, 8), det=[0, 0, 0, 0, 21, -17, 9, 0], sto=[0, 0, 0, 0, 48, 48, 48, 63]),
}
