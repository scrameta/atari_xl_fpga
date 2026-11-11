"""The engine's chip writes with the Rev C extensions (spec 6.8), unlocked.

Same conventions as engmodel.expected, plus the extension page xram (word -> value)
and 'rt' jobs: a retrigger of voice v, placed by the caller where it falls in time.
jobs: ('inst', v, i) | ('on', v, note, lvl, hm) | ('off', v) | ('rt', v)
"""


def sx(x, bits):
    return x - (1 << bits) if x & (1 << (bits - 1)) else x


def expected_x(jobs, rnows, wnows, ram, xram, hpv8=False):
    ram = dict(ram)
    out = []
    rn = iter(rnows); wn = iter(wnows)
    hpv = 8 if hpv8 else 16
    pfa = [0] * 64; pfd = [0] * 64
    last = {}                                         # voice -> (lvl, hm) of its note
    for job in jobs:
        kind, v = job[0], job[1]
        hb = v * hpv
        vs = ram.get(32 + v, 0)
        if kind == 'inst':
            i = job[2]
            wnow = next(wn)
            xh = xram.get(i, 0)
            out += [(1, xh & 3), (0, 0x10 + v)]
            out += [(1, v), (3, (xh >> 8) & 255), (0, 0x34)]
            for k in range(hpv):
                h = hb + k
                hw = (xram.get(32 + 8 * i + (k >> 1), 0) >> (16 * (k & 1))) & 0xFFFF
                pfa[h] = (hw >> 14) & 1; pfd[h] = (hw >> 15) & 1
                out += [(1, 0), (3, 0), (0, 0x40 + h)]
                out += [(1, h), (3, hw & 63), (0, 0x35)]
                out += [(1, h), (3, (hw >> 8) & 63), (0, 0x36)]
            ram[32 + v] = (i & 15) | (1 << 4) | (wnow << 8) | (((vs >> 24) & 127) << 24)
            continue
        now = next(rn)
        wnow = next(wn)
        inst = vs & 15
        xh = xram.get(inst, 0)
        if kind == 'on':
            note, lvl, hm = job[2] & 127, job[3], job[4] & 31
            last[v] = (lvl, hm)
        elif kind == 'rt':
            note = (vs >> 24) & 127
            lvl, hm = last[v]
        else:
            note = (vs >> 24) & 127
            lvl, hm = 0, 0
        legato = not (vs >> 4) & 1
        age = (now - ((vs >> 8) & 255)) & 255
        ceil = (vs >> 16) & 255
        hdr = ram.get(48 + inst, 0)
        rel = hdr & 255
        d = (hdr >> 16) & 31
        x = lvl - ceil
        n = age
        while x < 8 and not legato and n != 0:
            x += d; n -= 1
        rise = x >= 8
        cnew = lvl if (kind != 'off' and x >= 0) else (lvl - x) & 255
        if kind == 'off':
            for k in range(hpv):
                out += [(1, rel), (2, 0), (3, 0), (0, 0x40 + hb + k)]
            ram[32 + v] = inst | (1 << 4) | (wnow << 8) | (cnew << 16) | (note << 24)
            continue
        if kind == 'on':
            up = note > ((vs >> 24) & 127)
            glide = 0
            if legato:
                glide = (hdr >> 8) & 255 if up else (hdr >> 24) & 255
            f = (ram.get(40, 0) + note * 64) & 0x1FFF
            off = sx((xh >> 16) & 255, 8)
            if off:
                s = min(8191, max(0, f + 16 * off))
                out += [(1, 0), (2, s >> 8), (3, s & 255), (0, 0x08 + v)]
                out += [(1, (xh >> 24) & 255), (2, 0x80 | (f >> 8)), (3, f & 255), (0, 0x08 + v)]
            else:
                out += [(1, glide), (2, f >> 8), (3, f & 255), (0, 0x08 + v)]
        decay = (hdr >> 23) & 1
        for pas in (0, 1) if decay else (0,):
            for k in range(hpv):
                h = hb + k
                wd = ram.get(((inst + 4) & 15) * 16 + k, 0)
                lo, atk, dec, sus = wd & 255, (wd >> 8) & 255, (wd >> 16) & 255, (wd >> 24) & 255
                p = lvl - lo
                inn = k < hm and lo != 255 and p > 0
                if pas == 0:
                    if inn:
                        b = 0x80 if (rise and pfa[h]) else 0
                        out += [(1, atk if rise else 0), (2, b), (3, p), (0, 0x40 + h)]
                    else:
                        out += [(1, rel), (2, 0), (3, 0), (0, 0x40 + h)]
                else:
                    if inn and (not rise or atk == 0):
                        out += [(1, dec), (2, 0x80 if pfd[h] else 0), (3, max(0, p - sus)), (0, 0x40 + h)]
        ram[32 + v] = inst | (0 << 4) | (wnow << 8) | (cnew << 16) | (note << 24)
    return out
