#!/usr/bin/env python3
"""modplay.py - ProTracker MOD reader and tick-level player (state only, no mixing).

play(path) -> (mod, ticks): ticks is a list of (time_s, [chan state x4]) where a chan
state is a dict: smp (1-31, 0 = none), period (after arpeggio/vibrato), vol (0-64, after
tremolo), trig (True on the tick a note starts), off (sample offset in bytes at trigger),
pos (sample position in bytes at the start of the tick), alive (the sample still plays).
Effects: 0 1 2 3 4 5 6 7 9 A B C D F, E1 E2 E9 EA EB EC ED EE; PAL clock 3546895 Hz."""
import struct

PAL = 3546895
SINE = [0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
        255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24]
PERIODS = [856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
           428, 404, 381, 360, 340, 320, 302, 285, 269, 254, 240, 226,
           214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113]


class Mod:
    def __init__(self, path):
        d = open(path, 'rb').read()
        self.title = d[:20].split(b'\0')[0].decode('latin1')
        self.samples = [None]
        o = 20 + 31 * 30 + 2 + 128 + 4
        self.length = d[950]
        self.order = list(d[952:952 + 128])
        npat = max(self.order[:128]) + 1
        self.patterns = []
        for p in range(npat):
            rows = []
            for r in range(64):
                row = []
                for c in range(4):
                    b = d[1084 + p * 1024 + r * 16 + c * 4:][:4]
                    row.append(((b[0] & 0xF0) | (b[2] >> 4), ((b[0] & 15) << 8) | b[1], b[2] & 15, b[3]))
                rows.append(row)
            self.patterns.append(rows)
        o = 1084 + npat * 1024
        for i in range(31):
            h = 20 + 30 * i
            name = d[h:h + 22].split(b'\0')[0].decode('latin1')
            ln, ft, vol, ls, ll = struct.unpack('>HBBHH', d[h + 22:h + 30])
            data = d[o:o + ln * 2]; o += ln * 2
            pcm = [x - 256 if x > 127 else x for x in data]
            ft &= 15
            self.samples.append(dict(name=name, len=ln * 2, ft=ft - 16 if ft > 7 else ft, vol=vol,
                                     ls=ls * 2, ll=ll * 2, loop=ll > 1, pcm=pcm))


