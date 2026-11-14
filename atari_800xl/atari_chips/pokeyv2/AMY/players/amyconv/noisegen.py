"""AMY noise for the behavioural renderers (render.py, amysong/render8.py).

The two generators run bit-exact (amynoise.py; fix=True models the PokeyMAX core's NOISE_FIX
PRB repair).  A noise voice multiplies every harmonic but its first by a signed gain that
depends on the generator's output word and, near the top of the range, on the harmonic's level
(measured on the RTL chip model)."""
import numpy as np, amynoise
# Signed gain of a noise voice's harmonic against the output word (bins of 128), measured with
# one harmonic at amplitude $C0 (the same shape at $60 and $90): it grows with |word| on both
# sides with the sign flipped, so each harmonic is ring-modulated by the noise.
O = np.arange(-2048, 2048, 128) + 64
G = np.array([0.838, 0.819, 0.794, 0.767, 0.735, 0.707, 0.673, 0.634, 0.582, 0.530, 0.471, 0.394,
              0.328, 0.253, 0.165, 0.056, -0.048, -0.190, -0.338, -0.486, -0.680, -0.879, -1.200,
              -1.380, -1.663, -1.982, -2.359, -2.759, -3.213, -3.768, -4.300, -4.894])
# level + word past the 13-bit range (amplitude x 32 + word > 8191, BOVER): measured at $F0 as a
# constant -0.587; below 0 (BLTNEG) the harmonic is muted.
G_OVER = -0.587

def words(ram, n, fix=True):
    """per-sample output words of both generators (12-bit, two's complement) from a Noise RAM image"""
    m = amynoise.Noise(ram, fix=fix)
    w = np.zeros((2, n), np.int16)
    for i in range(n):
        m.pass_()
        w[0, i], w[1, i] = m.out
    return np.where(w >= 2048, w - 4096, w)

def gain(o, level):
    """signed gain for output words o on harmonics at amplitude `level` (amplitude units, may be
    fractional; arrays broadcast)"""
    o = np.asarray(o, float)
    g = np.interp(o, O, G)
    e = np.asarray(level) * 32 + o
    return np.where(e > 8191, G_OVER, np.where(e < 0, 0.0, g))
