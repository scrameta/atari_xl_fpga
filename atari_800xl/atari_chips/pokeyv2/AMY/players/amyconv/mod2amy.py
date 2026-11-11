"""ProTracker MOD -> an AMY arrangement for the note engine (set 4), in arrange.py's event format:
(frame, 'on', v, note, level, harmonics[, 'keephm']), (frame, 'off', v), (frame, 'inst', v, inst),
(frame, 'vib', v, depth).

The module's 4 channels play sampled sounds; mod/samples.py says what each sample is. A tonal
sample is one note; chord-stab, phrase and rhythm-loop samples carry several notes or hits,
placed where the channel's playback position passes them. Voices:
  v0 bass (channel 2's bass samples), v1-v3 and v7 a pool for the other tonal notes
  (instrument switched per note), v4 snare, clap and the noise riser (noise), v5 hats and gated
  noise (noise),
  v6 kick and the snare's low body (v0 and v6 are the two voices in both output channels).
Times: the module runs at 116 BPM (21.55 ms ticks); each tick goes to the nearest 50 Hz frame,
counted from the start of its pattern, so a repeated pattern gives the same frames (and the
stream compressor finds the repeats)."""
import os, sys, math, collections
H = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(H, 'mod'))
import modplay, samples
import instruments as I

FRAME = 0.02
POOL = (1, 2, 3, 7)
FIXED = {'KICK': 6, 'HAT': 5, 'NOISE': 5, 'SNARE': 4, 'CLAP': 4, 'SWELL': 4}
DRUM_NOTE = {'SNARE': 90, 'CLAP': 80, 'HAT': 93, 'NOISE': 84}
DRUM_HOLD = {'KICK': 3, 'SNARE': 4, 'CLAP': 2}     # frames to the note-off (mod_instruments.py)
# A stab is up to three STAB voices (mod_instruments.py): 24 and 12 semitones under the root
# and at the root, at these levels (dB against the hit) for each stab sample. 21 (F) and 2 (Eb)
# are root position, strongest at the bottom; 22 (Eb, first inversion) and 23 (Bb, second
# inversion) sit higher. The upper two are dropped when the pool has no voice free.
STAB_VOICES = {21: (0, -5, -12), 2: (0, -8, -14), 22: (0, -3, -8), 23: (-3, 0, -6)}
INST_OF = {'CLAP': 'NOISE'}        # the clap plays on the noise instrument (12 is all the engine holds)
PAD_VOICES = (('PAD', -7, -12), ('PADF', -5, 0))    # instrument, semitones, level (1/4 dB): see PAD
SWELL_FLOOR = 0x58                 # a noise swell below this level is not played
KICK_HI, KICK_LO = 58, 40          # 185 Hz gliding to 65 Hz (Rev C: the pitch drop from +18 st)
KICK_HOLD = DRUM_HOLD['KICK']      # the kick sample is level for 60 ms, then falls 600 dB/s (the
                                   # release); so are the snare and clap bodies
# the snare and clap samples carry a low body (133 Hz, 69 Hz): a kick-voice hit under the noise
BODY = {'SNARE': (52, 0.5), 'CLAP': (40, -2.5)}      # note, level offset (dB) against the noise hit
# level (1/4 dB) for a hit at 0 dB re full scale at channel volume 64; set by the calibration
BASEL = {'BASS': 249, 'LEAD': 259, 'BELL': 279, 'PLUCK': 257, 'PAD': 250, 'PADF': 250, 'ORGAN': 253, 'STAB': 256, 'KICK': 250, 'SNARE': 229, 'CLAP': 234, 'HAT': 266, 'NOISE': 255}
INIT = ['BASS', 'LEAD', 'LEAD', 'LEAD', 'SNARE', 'HAT', 'KICK', 'BELL']
NYQ = I.mkinst.clock_nyq(I.CLK)


def harmonics(code):
    return max(1, min(8, int(NYQ / (261.6256 * 2 ** ((code - 64) / 12.0)))))


def step_q(inst):
    """the sustain depth (1/4 dB) of the instrument's first sounding harmonic: a fade steps by it"""
    ins = I.INSTRUMENTS[I.NAMES.index(inst)]
    if not ins.hasdec:
        return None
    for k in range(8):
        if ins.lvl[k] != 255 and ins.sus[k] != 255:
            return ins.sus[k]
    return None


def lev(inst, db, vol):
    if vol <= 0:
        return None
    return BASEL[inst] + int(round(4 * db + 80 * math.log10(vol / 64.0)))


def clamp(l):
    return max(0x40, min(0xF8, l))