def play(path, max_s=None):
    m = Mod(path)
    speed, bpm = 6, 125
    ch = [dict(smp=0, period=0, base=0, vol=0, pos=0.0, alive=False, porta_to=0, porta_spd=0,
               vib_pos=0, vib_spd=0, vib_dep=0, trem_pos=0, trem_spd=0, trem_dep=0, last_off=0,
               vslide=0, eff=(0, 0)) for _ in range(4)]
    ticks = []
    t = 0.0
    oi, row = 0, 0
    seen = set()
    while oi < m.length:
        if (oi, row) in seen:
            break                       # the song loops: stop
        seen.add((oi, row))
        pat = m.patterns[m.order[oi]]
        brk = None
        delay = 0
        for c in range(4):
            s, per, e, x = pat[row][c]
            st = ch[c]
            st['trig'] = False; st['off'] = 0
            st['eff'] = (e, x)
            if s:
                st['smp'] = s; st['vol'] = m.samples[s]['vol']
            if per and e not in (3, 5) and not (e == 0xE and x >> 4 == 0xD):
                st['base'] = per; st['period'] = per; st['pos'] = 0.0
                st['trig'] = True; st['alive'] = st['smp'] > 0 and m.samples[st['smp']]['len'] > 2
                st['vib_pos'] = 0
            if per and e in (3, 5):
                st['porta_to'] = per
            if e == 3 and x: st['porta_spd'] = x
            if e == 4:
                if x >> 4: st['vib_spd'] = x >> 4
                if x & 15: st['vib_dep'] = x & 15
            if e == 7:
                if x >> 4: st['trem_spd'] = x >> 4
                if x & 15: st['trem_dep'] = x & 15
            if e == 9:
                if x: st['last_off'] = x * 256
                if st['trig']:
                    st['pos'] = float(st['last_off']); st['off'] = st['last_off']
                    if st['pos'] >= m.samples[st['smp']]['len']: st['alive'] = False
            if e == 0xC: st['vol'] = min(64, x)
            if e == 0xB: brk = (x, 0)
            if e == 0xD: brk = (oi + 1, (x >> 4) * 10 + (x & 15))
            if e == 0xF:
                if x == 0: pass
                elif x < 32: speed = x
                else: bpm = x
            if e == 0xE:
                sub, y = x >> 4, x & 15
                if sub == 1: st['base'] = max(113, st['base'] - y); st['period'] = st['base']
                if sub == 2: st['base'] = min(856, st['base'] + y); st['period'] = st['base']
                if sub == 0xA: st['vol'] = min(64, st['vol'] + y)
                if sub == 0xB: st['vol'] = max(0, st['vol'] - y)
                if sub == 0xE: delay = y
        for rep in range(1 + delay):
            for tk in range(speed):
                dt = 2.5 / bpm
                states = []
                for c in range(4):
                    st = ch[c]
                    s, per, e, x = pat[row][c]
                    per_out = st['base']; vol_out = st['vol']
                    if tk and rep == 0 or rep:
                        if e == 1: st['base'] = max(113, st['base'] - x)
                        if e == 2: st['base'] = min(856, st['base'] + x)
                        if e in (3, 5) and st['porta_to']:
                            if st['base'] < st['porta_to']: st['base'] = min(st['porta_to'], st['base'] + st['porta_spd'])
                            else: st['base'] = max(st['porta_to'], st['base'] - st['porta_spd'])
                        if e in (4, 6): st['vib_pos'] = (st['vib_pos'] + st['vib_spd']) & 63
                        if e == 7: st['trem_pos'] = (st['trem_pos'] + st['trem_spd']) & 63
                        if e in (5, 6, 0xA):
                            if x >> 4: st['vol'] = min(64, st['vol'] + (x >> 4))
                            else: st['vol'] = max(0, st['vol'] - (x & 15))
                        if e == 0xE and x >> 4 == 0xC and tk == (x & 15): st['vol'] = 0
                        if e == 0xE and x >> 4 == 9 and (x & 15) and tk % (x & 15) == 0:
                            st['pos'] = 0.0; st['trig'] = True; st['alive'] = True
                    if e == 0xE and x >> 4 == 0xD and tk == (x & 15) and per and rep == 0:
                        st['base'] = per; st['pos'] = 0.0; st['trig'] = True; st['alive'] = True
                    per_out = st['base']; vol_out = st['vol']
                    if e in (4, 6):
                        per_out += (SINE[st['vib_pos'] & 31] * st['vib_dep'] >> 7) * (-1 if st['vib_pos'] & 32 else 1)
                    if e == 7:
                        vol_out = max(0, min(64, vol_out + (SINE[st['trem_pos'] & 31] * st['trem_dep'] >> 6) *
                                             (-1 if st['trem_pos'] & 32 else 1)))
                    if e == 0 and x:
                        a = (0, x >> 4, x & 15)[tk % 3]
                        if a:
                            i = min(range(36), key=lambda k: abs(PERIODS[k] - per_out))
                            per_out = PERIODS[min(35, i + a)]
                    smp = m.samples[st['smp']] if st['smp'] else None
                    states.append(dict(smp=st['smp'], period=per_out, vol=vol_out, trig=st['trig'] and tk == 0 or
                                       (st['trig'] and e == 0xE and (x >> 4) in (9, 0xD)),
                                       off=st['off'] if tk == 0 else 0, pos=st['pos'],
                                       alive=st['alive'], row=(oi, row), eff=(e, x), base=st['base'],
                                       vib=st['vib_dep'] if e in (4, 6) else 0))
                    if e == 0xE and (x >> 4) in (9, 0xD):
                        st['trig'] = False
                    # advance the sample position
                    if st['alive'] and smp and per_out:
                        st['pos'] += PAL / per_out * dt
                        if smp['loop']:
                            end = smp['ls'] + smp['ll']
                            while st['pos'] >= end:
                                st['pos'] -= smp['ll']
                        elif st['pos'] >= smp['len']:
                            st['alive'] = False
                ticks.append((t, states))
                for c in range(4):
                    ch[c]['trig'] = False
                t += dt
            if max_s and t > max_s:
                return m, ticks
        if brk is not None:
            oi, row = brk
            if oi >= m.length: break
        else:
            row += 1
            if row == 64:
                row = 0; oi += 1
    return m, ticks


if __name__ == '__main__':
    import sys, collections
    m, ticks = play(sys.argv[1])
    print(m.title, 'ticks', len(ticks), 'length %.1f s' % (ticks[-1][0]))
    trig = collections.Counter()
    for t, sts in ticks:
        for c, s in enumerate(sts):
            if s['trig']: trig[s['smp']] += 1
    print('note starts per sample', sorted(trig.items()))
