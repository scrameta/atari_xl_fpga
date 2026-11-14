"""SAP (POKEY, AUDCTL $50 style) -> an AMY arrangement for the note engine, 8 voices x 8 harmonics:
  v0 bass (distortion C -> BUZZ)
  v1/v2 POKEY channel 3, v3/v4 channel 4: two voices each, alternating notes, LEAD or PAD by
        whether the channel's notes start quiet and swell (POKEY volume ramps)
  v5 hat (fast noise), v6 snare (slower noise), v7 tom (POKEY's falling-pitch tone fragments,
        played as a note and a legato note gliding down)
Events: (frame, 'on', v, note, level, harmonics), (frame, 'off', v), (frame, 'inst', v, inst),
(frame, 'vib', v, depth): the player's vibrato on voice v (depth in 1/64 semitone, 0 = off)."""
import os, sys, math, collections, bisect
H = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, H); sys.path.insert(0, os.path.join(H, '..', 'asma'))
import sap2notes, instruments as I

NYQ = I.mkinst.clock_nyq(I.CLK)   # derives from the selected AMY clock
BASE = {'BUZZ': 0xC2, 'LEAD': 0xC8, 'PAD': 0xC6, 'PAD2': 0xC6, 'SWELL': 0xCE, 'HAT': 0xD0, 'SNARE': 0xD4, 'CLAP': 0xCC, 'TOM': 0xCC, 'KICK': 0xE8}
DRUM_NOTE = {'HAT': 93, 'SNARE': 92}     # noise voices: hat 1397 Hz (harmonics 3-8: 4.2-11 kHz), snare 1319 Hz (3.9-10.6 kHz)
DRUM_VOICE = {'HAT': 5, 'SNARE': 6, 'TOM': 7}
# Added kicks (the POKEY originals have none), on voice 4: the pads then share voice 3.
#   'snare_mid': halfway between backbeat snares 30-40 frames apart (beats 1 and 3)
#   'bass': at bar positions `pos` (bar of `bar` frames from frame 0) where a bass note starts,
#           while there are drums within a bar or two
KICK_RULES = {'Warhawk.sap': dict(mode='snare_mid'),
              'Draconus.sap': dict(mode='bass', bar=80, pos=(0, 30)),
              'Zybex.sap': dict(mode='bass', bar=96, pos=(0, 48))}
KICK_HI, KICK_LO = 52, 34              # 130 Hz, then the glide down to 46 Hz
# set 1's swelling instruments: frames a note waits after the note-off of the one before it
PAD_LATE = {'SWELL': 1, 'PAD2': 2}
KICKS = True

def code_hz(code):
    return 261.6256 * 2 ** ((code - 64) / 12.0)

def harmonics(code):
    return max(1, min(8, int(NYQ / code_hz(code))))

def level(inst, vol):
    return max(0x40, min(0xF8, int(round(BASE[inst] + 80 * math.log10(max(vol, 1) / 10.0)))))

# The engine holds a note at its sustain level until the off; a POKEY note can fade on long
# after (Axel F's held melody notes: 15 down to 5 in 8 frames, then 1.6 s fading out from
# -10 dB to -24 dB). Once the POKEY volume is this far below the peak, the note is let go
# and the release does the fade (about the sustain level, less 5 dB).
TAIL_DB = {'LEAD': -11, 'BUZZ': -13}

def sounding(inst, vol):
    """frames until the off: the POKEY note's length, or the frame its tail falls below
    the instrument's TAIL_DB (after the peak)"""
    lim = TAIL_DB.get(inst)
    if lim is None:
        return len(vol)
    pk = max(vol); i = vol.index(pk)
    thr = pk * 10 ** (lim / 20.0)
    for k in range(i + 1, len(vol)):
        if vol[k] < thr:
            return max(k, 2)
    return len(vol)

# The newer tunes (arrange_generic) follow the POKEY fade instead: each time the POKEY volume
# has fallen another sustain step below the peak (LEAD 6 dB, BUZZ 8 dB, the instrument's sustain
# on the fundamental), the note is played again legato, one step lower. The engine then jumps
# to the level it was sustaining at and decays one more step, so the note steps down in smooth
# decays (Axel F's long notes: -6, -12 from frame 8, -18 from 55, -24 from 79, the off at 91).
STEP_Q = {i.name: i.sus[0] for i in I.INSTRUMENTS if i.name in ('LEAD', 'BUZZ')}   # 1/4 dB

