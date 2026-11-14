import numpy as np
def yin_period(x, tmin=16, tmax=800, thr=0.12):
    """period in bytes (float) by YIN on segment x (needs len >= 2*tmax)"""
    x = np.asarray(x, float); x = x - x.mean()
    W = len(x) - tmax
    d = np.zeros(tmax + 1)
    for tau in range(1, tmax + 1):
        e = x[:W] - x[tau:tau + W]; d[tau] = (e * e).sum()
    cm = d.copy(); cm[0] = 1
    cm[1:] = d[1:] * np.arange(1, tmax + 1) / np.maximum(np.cumsum(d[1:]), 1e-12)
    tau = None
    for t in range(tmin, tmax):
        if cm[t] < thr:
            while t + 1 < tmax and cm[t + 1] < cm[t]: t += 1
            tau = t; break
    if tau is None:
        tau = tmin + int(np.argmin(cm[tmin:tmax]))
    # parabolic refinement
    a, b, c = cm[tau - 1], cm[tau], cm[tau + 1]
    den = a - 2 * b + c
    return tau + (0.5 * (a - c) / den if den else 0.0), cm[tau]
