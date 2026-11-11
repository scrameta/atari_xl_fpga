"""ref (libopenmpt) vs AMY preview: spectrograms of a few windows, and band levels"""
import sys, wave, numpy as np, matplotlib
matplotlib.use('Agg'); import matplotlib.pyplot as plt
def load(f):
    w = wave.open(f); x = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(float).reshape(-1, w.getnchannels())
    return x.mean(1) / 32768, w.getframerate()
a, sa = load(sys.argv[1]); b, sb = load(sys.argv[2])
wins = [tuple(map(float, s.split(':'))) for s in sys.argv[4].split(',')]
fig, axs = plt.subplots(2, len(wins), figsize=(6 * len(wins), 8))
for j, (t0, t1) in enumerate(wins):
    for i, (x, sr, nm) in enumerate(((a, sa, 'MOD (libopenmpt)'), (b, sb, 'AMY model'))):
        ax = axs[i][j] if len(wins) > 1 else axs[i]
        seg = x[int(t0 * sr):int(t1 * sr)]
        ax.specgram(seg, NFFT=2048, Fs=sr, noverlap=1536, cmap='magma', vmin=-110, vmax=-20)
        ax.set_yscale('symlog', linthresh=500); ax.set_ylim(40, 14000)
        ax.set_title('%s %.0f-%.0f s' % (nm, t0, t1))
plt.tight_layout(); plt.savefig(sys.argv[3], dpi=45)
# band levels over the whole overlap
n = min(len(a) // sa, len(b) // sb)
def bands(x, sr):
    out = []
    for lo, hi in ((30, 150), (150, 500), (500, 2000), (2000, 6000), (6000, 14000)):
        X = np.abs(np.fft.rfft(x[:n * sr].reshape(-1, sr) * np.hanning(sr), axis=1)) ** 2
        f = np.fft.rfftfreq(sr, 1 / sr)
        out.append(10 * np.log10(X[:, (f >= lo) & (f < hi)].sum(1).mean() + 1e-12))
    return out
ba, bb = bands(a, sa), bands(b, sb)
print('bands 30-150, 150-500, 500-2k, 2k-6k, 6k-14k (AMY - MOD, dB):', [round(y - x, 1) for x, y in zip(ba, bb)])
print('RMS dBFS MOD %.1f AMY %.1f' % (20 * np.log10(np.sqrt((a[:n*sa] ** 2).mean())), 20 * np.log10(np.sqrt((b[:n*sb] ** 2).mean()))))
