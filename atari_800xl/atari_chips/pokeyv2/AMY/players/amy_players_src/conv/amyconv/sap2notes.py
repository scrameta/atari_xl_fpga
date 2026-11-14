"""SAP (TYPE B) -> notes per POKEY channel: start, length, kind, pitch, volume and pitch tracks."""
import sys, os, math, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sapcap, pokey

def semis(hz):           # semitones above C4 (261.63 Hz)
    return 12 * math.log2(hz / 261.6256)

def notes(path, song, frames, clk='PAL'):
    hdr, fr = sapcap.capture(path, song, frames)
    out = []
    for c in range(4):
        tr = [pokey.channel_state(f, c, f[8], clk) for f in fr]
        cur = None
        for t, (kind, hz, vol) in enumerate(tr):
            new = False
            if kind is None:
                if cur: out.append(cur); cur = None
                continue
            if cur is None or kind != cur['kind']:
                new = True
            elif kind != 'noise' and abs(semis(hz) - cur['base']) > 0.6:
                new = True
            elif vol >= cur['vol'][-1] + 2 or (kind == 'noise' and vol > cur['vol'][-1]):
                new = True
            if new:
                if cur: out.append(cur)
                cur = dict(ch=c, start=t, kind=kind, base=semis(hz) if kind != 'noise' else 0.0,
                           hz=[], vol=[], rate=hz)
            cur['hz'].append(hz); cur['vol'].append(vol)
        if cur: out.append(cur)
    out.sort(key=lambda n: (n['start'], n['ch']))
    return hdr, fr, out

# ---- set 1 (Gilmore / Hubbard) segmentation -------------------------------------------------
# notes() above starts a new note whenever the pitch is 0.6 semitones from the note's first
# frame, or the volume steps up by 2.  That chops two things these players do all the time:
#   * vibrato on an 8-bit divider: Warhawk's lead swings AUDF $28..$2B around the note, 1.2
#     semitones peak to peak, so one held note became a string of short ones;
#   * a swell: volume 2 3 4 7 8 9 is one attack, not a second note at the 7.
# notes2() splits on the step between one frame and the next instead: a note change jumps (most
# of a semitone or more in one frame), vibrato and slides creep; a volume step up is a new
# attack only after the volume has fallen.  Falling-pitch hits (toms, zaps, Draconus's plucks) are
# found first, on the raw frames, so they are one hit whatever their size in semitones.
VIB_STEP = 0.75      # semitones in one frame: more is a new note, less is vibrato or a slide
VIB_RANGE = 1.5      # a note's pitch range at most; up to VIB_WIDE when it is seen to swing
VIB_WIDE = 2.0       # (one AUDF step is 0.6 semitones at 1 kHz: Warhawk's high notes swing 1.8)
VIB_CYCLE = 8        # frames: these players' vibrato period
VIB_SHIFT = 0.5      # the pitch averaged over a cycle moves this much: a new note

