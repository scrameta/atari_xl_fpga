"""per-instrument level calibration: each instrument group alone, AMY model vs the MOD's own
samples for it (modmix stems), RMS over the frames where the MOD stem sounds"""
import os, sys, subprocess, wave, numpy as np
H = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, H)
import modplay, modmix, samples
OUT = sys.argv[1]; SECS = float(sys.argv[2]) if len(sys.argv) > 2 else 184
GROUPS = sys.argv[3].split(';') if len(sys.argv) > 3 else None
m, ticks = modplay.play(os.path.join(H, 'axelf.mod'))
S = samples.analyse(m)
by = {}
for s, d in S.items(): by.setdefault(d['inst'], set()).add(s)
groups = GROUPS or sorted(by)
def load(f):
    w = wave.open(f); x = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(float).reshape(-1, w.getnchannels())
    return x.mean(1) / 32768
for g in groups:
    insts = g.split(',')
    smp = set().union(*(by[i] for i in insts))
    ref = modmix.render(m, ticks, smp).mean(1) * 0.5        # the same gain as the full ref render
    ref = ref[:int(SECS * 32000)]
    wav = os.path.join(OUT, 'cal_%s.wav' % g.replace(',', '_'))
    env = dict(os.environ, MOD_ONLY=g, AMYCONV_SET='4')
    subprocess.run([sys.executable, os.path.join(H, '..', 'preview.py'), '4', '0', 'on', wav, str(SECS)], env=env,
                   check=True, capture_output=True)
    amy = load(wav)
    n = min(len(ref), len(amy)) // 640
    er = np.sqrt((ref[:n * 640].reshape(n, 640) ** 2).mean(1)); ea = np.sqrt((amy[:n * 640].reshape(n, 640) ** 2).mean(1))
    act = er > er.max() * 0.03
    r1 = 20 * np.log10(np.sqrt((er[act] ** 2).mean())); r2 = 20 * np.log10(np.sqrt((ea[act] ** 2).mean()) + 1e-9)
    print('%-12s MOD %6.1f dB  AMY %6.1f dB  diff %+5.1f' % (g, r1, r2, r2 - r1), flush=True)