class Timeline:
    """tick -> frame, per pattern (order position)"""
    def __init__(self, ticks):
        self.t0 = {}
        for t, sts in ticks:
            oi = sts[0]['row'][0]
            self.t0.setdefault(oi, t)
        self.ticks = ticks

    def frame(self, t, oi):
        t0 = self.t0[oi]
        return int(round(t0 / FRAME)) + int(round((t - t0) / FRAME))


def sources(ticks):
    """per channel: runs of ticks playing one triggered sample"""
    out = []
    for c in range(4):
        cur = None
        for i, (t, sts) in enumerate(ticks):
            s = sts[c]
            if s['trig'] and s['smp']:
                if cur: out.append(cur)
                cur = dict(ch=c, smp=s['smp'], i0=i, ticks=[])
            if cur is not None:
                if not s['alive'] or s['smp'] != cur['smp']:
                    out.append(cur); cur = None; continue
                cur['ticks'].append(i)
        if cur: out.append(cur)
    return out


def crossings(m, ticks, src, byte):
    """time (and tick index) when the source's playback passes sample byte `byte`, or None"""
    sm = m.samples[src['smp']]
    for j, i in enumerate(src['ticks']):
        t, sts = ticks[i]
        s = sts[src['ch']]
        t1 = ticks[i + 1][0] if i + 1 < len(ticks) else t + 0.0216
        rate = modplay.PAL / max(1, s['period'])
        p = s['pos']; adv = rate * (t1 - t)
        if s['trig'] and j == 0 and s['off'] == 0 and byte == 0:
            return t, i
        segs = []
        if sm['loop']:
            end = sm['ls'] + sm['ll']
            a = p; left = adv
            while left > 0:
                n = min(left, end - a)
                segs.append((a, a + n, t + (adv - left) / rate))
                left -= n; a = sm['ls']
                if len(segs) > 50: break
        else:
            segs.append((p, p + adv, t))
        for a, b, ts in segs:
            if a <= byte < b:
                return ts + (byte - a) / rate, i
    return None


def crossings_all(m, ticks, src, hits, under_way=None):
    """every pass of each hit (loops repeat their hits): [(t, tick index, hit, rate)].
    A sample offset (9xx) can start the playback inside a hit: 97 of the hat loops' 362
    triggers, 34 of the 162 stabs (26 of them played nothing at all), 56 of the 70 riffs.
    That hit sounds from the trigger on, as far as it still has to go: under_way(hit, pos)
    gives it as a hit from pos (with the level it has there), or None when it is nearly over."""
    sm = m.samples[src['smp']]
    out = []
    for j, i in enumerate(src['ticks']):
        t, sts = ticks[i]
        s = sts[src['ch']]
        t1 = ticks[i + 1][0] if i + 1 < len(ticks) else t + 0.0216
        rate = modplay.PAL / max(1, s['period'])
        p = s['pos']; adv = rate * (t1 - t)
        if j == 0 and under_way is not None:
            for h in hits:
                if h[0] < p < h[1]:
                    h2 = under_way(h, p)
                    if h2 is not None:
                        out.append((t, i, h2, rate))
        segs = []
        if sm['loop']:
            end = sm['ls'] + sm['ll']
            a = p; left = adv
            while left > 1e-9:
                n = min(left, end - a)
                if n <= 0: a = sm['ls']; continue
                segs.append((a, a + n, t + (adv - left) / rate))
                left -= n; a = sm['ls'] if a + n >= end else a + n
                if len(segs) > 50: break
        else:
            segs.append((p, p + adv, t))
        for a, b, ts in segs:
            for h in hits:
                if a <= h[0] < b or (j == 0 and h[0] < a and h[0] == 0 and s['off'] and False):
                    out.append((ts + (h[0] - a) / rate, i, h, rate))
    return out


