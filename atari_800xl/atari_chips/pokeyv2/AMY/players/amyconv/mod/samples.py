"""What each sample of the Axel F module is, for mod2amy.py: its AMY instrument and the notes or
hits inside it, in sample bytes (so a hit plays when the channel's position passes it, loops
included).

kinds:
  tone      one note: the instrument, its pitch (semitones from middle C at period 160)
  stab      major-triad stabs: each onset in the sample is a chord hit (STAB, one voice)
  phrase    a sampled riff: notes from the spectral tracker (track.py), up to 3 at a time
  drum      one hit at the start
  loop      a sampled rhythm (the hat loops): one hit per onset
  swell     sampled noise (the riser 1, the gated noise 17): a held noise note whose level
            follows the sample's
Every hit: (byte_on, byte_off, semis160, level dB re full scale).  Every sample also has its
level curve ('env', dB per 'hop' bytes: 4 ms at period 160), and the loops the byte where each
hit's plateau ends ('hold': a hat is level for 50 ms, then falls 400 dB/s)."""
import os, math
import numpy as np
import modplay, track

H = os.path.dirname(os.path.abspath(__file__))
R160 = modplay.PAL / 160            # bytes per second at period 160

# tonal samples: instrument, pitch at period 160 (YIN on the attack and the loop, mod/yin.py;
# the module is tuned ~10 cents sharp of A440)
TONE = {3: ('BASS', -33), 5: ('BASS', -36), 7: ('BASS', -21), 8: ('BASS', -31), 9: ('BASS', -19),
        13: ('BASS', -23), 14: ('BASS', -9), 15: ('BASS', -19), 16: ('BASS', -26),
        24: ('LEAD', 8), 25: ('PLUCK', 13), 11: ('BELL', 8), 28: ('BELL', 8), 4: ('BELL', 20),
        26: ('PAD', 7), 27: ('ORGAN', 13)}
# chord stabs: the triad's root at period 160 (21 F major, 22 Eb major (1st inversion),
# 23 Bb major (2nd inversion), 2 Eb major, all at period 127 = 4 semitones up)
STAB = {21: 5 - 4, 22: 3 - 4, 23: -2 - 4, 2: 3 - 4}
PHRASE = {29: 'PLUCK', 30: 'PLUCK'}
# 1: a band of noise sweeping up over 1.5 s (not notes); 17: 2.4 s of gated white noise, played
# from six offsets
SWELL = {1: 'NOISE', 17: 'NOISE'}
DRUM = {18: 'KICK', 19: 'SNARE', 12: 'CLAP'}
LOOP = {6: 'HAT', 10: 'HAT', 20: 'HAT', 31: 'HAT'}


def env_db(x, hop):
    hop = max(1, min(hop, len(x)))
    n = len(x) // hop
    e = np.sqrt((x[:n * hop].reshape(n, hop) ** 2).mean(1))
    return 20 * np.log10(np.maximum(e, 1e-4))


def onsets(x, hop, rise=9.0, floor=24.0, gap=15):
    e = env_db(x, hop)
    mx = e.max(); out = []
    for i in range(len(e)):
        lo = e[max(0, i - 5):i].min() if i else -80     # 20 ms back
        if e[i] - lo >= rise and e[i] > mx - floor and (not out or i - out[-1] >= gap):
            out.append(i)
    if not out or out[0] > 3:
        out = [0] + out
    return out, e


def peak_db(x, hop):
    return float(env_db(x, hop).max())


def analyse(m):
    S = {}
    for s in range(1, 32):
        sm = m.samples[s]
        if sm['len'] <= 2:
            continue
        x = np.array(sm['pcm'], float) / 128.0
        hop = int(R160 * 0.004)
        if s in SWELL:
            S[s] = dict(kind='swell', inst=SWELL[s], hits=[(0, sm['len'], 0, peak_db(x, int(R160 * 0.02)))])
        elif s in TONE:
            inst, st = TONE[s]
            S[s] = dict(kind='tone', inst=inst, hits=[(0, sm['len'], st, peak_db(x, int(R160 * 0.02)))])
        elif s in DRUM:
            S[s] = dict(kind='drum', inst=DRUM[s], hits=[(0, sm['len'], 0, peak_db(x, int(R160 * 0.01)))])
        elif s in STAB or s in LOOP:
            on, e = onsets(x, hop)
            hits = []; hold = {}
            for j, i in enumerate(on):
                nxt = on[j + 1] if j + 1 < len(on) else len(e)
                lv = e[i:min(nxt, i + 15)].max()
                end = nxt
                for k in range(i, nxt):
                    if e[k] < lv - 20: end = k; break
                hits.append((i * hop, end * hop, STAB.get(s, 0), float(lv)))
                hold[i * hop] = next((k for k in range(i + 2, end) if e[k:k + 3].max() < lv - 5), end) * hop
            S[s] = dict(kind='stab' if s in STAB else 'loop', inst='STAB' if s in STAB else LOOP[s], hits=hits, hold=hold)
        elif s in PHRASE:
            tr = track.track(x * 128, R160, top=3)
            hits = [(int(a * R160), int(b * R160), n, 20 * math.log10(max(l, 1e-4)) + 6) for a, b, n, l in tr]
            # the tracker also reports a note's partials and the tail of one that has just
            # ended as short quiet notes (-11 to -19 dB, 50-100 ms): not played
            top = max(h[3] for h in hits)
            hits = [h for h in hits if h[3] > top - 9]
            S[s] = dict(kind='phrase', inst=PHRASE[s], hits=hits)
        if s in S:
            S[s]['env'] = env_db(x, hop); S[s]['hop'] = hop
    return S


if __name__ == '__main__':
    m = modplay.Mod(os.path.join(H, 'axelf.mod'))
    S = analyse(m)
    for s in sorted(S):
        d = S[s]
        print(s, d['kind'], d['inst'], len(d['hits']), [(a, b, n, round(l, 1)) for a, b, n, l in d['hits'][:8]],
              'hold ' + str(sorted(d['hold'].items())) if d.get('hold') and d['kind'] == 'loop' else '')