def _shifts(tr, used):
    """frames where a note changes under the vibrato with no step to show it (Draconus at
    5920: AUDF $3E-$40 swinging, then $3B-$3D, joined at the low end of the swing by a step
    of 0.56).  The pitch averaged over the vibrato cycle before the frame and over the cycle
    from it differ by VIB_SHIFT or more; the frame where they differ most."""
    n = len(tr); W = VIB_CYCLE
    p = [semis(x[1]) if x[0] in ('tone', 'buzz') else None for x in tr]
    D = [0.0] * n
    for t in range(W, n - W + 1):
        k = tr[t][0]
        if k not in ('tone', 'buzz'): continue
        if any(tr[u][0] != k or used[u] for u in range(t - W, t + W)): continue
        if any(abs(p[u] - p[u - 1]) > VIB_STEP or abs(tr[u][2] - tr[u - 1][2]) >= 2 for u in range(t - W + 1, t + W)):
            continue                               # a step or an attack nearby splits anyway
        D[t] = abs(sum(p[t:t + W]) - sum(p[t - W:t])) / W
    out = set()
    for t in range(n):
        if D[t] >= VIB_SHIFT and D[t] == max(D[max(0, t - W):t + W + 1]) and not any(u in out for u in range(t - W, t)):
            # (the vibrato's phase pulls that frame a little either way: the best fit of
            # two levels to the two cycles places it)
            def sse(u):
                a, b = p[t - W:u], p[u:t + W]
                ma, mb = sum(a) / len(a), sum(b) / len(b)
                return sum((x - ma) ** 2 for x in a) + sum((x - mb) ** 2 for x in b)
            out.add(min(range(t - W // 2, t + W // 2 + 1), key=sse))
    return out

def _drops(tr):
    """falling-pitch hits on one channel: [(first frame, last frame, [tone frames])].
    Tone frames whose pitch falls every frame and whose volume never rises, at least 3 of
    them, with up to 2 noise frames between (Hubbard mixes the two in a tom).  Either the
    hit stands alone (no tone before or after), or it fades by 2 or more and something new
    follows: so the falling half of a vibrato cycle in a held note is not one."""
    n = len(tr); out = []; t = 0
    tone = lambda i: 0 <= i < n and tr[i][0] == 'tone'
    while t < n:
        if not tone(t):
            t += 1; continue
        fr = [t]; u = t
        while True:
            w = u + 1; gap = 0
            while w < n and tr[w][0] == 'noise' and gap < 2:
                w += 1; gap += 1
            if not tone(w): break
            a, b = tr[u], tr[w]
            if not (b[1] < a[1] and 12 * math.log2(a[1] / b[1]) <= 2.5 and b[2] <= a[2]): break
            fr.append(w); u = w
        ok = False
        if len(fr) >= 3:
            alone = not tone(t - 1) and not tone(u + 1)
            start_ok = not tone(t - 1) or tr[t][2] >= tr[t - 1][2] + 2 or tr[t][1] > tr[t - 1][1]
            end_ok = not tone(u + 1) or tr[u + 1][2] >= tr[u][2] + 2 or \
                12 * math.log2(tr[u + 1][1] / tr[u][1]) >= 0.5
            ok = alone or (start_ok and end_ok and tr[t][2] - tr[u][2] >= 2)
        if ok:
            out.append((t, u, fr)); t = u + 1
        else:
            t += 1
    return out

def _centre(ps):
    """a note's pitch from its frames' pitches (semitones): the one it sits on most of the
    time, or the middle of its swing when it has vibrato"""
    c = collections.Counter(round(p, 3) for p in ps)
    p, k = c.most_common(1)[0]
    if k >= 0.6 * len(ps):
        return p
    return (min(ps) + max(ps)) / 2.0

def notes2(path, song, frames, clk='PAL'):
    hdr, fr = sapcap.capture(path, song, frames)
    out = []
    for c in range(4):
        tr = [pokey.channel_state(f, c, f[8], clk) for f in fr]
        n = len(tr)
        # a single distortion-C frame inside a noise burst that carries on is part of the
        # drum (Warhawk's snare on the bass channel: noise, 1 frame of distortion C, noise).
        # (Not a pure tone: noise and tone frames mixed are a tom, below.)
        for t in range(1, n - 2):
            if tr[t][0] == 'buzz' and tr[t - 1][0] == 'noise' and tr[t + 1][0] == 'noise' \
                    and tr[t + 2][0] == 'noise':
                tr[t] = ('noise', tr[t - 1][1], tr[t][2])
        used = [False] * n
        for t0, t1, tf in _drops(tr):
            for t in tf: used[t] = True
            out.append(dict(ch=c, start=t0, kind='sweep', base=semis(tr[t0][1]), end=semis(tr[t1][1]),
                            hz=[tr[t][1] for t in tf], vol=[tr[t][2] for t in tf], rate=0, last=t1))
        shifts = _shifts(tr, used)
        cur = None
        def close():
            nonlocal cur
            if cur:
                if cur['kind'] != 'noise':
                    ps = [semis(h) for h in cur['hz']]
                    cur['base'] = _centre(ps)
                    d = [b - a for a, b in zip(ps, ps[1:]) if b != a]
                    turns = sum(1 for a, b in zip(d, d[1:]) if a * b < 0)
                    cur['swing'] = (max(ps) - min(ps)) / 2.0 if turns >= 2 else 0.0
                out.append(cur)
            cur = None
        for t, (kind, hz, vol) in enumerate(tr):
            if kind is None or used[t]:
                close(); continue
            new = cur is None or kind != cur['kind']
            if not new and kind == 'noise':
                new = vol > cur['vol'][-1]
            elif not new:
                p = semis(hz)
                if vol >= cur['vol'][-1] + 2 and cur['vol'][-1] < max(cur['vol']):
                    new = True                     # an attack after the volume had fallen
                elif vol <= cur['vol'][-1] - 2 and any(
                        tr[u][2] >= vol + 2 for u in range(t + 1, min(t + 7, n))
                        if all(tr[w][0] == kind and not used[w] and tr[w][2] >= vol for w in range(t + 1, u + 1))):
                    new = True                     # the volume drops and swells again: the next
                                                   # swelling note (Warhawk's lead: 6 6 6 | 2 3 4 7 8 9)
                elif abs(p - semis(cur['hz'][-1])) > VIB_STEP or t in shifts:
                    new = True                     # a step
                else:
                    r = max(cur['hi'], p) - min(cur['lo'], p)
                    if cur['lo'] <= p <= cur['hi']:
                        pass                       # within what the note has already covered
                    elif r > VIB_WIDE:
                        new = True
                    elif r > VIB_RANGE:
                        # wide: a vibrato if it has been swinging, or turns back soon;
                        # else a slide that has gone too far for one note
                        ps = [semis(h) for h in cur['hz']]
                        d = [b - a for a, b in zip(ps, ps[1:]) if b != a]
                        swung = sum(1 for a, b in zip(d, d[1:]) if a * b < 0) >= 2
                        mid = (cur['lo'] + cur['hi']) / 2.0
                        back = False
                        for u in range(t + 1, min(t + 7, n)):
                            if tr[u][0] != kind or used[u]: break
                            if abs(semis(tr[u][1]) - mid) < abs(p - mid) - 0.2: back = True; break
                        new = not (swung or back)
            if new:
                close()
                cur = dict(ch=c, start=t, kind=kind, base=semis(hz) if kind != 'noise' else 0.0,
                           hz=[], vol=[], rate=hz, lo=semis(hz) if kind != 'noise' else 0.0,
                           hi=semis(hz) if kind != 'noise' else 0.0, swing=0.0)
            cur['hz'].append(hz); cur['vol'].append(vol)
            if kind != 'noise':
                p = semis(hz); cur['lo'] = min(cur['lo'], p); cur['hi'] = max(cur['hi'], p)
        close()
    out.sort(key=lambda n: (n['start'], n['ch']))
    # a single frame at the pitch of the note it follows straight on, no louder than that note
    # was: its tail, not a note (Hubbard's bass: 8 9 7 5 4 3 2 5, the 5 a frame before the
    # next note's pitch)
    res = []; last = {}
    for n in out:
        p = last.get(n['ch'])
        if n['kind'] in ('tone', 'buzz') and len(n['vol']) == 1 and p is not None and p['kind'] == n['kind'] \
                and p['start'] + len(p['vol']) == n['start'] and abs(p['base'] - n['base']) < 0.3 \
                and n['vol'][0] <= max(p['vol']):
            p['vol'] += n['vol']; p['hz'] += n['hz']
            continue
        res.append(n)
        if n['kind'] != 'sweep':
            last[n['ch']] = n
        else:
            last.pop(n['ch'], None)
    return hdr, fr, res

if __name__ == '__main__':
    hdr, fr, ns = notes(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]))
    print(hdr['NAME'][0], len(ns), 'notes')
    by = collections.Counter((n['ch'], n['kind']) for n in ns)
    print(sorted(by.items()))
    dr = collections.Counter((n['ch'], round(n['rate']), len(n['vol']), tuple(n['vol'][:3])) for n in ns if n['kind'] == 'noise')
    for k, v in sorted(dr.items(), key=lambda x: -x[1])[:15]: print('  drum', k, v)
    for n in ns[:30]:
        print(n['start'], n['ch'], n['kind'], '%.2f' % n['base'], len(n['vol']), n['vol'][:12])