def arrange(path, song=0, frames=None):
    if not os.path.exists(path):
        path = os.path.join(H, 'mod', os.path.basename(path))
    m, ticks = modplay.play(path)
    S = samples.analyse(m)
    TL = Timeline(ticks)

    def fr(t, i):
        return TL.frame(t, ticks[i][1][0]['row'][0])

    notes = []          # dict(f0, f1, inst, code, lvl, steps [(f, code, lvl)], vib [(f, depth)], cls, ch)
    swells = []         # (frame, level, note) of every noise-swell channel, tick by tick
    for src in sources(ticks):
        d = S.get(src['smp'])
        if d is None or not src['ticks']:
            continue
        c = src['ch']
        i_end = src['ticks'][-1]
        t_end = ticks[i_end + 1][0] if i_end + 1 < len(ticks) else ticks[i_end][0] + 0.0216
        inst = d['inst']
        if d['kind'] in ('tone', 'swell'):
            st = d['hits'][0][2]; hdb = d['hits'][0][3]
            swell = d['kind'] == 'swell'
            smlen = m.samples[src['smp']]['len']
            s0 = ticks[src['i0']][1][c]
            if s0['off'] > m.samples[src['smp']]['len'] * 0.8 and not m.samples[src['smp']]['loop']:
                continue
            q = step_q(inst)
            f0 = fr(ticks[src['i0']][0], src['i0'])
            code0 = None; lvl0 = None; steps = []; vib = []; j = 0; last_l = None; last_code = None
            f1 = fr(t_end, i_end)
            depth_prev = 0
            for i in src['ticks']:
                t, sts = ticks[i]; s = sts[c]; f = fr(t, i)
                code = int(round(64 + st + 12 * math.log2(160.0 / max(113, s['base']))))
                if swell:
                    # the riser: the sample's own level where the playback is (40 ms around),
                    # and a note that climbs with the slide and through the sample (the noise
                    # bands of the Rev B voice rise with it; white noise has no pitch)
                    k = int(min(s['pos'], smlen - 1) // d['hop'])
                    hdb = float(d['env'][max(0, k - 5):k + 6].max())
                    code = min(96, 76 + int(round(12 * math.log2(202.0 / max(113, s['base'])) + 8 * min(1.0, s['pos'] / smlen))))
                l = lev(inst, hdb, s['vol'])
                if swell:
                    swells.append((f, l if l is not None else 0, code))
                    continue
                if l is None:
                    f1 = f; break
                if code0 is None:
                    code0, lvl0 = code, l; last_l = l; last_code = code
                else:
                    if code != last_code:
                        steps.append((f, code, last_l)); last_code = code
                    if q:       # decaying instrument: step down by its sustain depth
                        while l <= lvl0 - q * (j + 1) - q // 2 and lvl0 - q * (j + 1) >= 0x40:
                            j += 1; last_l = lvl0 - q * j
                            steps.append((f, last_code, last_l))
                    elif abs(l - last_l) >= 6:
                        last_l = l; steps.append((f, last_code, l))
                dv = s['vib']
                depth = 0
                if dv:
                    depth = min(31, int(round(64 * 12 * math.log2((s['base'] + 2 * dv) / s['base']))))
                if depth != depth_prev:
                    vib.append((f, depth)); depth_prev = depth
            if code0 is None:
                continue                    # (a swell: collected above)
            if not m.samples[src['smp']]['loop']:
                rate = modplay.PAL / max(113, ticks[src['i0']][1][c]['period'])
                f1 = min(f1, f0 + max(1, int(round((m.samples[src['smp']]['len'] - s0['off']) / rate / FRAME))))
            for pinst, dc, dl in (PAD_VOICES if inst == 'PAD' else ((inst, 0, 0),)):
                notes.append(dict(f0=f0, f1=max(f1, f0 + 1), inst=pinst, code=code0 + dc, lvl=lvl0 + dl,
                                  steps=[(f, cd + dc, l + dl) for f, cd, l in steps], vib=vib,
                                  cls='bass' if inst == 'BASS' and c == 1 else ('pool' if inst not in FIXED else inst),
                                  ch=c, grp=inst))
        elif d['kind'] == 'drum':
            s0 = ticks[src['i0']][1][c]
            if s0['off'] > 256:
                continue
            l = lev(inst, d['hits'][0][3], s0['vol'])
            if l is None: continue
            f0 = fr(ticks[src['i0']][0], src['i0'])
            rate = modplay.PAL / max(113, s0['period'])
            f1 = min(fr(t_end, i_end), f0 + max(1, int(round(d['hits'][0][1] / rate / FRAME))))
            f1 = min(f1, f0 + DRUM_HOLD[inst])
            notes.append(dict(f0=f0, f1=max(f1, f0 + 1), inst=INST_OF.get(inst, inst), code=KICK_LO if inst == 'KICK' else DRUM_NOTE[inst],
                              lvl=l, steps=[], vib=[], cls=inst, ch=c, grp=inst))
            if inst in BODY:
                lo, off = BODY[inst]
                notes.append(dict(f0=f0, f1=f0 + KICK_HOLD, inst='KICK', code=lo, lvl=l + int(round(4 * off)) + BASEL['KICK'] - BASEL[inst],
                                  steps=[], vib=[], cls='KICK', ch=c, grp=inst))
        else:       # stab, phrase, loop: the hits the playback passes
            hop = d['hop']; env = d['env']; hold = d.get('hold', {})
            def under_way(h, p, kind=d['kind'], env=env, hop=hop, hold=hold):
                if kind == 'phrase':        # a held note of the riff: what is left of it
                    if h[1] - p < 0.06 * samples.R160: return None
                    return (p, h[1], h[2], h[3] - min(12.0, 40.0 * (p - h[0]) / samples.R160))
                k = int(p // hop)           # a stab or a hat: the level it still has
                lv = float(env[k:k + 6].max())
                if lv < h[3] - 12: return None
                hold[p] = max(hold.get(h[0], h[1]), p + hop)
                return (p, h[1], h[2], lv)
            for t, i, h, rate in crossings_all(m, ticks, src, d['hits'], under_way):
                s = ticks[i][1][c]
                l = lev(inst, h[3], s['vol'])
                if l is None: continue
                f0 = fr(t, i)
                dur = ((hold[h[0]] if d['kind'] == 'loop' and inst == 'HAT' else h[1]) - h[0]) / rate
                # how long the channel goes on sounding: to the end of this trigger's ticks, or
                # to a volume of 0.  A hit the playback reaches just before that is not heard
                # (the hat loops are cut a few ms into their next hit: those played in full)
                t_sil = t_end
                for i2 in src['ticks']:
                    if i2 > i and ticks[i2][1][c]['vol'] == 0:
                        t_sil = ticks[i2][0]; break
                if t_sil - t < 0.03: continue
                dur = min(dur, t_sil - t)
                f1 = min(fr(t_end, i_end), fr(t + dur, i) if t + dur < t_end else fr(t_end, i_end))
                if d['kind'] == 'loop':
                    code = DRUM_NOTE[inst]
                else:
                    code = int(round(64 + h[2] + 12 * math.log2(160.0 / max(113, s['base']))))
                if d['kind'] == 'stab':
                    for k, db in enumerate(STAB_VOICES[src['smp']]):
                        notes.append(dict(f0=f0, f1=max(f1, f0 + 1), inst=inst, code=code - 24 + 12 * k, lvl=l + 4 * db,
                                          steps=[], vib=[], cls='pool', ch=c, grp='STAB', top=k))
                    continue
                if not 12 <= code <= 120: continue
                notes.append(dict(f0=f0, f1=max(f1, f0 + 1), inst=inst, code=code, lvl=l, steps=[], vib=[],
                                  cls='pool' if inst not in FIXED else inst, ch=c))
    # the noise swells: several channels play the riser at once (three as it peaks), and AMY
    # has one voice for it: their powers added, frame by frame, as one held note with a step
    # for every 1.5 dB
    by = collections.defaultdict(list)
    for f, l, code in swells:
        by[f].append((l, code))
    run = None
    for f in sorted(by) + [None]:
        if f is not None:
            l = int(round(40 * math.log10(sum(10 ** (x / 40.0) for x, _ in by[f]))))
            code = max(by[f])[1]
        if f is None or l < SWELL_FLOOR or (run and f > run['last'] + 2):
            if run:
                run['f1'] = run['last'] + 1; del run['last']; notes.append(run); run = None
            if f is None or l < SWELL_FLOOR:
                continue
        if run is None:
            run = dict(f0=f, f1=f + 1, inst='NOISE', code=code, lvl=l, steps=[], vib=[], cls='SWELL', ch=0,
                       resume=True, last=f, cur=(code, l))
        else:
            if abs(l - run['cur'][1]) >= 6 or code != run['cur'][0]:
                run['steps'].append((f, code, l)); run['cur'] = (code, l)
            run['last'] = f

    only = os.environ.get('MOD_ONLY')          # calibration: one instrument group alone
    if only:
        notes = [n for n in notes if n.get('grp', n['inst']) in only.split(',')]
    # ---- voices --------------------------------------------------------------------------
    import heapq
    heap = [(n['f0'], n.get('top', 0), -n['lvl'], k, n) for k, n in enumerate(notes)]
    heapq.heapify(heap); seq = len(heap)
    vnotes = collections.defaultdict(list)
    busy = {v: -1 for v in range(8)}; vinst_now = {v: INIT[v] for v in range(8)}
    while heap:
        n = heapq.heappop(heap)[-1]
        if n['cls'] == 'bass':
            v = 0
        elif n['cls'] in FIXED:
            v = FIXED[n['cls']]
        else:
            free = [v for v in POOL if busy[v] <= n['f0']]
            same = [v for v in free if vinst_now[v] == n['inst']]
            if same: v = same[0]
            elif free: v = min(free, key=lambda v: busy[v])
            elif n.get('top'):
                continue    # no voice free for a stab's upper voice: the stab plays without it
            else:           # steal: a stab's upper voice if there is one, else the quietest note
                v = min(POOL, key=lambda v: (-vnotes[v][-1].get('top', 0), vnotes[v][-1]['lvl']))
        if vnotes[v] and vnotes[v][-1]['f1'] > n['f0']:
            p = vnotes[v][-1]
            if p.get('resume') and p['f1'] > n['f1'] + 2 and not n.get('resume'):
                # the riser under a snare hit: it carries on when the snare has gone
                st = [x for x in p['steps'] if x[0] <= n['f1']]
                q = dict(p, f0=n['f1'], code=st[-1][1] if st else p['code'], lvl=st[-1][2] if st else p['lvl'],
                         steps=[x for x in p['steps'] if x[0] > n['f1']])
                heapq.heappush(heap, (q['f0'], 0, -q['lvl'], seq, q)); seq += 1
            p['f1'] = n['f0']
        if vnotes[v] and vnotes[v][-1]['f0'] == n['f0']:
            # two notes in one frame on one voice: keep the louder
            if vnotes[v][-1]['lvl'] >= n['lvl']:
                continue
            vnotes[v].pop()
        vnotes[v].append(n); busy[v] = n['f1']; vinst_now[v] = n['inst']

    ev = [(0, 'inst', v, I.NAMES.index(INIT[v])) for v in range(8)]
    stats = collections.Counter()
    for v in range(8):
        cur = INIT[v]; vd = 0
        for k, n in enumerate(vnotes[v]):
            f0, f1 = n['f0'], n['f1']
            if f1 <= f0:
                continue
            if n['inst'] != cur:
                ev.append((f0, 'inst', v, I.NAMES.index(n['inst']))); cur = n['inst']
            lv = clamp(n['lvl'])
            if n['inst'] == 'KICK':
                ev.append((f0, 'on', v, n['code'] + 18, lv, 8))
                ev.append((f0, 'on', v, n['code'], lv, 8, 'keephm'))
            else:
                ev.append((f0, 'on', v, n['code'], lv, harmonics(n['code'])))
            last = {}                           # (several steps in one frame: the last one)
            for f, code, l in n['steps']:
                if f0 < f < f1:
                    last[f] = (code, l)
            for f, (code, l) in sorted(last.items()):
                ev.append((f, 'on', v, code, clamp(l), harmonics(code), 'step'))
            for f, depth in n['vib']:
                if f0 <= f < f1 and depth != vd:
                    ev.append((f, 'vib', v, depth)); vd = depth
            if vd and (k + 1 == len(vnotes[v]) or not vnotes[v][k + 1]['vib']):
                ev.append((f1, 'vib', v, 0)); vd = 0
            ev.append((f1, 'off', v))
            stats[n['inst']] += 1
    # an off and an on in one frame: the off first (a re-attack); a step is a plain on
    out = []
    for e in ev:
        if e[1] == 'on' and len(e) == 7 and e[6] == 'step':
            out.append(e[:6])
        else:
            out.append(e)
    # drop an off that an on of the same voice in the same frame follows only if the on is a
    # step (legato); keep it for a new note (re-attack)
    order = {'inst': 0, 'off': 1, 'on': 2, 'vib': 3}
    out.sort(key=lambda e: (e[0], order[e[1]], e[2]))
    if frames:
        out = [e for e in out if e[0] < frames]
    hdr = {'NAME': ['Axel F (DJ Metune, MOD)']}
    vinst = {v: INIT[v] for v in range(8)}
    return hdr, out, vinst, stats


def length_frames(path):
    m, ticks = modplay.play(path if os.path.exists(path) else os.path.join(H, 'mod', os.path.basename(path)))
    return int(math.ceil((ticks[-1][0] + 0.0216) / FRAME)) + 1


if __name__ == '__main__':
    p = sys.argv[1] if len(sys.argv) > 1 else os.path.join(H, 'mod', 'axelf.mod')
    hdr, ev, vinst, st = arrange(p)
    print(hdr['NAME'][0], 'frames', length_frames(p), dict(st), collections.Counter(e[1] for e in ev))
    per_v = collections.Counter(e[2] for e in ev if e[1] == 'on')
    print('ons per voice', sorted(per_v.items()))
    per_f = collections.Counter(e[0] for e in ev)
    print('max events in a frame', max(per_f.values()))
