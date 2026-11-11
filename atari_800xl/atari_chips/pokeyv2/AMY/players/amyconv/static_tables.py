"""Engine instrument RAM and AMY pitch/harmonic tables at the configured clock.

No SAP files, py65, or ca65 needed: this module only generates the static
front section of convdata.inc from source instrument definitions.
"""
import math
import instruments as I


def tables():
    ram = I.ram_image(I.FREQ0)
    L = ['; engine RAM: runs of (first word, count, count x 4 bytes), 0 ends', 'engram:']
    ws = sorted(w for w in ram if w >= 40)
    runs = []
    for w in ws:
        if runs and runs[-1][0] + len(runs[-1][1]) == w and len(runs[-1][1]) < 63:
            runs[-1][1].append(ram[w])
        else:
            runs.append((w, [ram[w]]))
    for w, vals in runs:
        L.append('        .byte %d, %d' % (w, len(vals)))
        for i in range(0, len(vals), 4):
            L.append('        .byte ' + ', '.join('$%02X,$%02X,$%02X,$%02X' %
                     (v & 255, v >> 8 & 255, v >> 16 & 255, v >> 24 & 255) for v in vals[i:i + 4]))
    L.append('        .byte 0')
    x = I.ext_image()
    L.append('; Rev C extension page (XPAGE): all 128 words, 4 bytes each')
    L.append('extram:')
    for a in range(0, 128, 4):
        L.append('        .byte ' + ', '.join('$%02X,$%02X,$%02X,$%02X' % (v & 255, v >> 8 & 255, v >> 16 & 255, v >> 24 & 255) for v in (x[a + i] for i in range(4))))
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
