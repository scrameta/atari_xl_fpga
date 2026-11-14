#!/usr/bin/env python3
"""
amy_model.py - behavioural AMY Rev C model for previewing command streams

Reads the "ms reg value" log written by amy_drums_host and renders a
32 kHz stereo WAV.  It follows the programmer-visible spec (Rev B plus
the Rev C draft), not the RTL:

  * envelopes: slope/destination, updates every 2/8/32/128 samples,
    amplitude 1/128 dB and frequency 1/2048 semitone steps, stop at the
    destination; zero-slope jumps apply at command time (Rev C fix)
  * harmonic k of a voice (k = position in the voice, from the LHP
    flags) at f_v * (k + detune/64)
  * output per harmonic: 0.049 full scale at 63.75 dB (measured, RTL), x VOLUME/32,
    INDIVIDUAL mode masks, signed saturation
  * voice type 3: each harmonic is amplitude * cos(random phase) per
    sample (white)
  * voice types 1/2: harmonics 2.. ring-modulated by ~200 Hz band noise
    (an approximation of the original noise generators)
  * diffusion: per-sample random phase step r8 * (8 + s&7) << (s>>3)
    (2^18 per cycle), as amy1_ext_phase with revc_diffusion_exp.patch
  * proportional mode (7.6): B bit 7 on FFBP/HABP while unlocked, step
    (dest - cur) >> k, at least 1, on the 18-bit frequency / 13-bit
    amplitude, until the top bits match (as the RTL's arrival test)

usage: amy_model.py log.txt out.wav [--from S] [--to S] [--png spec.png]
"""
import sys, argparse
import numpy as np
from scipy.io import wavfile
from scipy.signal import lfilter, butter

FS = 32000
BLK = 32                                    # 1 ms
# One harmonic at level 255 peaks at about 1600 counts at VOLUME 32 (measured on the
# Rev C RTL: two harmonics at level 240, VOLUME $FF, 8291 RMS): 0.049 of 16-bit full scale.
HFS = 1600 / 32768
INTERVAL = np.array([128, 32, 8, 2])


def slope_step(a):
    """(interval, signed step) for an 8-bit Atari slope byte."""
    e = (a >> 5) & 3
    m = a & 31
    step = m if a < 0x80 else -(32 - m) if m else 0
    return INTERVAL[e], step


