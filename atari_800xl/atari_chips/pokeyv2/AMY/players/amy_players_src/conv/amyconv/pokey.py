"""POKEY (AUDCTL $50 style: ch1+2 joined 16-bit at 1.79 MHz, ch3/ch4 at 64 kHz) per-frame
state -> per-channel tracks: (kind, freq_hz, vol) per frame; kind 'tone', 'buzz' (dist C),
'noise' (dist 8 / 0 / 2 ...), or None (silent)."""
import math
PHI2 = {'PAL': 1773447.0, 'NTSC': 1789773.0}

def poly4_period(div):
    """distortion C: the output flips on each divider pulse where the 4-bit poly is 1;
    the poly runs at the machine clock.  Returns the waveform's period in machine cycles and
    one period of the waveform sampled per divider pulse (+1/-1)."""
    p = 0xF; seq = []
    for i in range(15):
        bit = p & 1
        seq.append(bit)
        nb = ((p >> 0) ^ (p >> 1)) & 1       # x^4 + x^3 + 1
        p = (p >> 1) | (nb << 3)
    out = 1; samples = []; k = 0
    start = None
    for n in range(60):
        b = seq[(n * div) % 15]
        if b: out = -out
        samples.append(out)
    # period: smallest L with repeating samples
    for L in range(1, 61):
        if all(samples[i] == samples[i + L] for i in range(60 - L)) and (60 // L) >= 2:
            return L * div, samples[:L]
    return 30 * div, samples[:30]

def channel_state(f, c, audctl, clk='PAL'):
    """POKEY channel c (0..3) from frame regs f -> (kind, hz, vol)"""
    phi = PHI2[clk]
    audc = f[2 * c + 1]; vol = audc & 15; dist = audc >> 5
    if vol == 0 or (audc & 0x10):               # volume only: treat as silent
        return (None, 0.0, 0)
    joined12 = audctl & 0x10; joined34 = audctl & 0x08
    if c == 0 and joined12: return (None, 0.0, 0)
    if c == 2 and joined34: return (None, 0.0, 0)
    base = phi / 28 if not (audctl & 1) else phi / 114
    if c == 1 and joined12:
        n = f[2] << 8 | f[0]; div = n + 7 if audctl & 0x40 else n + 1; fclk = phi if audctl & 0x40 else base
    elif c == 3 and joined34:
        n = f[6] << 8 | f[4]; div = n + 7 if audctl & 0x20 else n + 1; fclk = phi if audctl & 0x20 else base
    else:
        n = f[2 * c]
        fast = (c == 0 and audctl & 0x40) or (c == 2 and audctl & 0x20)
        div = n + 4 if fast else n + 1; fclk = phi if fast else base
    if dist in (5, 7):
        return ('tone', fclk / (2 * div), vol)
    if dist == 6:
        per, _ = poly4_period(div)
        return ('buzz', phi / per if fclk == phi else fclk / per, vol)
    return ('noise', fclk / div, vol)
