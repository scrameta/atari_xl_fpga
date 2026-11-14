"""AMY pitch/harmonic tables at the configured clock (the instruments are in the copper note
engine: mkconv.py writes their engine words for copgen.py).

No SAP files, py65, or ca65 needed: this module only generates the static
front section of convdata.inc from source instrument definitions.
"""
import math
import instruments as I


def tables():
    L = []
    f = [(I.FREQ0 + n * 64) & 0x1FFF for n in range(128)]
    L.append('ftab_lo:')
    L += ['        .byte ' + ','.join('$%02X' % (x & 255) for x in f[i:i + 16]) for i in range(0, 128, 16)]
    L.append('ftab_hi:')
    L += ['        .byte ' + ','.join('$%02X' % (x >> 8) for x in f[i:i + 16]) for i in range(0, 128, 16)]
    L.append('hmtab:')
    nyq = I.mkinst.clock_nyq(I.CLK)
    def harmonics(code):
        hz = 261.6256 * 2 ** ((code - 64) / 12.0)
        return max(1, min(8, int(nyq / hz)))
    L += ['        .byte ' + ','.join(str(harmonics(n)) for n in range(i, i + 16)) for i in range(0, 128, 16)]
    L.append('; AMY voice types (noise drums) and the Noise RAM image, for chip_init')
    L.append('vtypes: .byte ' + ','.join(map(str, I.VOICE_TYPE)))
    nz = I.noise_image()
    L.append('noiseram:')
    L += ['        .byte ' + ','.join(map(str, nz[i:i + 16])) for i in range(0, 64, 16)]
    L.append('; vibrato: lfo[phase * 32 + depth], signed, in 1/64 semitone')
    L.append('lfo:')
    lfo = [0, 1, 1, 0, 0, -1, -1, 0]
    for phase in range(8):
        L.append('        .byte ' + ','.join('$%02X' % (int(round(d * lfo[phase])) & 255) for d in range(32)))
    return L