class Amy:
    def __init__(self, rng):
        self.rng = rng
        self.reset()

    def reset(self):
        self.a = self.b = self.c = 0
        self.acur = np.zeros(64); self.adst = np.zeros(64)
        self.aint = np.ones(64, int); self.astp = np.zeros(64)
        self.fcur = np.full(8, 4978 * 32.0); self.fdst = self.fcur.copy()
        self.fint = np.ones(8, int); self.fstp = np.zeros(8)
        self.vtype = np.zeros(8, int)
        self.aprop = np.zeros(64, int); self.fprop = np.zeros(8, int)   # k + 1, 0 = linear
        self.b7 = 0
        self.lhp = np.zeros(32, int)
        self.det = np.zeros(64); self.sto = np.zeros(64); self.att = np.zeros(8)
        self.ext = False; self.unlock = 0
        self.run = False; self.nzinit = False; self.indiv = False
        self.mask_l = 0xFF; self.mask_r = 0xFF; self.vol = 0xFF
        self.phase = np.zeros(64)
        self.ring = np.zeros(64)              # legacy noise state
        self.map()

    def map(self):
        """harmonic -> (voice, k) from the Last Harmonic Pair flags."""
        self.hv = np.full(64, -1); self.hk = np.zeros(64)
        v, k = 0, 1
        for p in range(32):
            if v > 7:
                break
            for h in (2 * p, 2 * p + 1):
                self.hv[h] = v; self.hk[h] = k; k += 1
            if self.lhp[p]:
                v += 1; k = 1

    def write(self, reg, val):
        if reg == 1: self.a = val
        elif reg == 2: self.b = val & 31; self.b7 = val >> 7
        elif reg == 3: self.c = val
        elif reg == 4: self.mask_l = val
        elif reg == 5: self.mask_r = val
        elif reg == 6: self.vol = val
        elif reg == 7:
            if val == 0xA5: self.unlock = 1
            elif val == 0x5A and self.unlock == 1: self.ext = True; self.unlock = 0
            else: self.unlock = 0
        elif reg == 0: self.command(val)

    def command(self, c):
        a, b, cc = self.a, self.b, self.c
        if c < 8:
            self.reset(); return
        if c < 0x10:
            v = c & 7; d = ((b << 8) | cc) * 32.0
            self.fdst[v] = d
            self.fprop[v] = 0
            if a == 0:
                self.fcur[v] = d; self.fstp[v] = 0
            elif self.ext and self.b7:
                self.fint[v] = INTERVAL[(a >> 5) & 3]; self.fstp[v] = 0; self.fprop[v] = (a & 15) + 1
            else:
                self.fint[v], self.fstp[v] = slope_step(a)
        elif c < 0x18:
            self.vtype[c & 7] = a & 3
        elif c < 0x20:
            pass
        elif c < 0x30:
            self.indiv = bool(c & 4)
        elif c < 0x34 or (c < 0x40 and not self.ext):
            self.run = bool(c & 1); self.nzinit = bool(c & 2)
        elif c < 0x40:
            if c == 0x34: self.att[a & 7] = cc
            elif c == 0x35: self.det[a & 63] = (cc & 63) - 64 if cc & 32 else cc & 63
            elif c == 0x36: self.sto[a & 63] = cc & 63
            elif c == 0x39: self.det[:] = 0; self.sto[:] = 0; self.att[:] = 0; self.aprop[:] = 0; self.fprop[:] = 0
        elif c < 0x80:
            h = c & 63; d = cc * 32.0
            self.adst[h] = d
            self.aprop[h] = 0
            if a == 0:
                self.acur[h] = d; self.astp[h] = 0
            elif self.ext and self.b7:
                self.aint[h] = INTERVAL[(a >> 5) & 3]; self.astp[h] = 0; self.aprop[h] = (a & 15) + 1
            else:
                self.aint[h], self.astp[h] = slope_step(a)
        elif c < 0xC0:
            if not self.nzinit:
                self.lhp[(c >> 1) & 31] = c & 1; self.map()

    @staticmethod
    def env_block(cur, dst, intv, stp, n0):
        t = np.arange(BLK)
        cnt = (n0 + t)[None, :] // intv[:, None] - ((n0 - 1) // intv)[:, None]
        val = cur[:, None] + stp[:, None] * cnt
        up = stp[:, None] > 0
        dn = stp[:, None] < 0
        val = np.where(up, np.minimum(val, dst[:, None]), val)
        val = np.where(dn, np.maximum(val, dst[:, None]), val)
        newcur = val[:, -1].copy()
        done = (stp != 0) & (newcur == dst)
        return val, newcur, done

    @staticmethod
    def prop_block(val, cur, dst, intv, prop, n0):
        """Proportional envelopes (prop = k + 1 > 0) on their own rows."""
        t = np.arange(BLK)
        for i in np.nonzero(prop)[0]:
            k = int(prop[i]) - 1
            c = int(cur[i]); d = int(dst[i])
            cnt = (n0 + t) // intv[i] - (n0 - 1) // intv[i]
            seq = [c]
            for _ in range(int(cnt[-1])):
                if (c >> 5) != (d >> 5):
                    diff = d - c
                    st = diff >> k
                    if st == 0 and diff > 0:
                        st = 1
                    c += st
                seq.append(c)
            val[i] = np.array(seq, float)[cnt]
            cur[i] = c
            if (c >> 5) == (d >> 5):
                prop[i] = 0
        return val

    def render_block(self, n0):
        if not self.run:
            return np.zeros(BLK), np.zeros(BLK)
        aval, acur, adone = self.env_block(self.acur, self.adst, self.aint, self.astp, n0)
        self.astp[adone] = 0
        if self.aprop.any():
            aval = self.prop_block(aval, acur, self.adst, self.aint, self.aprop, n0)
        self.acur = acur
        fval, fcur, fdone = self.env_block(self.fcur, self.fdst, self.fint, self.fstp, n0)
        self.fstp[fdone] = 0
        if self.fprop.any():
            fval = self.prop_block(fval, fcur, self.fdst, self.fint, self.fprop, n0)
        self.fcur = fcur

        used = self.hv >= 0
        hv = np.where(used, self.hv, 0)
        lvl = aval - (self.att[hv] * 32)[:, None]
        lin = np.where(lvl > 0, 10 ** ((lvl / 128 - 64) / 20), 0.0)
        lin[~used] = 0
        fv = 440 * 2 ** ((fval / 32 - 4978) / 768)                # 8 x BLK
        fh = fv[hv] * (self.hk + self.det / 64)[:, None]
        inc = fh / FS
        sto = self.sto[:, None]
        if sto.any():
            # RTL (exponential patch): step = r8 * (8 + s&7) << (s>>3), 2^18/cycle
            si = self.sto.astype(int)
            step = np.where(si > 0, (8 + (si & 7)) << (si >> 3), 0)[:, None] / 2.0 ** 18
            inc = inc + step * self.rng.integers(-128, 128, inc.shape)
        ph = self.phase[:, None] + np.cumsum(inc, axis=1)
        self.phase = ph[:, -1] % 1.0
        out = lin * np.cos(2 * np.pi * ph)
        vt = self.vtype[hv]
        white = (vt == 3) & used
        if white.any():
            out[white] = lin[white] * np.cos(2 * np.pi * self.rng.random((white.sum(), BLK)))
        legacy = ((vt == 1) | (vt == 2)) & used & (self.hk > 1)
        if legacy.any():
            out[legacy] *= self.legacy_noise[n0 // BLK % self.legacy_noise.shape[0]][legacy]
        out *= HFS * self.vol / 32

        lm = np.array([(self.mask_l >> v) & 1 for v in range(8)])[hv] * used
        rm = np.array([(self.mask_r >> v) & 1 for v in range(8)])[hv] * used
        if not self.indiv:
            lm = rm = used.astype(float)
        return (out * lm[:, None]).sum(0), (out * rm[:, None]).sum(0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('log'); ap.add_argument('wav')
    ap.add_argument('--from', dest='t0', type=float, default=0)
    ap.add_argument('--to', dest='t1', type=float, default=None)
    ap.add_argument('--seed', type=int, default=1)
    args = ap.parse_args()

    ev = np.loadtxt(args.log, dtype=np.int64).reshape(-1, 3)
    end_ms = int(ev[-1, 0]) + 3000 if args.t1 is None else int(args.t1 * 1000)
    rng = np.random.default_rng(args.seed)
    amy = Amy(rng)
    # precomputed band-limited ring-mod noise for the original noise types
    b, a = butter(2, 200 / (FS / 2))
    nz = lfilter(b, a, rng.standard_normal((64, FS * 4)), axis=1)
    nz /= nz.std()
    amy.legacy_noise = nz.reshape(64, -1, BLK).transpose(1, 0, 2)

    t0 = int(args.t0 * 1000)
    L = []; R = []
    i = 0; n = len(ev)
    for ms in range(end_ms):
        while i < n and ev[i, 0] <= ms:
            amy.write(int(ev[i, 1]), int(ev[i, 2])); i += 1
        l, r = amy.render_block(ms * BLK)
        if ms >= t0:
            L.append(l); R.append(r)
    y = np.stack([np.concatenate(L), np.concatenate(R)], 1)
    clip = np.mean(np.abs(y) > 1)
    peak = np.abs(y).max()
    y = np.clip(y, -1, 1)
    wavfile.write(args.wav, FS, (y * 32767).astype(np.int16))
    print(f"{args.wav}: {len(y)/FS:.1f} s, peak {20*np.log10(peak+1e-12):+.1f} dBFS, clipped {clip*100:.3f}%")


if __name__ == '__main__':
    main()