def fades(inst, vol, lvl):
    """[(frame offset, level)]: legato re-plays of a note following its POKEY fade"""
    q = STEP_Q.get(inst)
    if q is None:
        return []
    pk = max(vol); i = vol.index(pk)
    out = []; j = 1
    for k in range(i + 1, len(vol)):
        dbk = 20 * math.log10(max(vol[k], 0.5) / pk)
        if 4 * dbk <= -(q * j + q // 2) and len(vol) - k >= 4:
            l2 = lvl - q * j
            if l2 < 0x40:
                break
            out.append((k, l2)); j += 1
    return out

# Frames a voice's next note may come after a note's end and still have no off (it plays on
# legato).  Warhawk had 2 when set 1 didn't fit in memory with all its offs; it fits now.
LEGATO_GAP = {}

def note_offs(ev, legato_gap=0, always=()):
    """a note ends: off, unless the voice has already moved on (another note, or an off,
    on that voice after this note's start and no later than its end), or the next note on
    the voice starts within legato_gap frames of the end. Each endmark is
    (end, 'endmark', v, start).  Voices in `always` get their off whatever the gap (the
    swelling voice needs it: its next note comes a frame later, for the dip)."""
    acts = collections.defaultdict(list)
    for e in ev:
        if e[1] in ('on', 'off'):
            acts[e[2]].append(e[0])
    for v in acts:
        acts[v].sort()
    out = []
    for e in ev:
        if e[1] == 'fade':
            a = acts.get(e[2], [])
            i = bisect.bisect_right(a, e[6])
            if not (i < len(a) and a[i] <= e[0]):
                out.append((e[0], 'on') + tuple(e[2:6]))
            continue
        if e[1] != 'endmark':
            out.append(e); continue
        end, v, start = e[0], e[2], e[3]
        a = acts.get(v, [])
        i = bisect.bisect_right(a, start)
        if i < len(a) and a[i] <= end + (0 if v in always else legato_gap):
            continue
        out.append((end, 'off', v))
    return out

SUSTAINS = ('BUZZ', 'LEAD', 'PAD', 'PAD2', 'SWELL')

def close_at_end(ev, frames, vinst):
    """the stream ends at `frames` and starts again with the voices carrying on: a voice still
    holding a note there (its off falls on the loop frame or after, where the stream has
    already ended) would hold it until its next note comes round, however long that is
    (Happy Train's last note on v3: 34 s, every time round).  Let those go in the last
    frame."""
    out = [e for e in ev if e[0] < frames]
    held = {}
    for e in sorted(out, key=lambda e: e[0]):
        if e[1] == 'on': held[e[2]] = True
        elif e[1] in ('off', 'inst'): held[e[2]] = False
    for v in sorted(held):
        if held[v] and vinst.get(v) in SUSTAINS:
            out.append((frames - 1, 'off', v))
    return out

def merge(ns):
    """tonal notes split by a short noise burst on the same channel, same pitch, volume not
    jumping up: one note (the AMY voice doesn't stop for the drum)"""
    out = []
    last = {}
    for n in ns:
        c = n['ch']
        p = last.get(c)
        if n['kind'] != 'noise' and p is not None and p['kind'] == n['kind'] and abs(p['base'] - n['base']) < 0.6 \
                and 0 < n['start'] - (p['start'] + len(p['vol'])) <= 3 and n['vol'][0] <= p['vol'][-1] + 1:
            gap = n['start'] - (p['start'] + len(p['vol']))
            p['vol'] += [p['vol'][-1]] * gap + n['vol']; p['hz'] += [p['hz'][-1]] * gap + n['hz']
            continue
        out.append(n)
        if n['kind'] != 'noise':
            last[c] = n
    return out

def sweeps(ns):
    """runs of short tone fragments on one channel, back to back, each lower and no louder than
    the last: one falling-pitch hit (kind 'sweep', base = first pitch, end = last pitch)"""
    out = []; run = {}
    def close(c):
        r = run.pop(c, None)
        if r is None: return
        if len(r) >= 2:
            out.append(dict(ch=c, start=r[0]['start'], kind='sweep', base=r[0]['base'], end=r[-1]['base'],
                            vol=sum((x['vol'] for x in r), []), hz=sum((x['hz'] for x in r), []), rate=0))
        else:
            out.append(r[0])
    for n in ns:
        c = n['ch']
        if n['kind'] != 'tone':
            close(c) if n['kind'] != 'noise' else None
            out.append(n); continue
        r = run.get(c)
        if r and n['start'] == r[-1]['start'] + len(r[-1]['vol']) and len(n['vol']) <= 4 and len(r[-1]['vol']) <= 4 \
                and r[-1]['base'] - 2.5 < n['base'] < r[-1]['base'] - 0.3 and n['vol'][0] <= r[-1]['vol'][-1] + 1:
            r.append(n); continue
        close(c)
        run[c] = [n]
    for c in list(run): close(c)
    out.sort(key=lambda n: (n['start'], n['ch']))
    return out

def swells(n):
    v = n['vol']
    return len(v) >= 3 and v[0] < max(v[:8]) - 1

# Tunes that don't follow the Gilmore/Hubbard AUDCTL $50 layout (bass on channel 2, leads on
# 3 and 4): every channel can play bass (distortion C), tones and noise.  Voices then go by
# what a note is, not which channel it's on:
#   v0 BUZZ  every distortion-C note (they never overlap in these tunes)
#   v1-v4    tones of POKEY channel 1-4 (each channel keeps its voice: v1, v3 left, v2, v4 right),
#            LEAD, or PAD for a channel whose notes mostly swell
#   v5 HAT, v6 SNARE: noise hits, as before;  v7 TOM: falling tone fragments, as before
GENERIC = {'Happy_Train_to_Kingdom_of.sap', 'Axel_F.sap', 'Bitter_Reality.sap',
           'International_Karate.sap', 'Jet_Set_Willy.sap'}

def arrange(path, song, frames):
    if path.endswith('.mod'):               # set 4: a ProTracker module (mod2amy.py)
        import mod2amy
        return mod2amy.arrange(path, song, frames)
    if os.path.basename(path) in GENERIC:
        return arrange_generic(path, song, frames)
    hdr, fr, ns = sap2notes.notes2(path, song, frames)
    ns = merge(ns)
    # voices by role: v0 bass; leads v1 (POKEY ch3) / v2 (ch4); swelling notes from either channel
    # share the pad pair v3/v4, alternating so each swell starts on a released voice
    rule = KICK_RULES.get(os.path.basename(path)) if KICKS else None
    # the swelling notes' instrument: PAD2 for a slow swell (Draconus: 14 frames to the peak),
    # SWELL for a quick one (Warhawk's lead: 5 frames)
    rise = sorted(n['vol'].index(max(n['vol'])) for n in ns if n['kind'] == 'tone' and swells(n))
    pad = 'SWELL' if rise and rise[len(rise) // 2] < 7 else 'PAD2'
    vinst = {0: 'BUZZ', 1: 'LEAD', 2: 'LEAD', 3: pad, 4: 'KICK' if rule else pad, 5: 'HAT', 6: 'SNARE', 7: 'TOM'}
    role = collections.Counter()
    ev = [(0, 'inst', v, I.NAMES.index(vinst[v])) for v in range(8)]
    pad_turn = 0
    active = {}                                    # POKEY channel -> its AMY voice now
    owner = {}                                     # AMY voice -> the POKEY channel whose note it has
    busy = {}                                      # voice -> frame its note ends
    vib = {}
    last_drum = {}
    stats = collections.Counter()
    def stop(c, t, keep=None):
        # the channel moves on: its last note's voice is let go, if that voice still has
        # that note (the pad voice may have been given to the other channel since)
        o = active.get(c)
        if o is not None and o != keep and owner.get(o) == c and busy.get(o, -1) > t:
            ev.append((t, 'off', o)); busy[o] = t
    for n in ns:
        t = n['start']; L = len(n['vol']); pk = max(n['vol']); c = n['ch']
        if n['kind'] == 'noise':
            d = 'HAT' if n['rate'] >= 20000 else 'SNARE'
            v = DRUM_VOICE[d]; code = DRUM_NOTE[d]
            if last_drum.get(d, -99) >= t - 3:      # Hubbard's snare: a 1-frame click, then the burst
                continue                            # 2 frames later: one hit
            last_drum[d] = t
            ev.append((t, 'on', v, code, level(d, pk), harmonics(code)))
            stats[d] += 1
            continue
        if n['kind'] == 'sweep':                   # tom: the start pitch, then glide to the end
            stop(c, t)
            c0 = 64 + int(round(n['base'])); c1 = 64 + int(round(n['end'])) - 3
            if not (12 <= c1 and c0 <= 120): continue
            ev.append((t, 'on', 7, c0, level('TOM', pk), harmonics(c0)))
            # the glide's target: 3 semitones past the end for a real fall (the tom sound);
            # a semitone for a slight one; none for a pluck that barely moves (Draconus's
            # low plucks fall 0.14 semitones: the same instrument, AUDF + 2 a frame)
            fall = n['base'] - n['end']
            if fall < 0.9: c1 = c0 - 1
            if fall >= 0.3:
                ev.append((t, 'on', 7, c1, level('TOM', pk), harmonics(c0), 'keephm'))
            stats['TOM'] += 1
            continue
        if pk <= 1 and L <= 2:                     # a frame or two at volume 1: the tail end of
            continue                               # the player's envelope, not a note
        code = 64 + int(round(n['base']))
        if code < 12 or code > 120: continue
        if n['kind'] == 'buzz' or c == 1:
            v = 0
        elif swells(n):
            v = 3 + pad_turn
            if not rule: pad_turn ^= 1
            if rule and busy.get(3, -1) > t and owner.get(3) not in (None, c):
                v = 1 if c == 2 else 2             # the pad voice has the other channel's note
        else:
            v = 1 if c == 2 else 2
        stop(c, t, keep=v)
        active[c] = v; owner[v] = c
        t_on = t
        if vinst[v] in PAD_LATE:
            # A swelling note.  Straight after another on its voice: that one is let go at t and
            # this one starts a frame or two later, so it dips and swells again (see
            # instruments.py).  After a long rest: the instrument is selected again first.
            # The engine's clock is 8 bits of 8 ms: 2.048 s after a note-off, and every
            # 2.048 s from then on, it takes the voice for just released and makes the attack
            # a jump (Draconus's pad at frame 4000, 2560 frames after the last one ended, came
            # in at full level).  A select clears that.
            last = busy.get(v)
            if last is not None and last >= t and L > 2 * PAD_LATE[vinst[v]]:
                if last > t:
                    ev.append((t, 'off', v)); busy[v] = t
                t_on = t + PAD_LATE[vinst[v]]
            elif t > 0 and (last is None or t - last >= 90):
                ev.append((t, 'inst', v, I.NAMES.index(vinst[v])))
        ev.append((t_on, 'on', v, code, level(vinst[v], pk), harmonics(code)))
        sw = n.get('swing', 0.0)
        depth = min(31, int(round(sw * 64))) if sw > 0.03 else 0
        if vib.get(v, 0) != depth:
            ev.append((t_on, 'vib', v, depth)); vib[v] = depth
        L = sounding(vinst[v], n['vol'])
        busy[v] = t + L
        ev.append((t + L, 'endmark', v, t_on))
        stats[vinst[v]] += 1
    if rule:
        drums = sorted(e[0] for e in ev if e[1] == 'on' and e[2] in (5, 6))
        kicks = []
        if rule['mode'] == 'snare_mid':
            sn = sorted(e[0] for e in ev if e[1] == 'on' and e[2] == 6)
            kicks = [(a + b) // 2 for a, b in zip(sn, sn[1:]) if 30 <= b - a <= 40]
        else:
            import bisect
            bass = sorted(e[0] for e in ev if e[1] == 'on' and e[2] == 0)
            near = lambda t: (lambda i: (i < len(drums) and drums[i] - t <= 2 * rule['bar']) or
                              (i > 0 and t - drums[i - 1] <= 2 * rule['bar']))(bisect.bisect_left(drums, t))
            kicks = [t for t in bass if t % rule['bar'] in rule['pos'] and near(t)]
        lk = level('KICK', 10)
        for t in kicks:
            ev.append((t, 'on', 4, KICK_HI, lk, 8))
            ev.append((t, 'on', 4, KICK_LO, lk, 8, 'keephm'))
        stats['KICK'] += len(kicks)
    out = note_offs(ev, LEGATO_GAP.get(os.path.basename(path), 0), [v for v in vinst if vinst[v] in PAD_LATE])
    order = {'inst': 0, 'off': 1, 'on': 2, 'vib': 3}
    out = close_at_end(out, frames, vinst)
    out.sort(key=lambda e: (e[0], order[e[1]], e[2]))
    return hdr, out, vinst, stats

# per-tune level offset (1/4 dB): every tune at about the same loudness as the first three
GAIN = {'Happy_Train_to_Kingdom_of.sap': -8, 'Axel_F.sap': -8, 'Bitter_Reality.sap': -16,
        'International_Karate.sap': -3, 'Jet_Set_Willy.sap': 9}
# and per instrument, on top: Axel F's melody (two LEAD channels) forward of its bass
GAIN_INST = {'Axel_F.sap': {'LEAD': 10, 'BUZZ': -4}}

def arrange_generic(path, song, frames):
    g = GAIN.get(os.path.basename(path), 0)
    gi = GAIN_INST.get(os.path.basename(path), {})
    def level(inst, vol):
        return max(0x40, min(0xF8, globals()['level'](inst, vol) + g + gi.get(inst, 0)))
    hdr, fr, ns = sap2notes.notes(path, song, frames)
    ns = sweeps(merge(ns))
    # Two kinds of tone fragment that aren't notes:
    #  * a tone of 1-2 frames just before a noise hit on the same channel is the drum's
    #    attack (Jet Set Willy's 3 kHz tick): the noise hit plays the drum
    #  * a 1-frame lead-in at the pitch of the note that follows straight on (Axel F's
    #    quiet blip before each melody note): the note itself carries it
    nxt = collections.defaultdict(list)
    for n in ns:
        nxt[n['ch']].append(n)
    drop = set()
    for c, lst in nxt.items():
        lst.sort(key=lambda n: n['start'])
        for a, b in zip(lst, lst[1:]):
            if a['kind'] != 'tone':
                continue
            end = a['start'] + len(a['vol'])
            if len(a['vol']) <= 2 and b['kind'] == 'noise' and b['start'] <= end + 1:
                drop.add(id(a))
            elif len(a['vol']) == 1 and b['kind'] == 'tone' and b['start'] == end and \
                    abs(b['base'] - a['base']) < 0.3:
                drop.add(id(a))
    ns = [n for n in ns if id(n) not in drop]
    # PAD only for a slow swell (peak 4 frames or more in), not a quick 2-frame attack
    tones = collections.Counter(); swl = collections.Counter()
    for n in ns:
        if n['kind'] == 'tone':
            tones[n['ch']] += 1; swl[n['ch']] += n['vol'].index(max(n['vol'])) >= 4
    vinst = {0: 'BUZZ', 5: 'HAT', 6: 'SNARE', 7: 'TOM'}
    for c in range(4):
        vinst[1 + c] = 'PAD' if tones[c] and swl[c] > 0.4 * tones[c] else 'LEAD'
    ev = [(0, 'inst', v, I.NAMES.index(vinst[v])) for v in range(8)]
    busy = {}; vib = {}; last_drum = {}
    stats = collections.Counter()
    def stop(v, t):
        if busy.get(v, -1) > t:
            ev.append((t, 'off', v)); busy[v] = t
    for n in ns:
        t = n['start']; L = len(n['vol']); pk = max(n['vol']); c = n['ch']
        if n['kind'] == 'noise':
            d = 'HAT' if n['rate'] >= 20000 else 'SNARE'
            v = DRUM_VOICE[d]; code = DRUM_NOTE[d]
            if last_drum.get(d, -99) >= t - 3:
                continue
            last_drum[d] = t
            ev.append((t, 'on', v, code, level(d, pk), harmonics(code)))
            stats[d] += 1
            continue
        if n['kind'] == 'sweep':
            stop(1 + c, t)
            c0 = 64 + int(round(n['base'])); c1 = 64 + int(round(n['end'])) - 3
            if not (12 <= c1 and c0 <= 120): continue
            ev.append((t, 'on', 7, c0, level('TOM', pk), harmonics(c0)))
            ev.append((t, 'on', 7, c1, level('TOM', pk), harmonics(c0), 'keephm'))
            stats['TOM'] += 1
            continue
        code = 64 + int(round(n['base']))
        if code < 12 or code > 120: continue
        v = 0 if n['kind'] == 'buzz' else 1 + c
        if v: stop(0, t) if False else None
        lv = level(vinst[v], pk); ev.append((t, 'on', v, code, lv, harmonics(code)))
        dev = [abs(sap2notes.semis(h) - n['base']) for h in n['hz']]
        depth = min(31, int(round(max(dev) * 64))) if 0.02 < max(dev) < 0.6 else 0
        if vib.get(v, 0) != depth:
            ev.append((t, 'vib', v, depth)); vib[v] = depth
        L = len(n['vol'])
        for k, l2 in fades(vinst[v], n['vol'], lv):
            ev.append((t + k, 'fade', v, code, l2, harmonics(code), t))
        busy[v] = t + L
        ev.append((t + L, 'endmark', v, t))
        stats[vinst[v]] += 1
    out = note_offs(ev, LEGATO_GAP.get(os.path.basename(path), 0))
    order = {'inst': 0, 'off': 1, 'on': 2, 'vib': 3}
    out = close_at_end(out, frames, vinst)
    out.sort(key=lambda e: (e[0], order[e[1]], e[2]))
    return hdr, out, vinst, stats

if __name__ == '__main__':
    hdr, ev, role, st = arrange(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]))
    print(hdr['NAME'][0], 'roles', role, dict(st), 'events', collections.Counter(e[1] for e in ev))
    for e in ev[:40]: print(e)
