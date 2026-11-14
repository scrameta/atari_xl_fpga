"""Behavioural AMY for "frame reg value" logs, 8 voices x 8 harmonics, AMY Rev. C
(32.0 kHz), INDIVIDUAL mode with VOICE_LEFT / VOICE_RIGHT (registers 4, 5): amplitude slopes
(1/128 dB steps) and frequency slopes (1/32 of a 1/64-semitone unit per step, measured on the
chip model).  Noise voices: noisegen.py (bit-exact generators, measured gain).  Writes a wav."""
import sys, os, numpy as np, wave
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'player'))
import noisegen
import instruments as I
import engmodel
FS = I.mkinst.clock_fs(I.CLK); FPS = 50.0
FBASE = engmodel.A440 + engmodel.fcorr(I.CLK)  # A440 at Rev. C AMY clock
PER = {0: 128, 1: 32, 2: 8, 3: 2}
def rate(b):                            # steps per sample, signed
    e = (b >> 5) & 3; m = b & 31
    if b & 0x80: m = -((32 - m) & 31 or 32)
    return m / PER[e]
def render(log, out, vol=0xF0, left=0xCB, right=0x75, secs=None, fix=True):
    ev = {}
    for l in open(log):
        f, r, v = map(int, l.split()); ev.setdefault(f, []).append((r, v))
    nf = (max(ev) + 100) if secs is None else int(secs * FPS)
    A = B = C = 0
    cur = np.zeros(64); dst = np.zeros(64); rt = np.zeros(64)
    fw = np.zeros(8); fdst = np.zeros(8); frt = np.zeros(8)
    ph = np.zeros(64)
    vtype = [0] * 8; nzinit = False; nram = [0] * 64; nw = None; npos = 0
    kk = np.tile(np.arange(1, 9), 8).astype(float)
    outL = []; outR = []; spf = FS / FPS; acc = 0.0
    for f in range(nf):
        for r, v in ev.get(f, []):
            if r == 1: A = v
            elif r == 2: B = v
            elif r == 3: C = v
            elif r == 4: left = v
            elif r == 5: right = v
            elif r == 6: vol = v
            elif r == 0:
                if 0x30 <= v < 0x40:
                    if nzinit and not (v & 2):           # loading done: the generators start
                        nw = noisegen.words(nram, int(FS * (nf / FPS + 1)), fix); npos = 0
                    nzinit = bool(v & 2)
                elif v >= 0x80 and nzinit:
                    nram[v & 63] = A & 7
                elif 0x10 <= v < 0x18:
                    vtype[v & 7] = A & 3
                elif 0x40 <= v < 0x80:
                    h = v & 63; dst[h] = C * 32
                    if A == 0: cur[h] = dst[h]; rt[h] = 0
                    else:
                        rt[h] = rate(A)
                        if (rt[h] > 0) != (dst[h] > cur[h]) and dst[h] != cur[h]:
                            print('WRONG DIRECTION frame', f, 'h', h, cur[h] / 32, '->', C, hex(A))
                elif 0x08 <= v < 0x10:
                    vv = v & 7; fdst[vv] = ((B & 31) << 8 | C) * 32.0
                    if A == 0: fw[vv] = fdst[vv]; frt[vv] = 0
                    else: frt[vv] = rate(A)
        acc += spf; n = int(acc); acc -= n
        t = np.arange(1, n + 1)
        c = cur[:, None] + rt[:, None] * t[None, :]
        c = np.where(rt[:, None] > 0, np.minimum(c, dst[:, None]), np.maximum(c, dst[:, None]))
        cur = c[:, -1].copy()
        g = fw[:, None] + frt[:, None] * t[None, :]
        g = np.where(frt[:, None] > 0, np.minimum(g, fdst[:, None]), np.maximum(g, fdst[:, None]))
        fw = g[:, -1].copy()
        amp = np.where(c > 0, 10 ** ((c / 128 - 64) / 20), 0) * 1590
        hz = 440 * 2 ** ((g / 32 - FBASE) / 768.0)                  # (8, n)
        inc = 2 * np.pi * np.repeat(hz, 8, axis=0) * kk[:, None] / FS
        inc = np.where(np.repeat(hz, 8, axis=0) * kk[:, None] < FS / 2, inc, 0)
        phs = ph[:, None] + np.cumsum(inc, axis=1)
        ph = phs[:, -1] % (2 * np.pi)
        s = amp * np.sin(phs)
        if nw is not None:
            for v in range(8):
                if vtype[v] in (1, 2):
                    hs = slice(8 * v + 1, 8 * v + 8)
                    s[hs] *= noisegen.gain(nw[vtype[v] - 1, npos:npos + n][None, :], c[hs] / 32.0)
            npos += n
        vs = s.reshape(8, 8, n).sum(axis=1)
        l = sum(vs[v] for v in range(8) if left >> v & 1)
        r = sum(vs[v] for v in range(8) if right >> v & 1)
        outL.append(l * vol / 32); outR.append(r * vol / 32)
    L = np.concatenate(outL); R = np.concatenate(outR)
    pk = max(np.abs(L).max(), np.abs(R).max())
    print(out, 'secs %.1f peak %.0f (%.1f dBFS) rms %.0f' % (len(L) / FS, pk, 20 * np.log10(pk / 32767 + 1e-12), np.sqrt((L ** 2).mean())))
    st = np.clip(np.stack([L, R], 1), -32767, 32767).astype('<i2')
    w = wave.open(out, 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(int(FS)); w.writeframes(st.tobytes()); w.close()
    return pk
if __name__ == '__main__':
    render(sys.argv[1], sys.argv[2], secs=float(sys.argv[3]) if len(sys.argv) > 3 else None)
