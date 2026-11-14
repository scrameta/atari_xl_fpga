#!/usr/bin/env python3
"""copsim.py LOG IMAGE.bin OUTDIR [--ref ENGINE_LOG] [--frames] - replay a ported player's
register log through the copper model and the AMY chip model.

LOG: "time reg value" lines, time in ms (--frames: in 20 ms frames). reg 0-7: AMY ($D2C0+),
written by the 6502 itself; $95-$9E: the copper's registers. IMAGE.bin is the copper note
engine (copgen.py), at $E000. The copper runs on a 1 ms tick and is instant within it (it runs
until every thread rests after each 6502 write), so its AMY writes are interleaved with the
6502's in the order they would reach the chip.

Writes OUTDIR/copper.chip.txt and .wav. With --ref, also renders the engine version's log
through engine.py and compares (per ms AMY writes and audio)."""
import sys, os, collections, subprocess, argparse
H = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, H)
from copper import Model
DRUMS = os.environ.get('AMY_TOOLS', os.path.join(H, 'tools'))   # engine.py, amy_model.py
sys.path.insert(1, DRUMS)
import engine

AMYBASE = 0xC0


def replay(lines, img, base=0xE000):
    mem = bytearray(65536); mem[base:base + len(img)] = img
    m = Model(mem, 0x1FF, {})
    chip = []                     # (t, reg, value)
    caddr = [0, 0]; cbase = 0; params = []
    stats = collections.Counter()
    now = 0
    last = {}                     # thread -> the time of its last start
    cost = {}                     # thread -> (RAM accesses, AMY commands) of its last start
    spins = []                    # (t, estimated 6502 wait in us at fast RAM, at slow RAM)
    def run():
        n0 = len(m.writes)
        m.run_pass()
        for t, a, v in m.writes[n0:]:
            chip.append((m.tick, a - AMYBASE, v))
    for t, r, v in lines:
        while now < t:                                  # the ticks up to this write
            now += 1; m.tick = now; m.do_tick(); run()
        m.tick = now
        if r < 8:
            chip.append((t, r, v)); stats['6502 AMY writes'] += 1
        elif r < 16:
            raise SystemExit('note engine register %d written at %d: not ported?' % (r, t))
        elif r == 0x95:
            if v & 2:
                m.kill(0xFF); m.queue.clear(); params = []
            stats['CCTRL'] += 1
        elif r == 0x96: caddr[0] = v; stats['CADDR'] += 1
        elif r == 0x97: caddr[1] = v; stats['CADDR'] += 1
        elif r == 0x98:
            busy = not m.at_rest(v & 7) or bool(m.queue)
            stats['starts'] += 1; stats['starts to a busy thread'] += busy
            th = v & 7
            if last.get(th) == t:
                stats['starts right after one to the same thread'] += 1
                ra, nc = cost[th]
                # the 6502 waits for the earlier start to finish: its RAM accesses (core-clock
                # RAM, ~35 ns, or 2 x PHI2 slots, 280 ns) and AMY commands (~2.44 us each)
                spins.append((t, max(0, ra * 0.035 + nc * 2.44 - 10), max(0, ra * 0.28 + nc * 2.44 - 10)))
            last[th] = t
            m.post(th, caddr[0] | caddr[1] << 8, cbase, params[:8]); params = []
            stats['CSTART'] += 1
            r0, c0 = m.ramacc, sum(1 for x in m.writes if x[1] == 0xC0)
            run()
            cost[th] = (m.ramacc - r0, sum(1 for x in m.writes if x[1] == 0xC0) - c0)
            continue
        elif r == 0x99: m.host_kill(v); stats['CKILL'] += 1
        elif r in (0x9B, 0x9C): stats['CTICK'] += 1
        elif r == 0x9D: cbase = v; stats['CBASE'] += 1
        elif r == 0x9E: params.append(v); stats['CPARAM'] += 1
        else:
            raise SystemExit('register $%02X written at %d' % (r, t))
        run()
    for k in range(2000):                               # let the tails finish
        now += 1; m.tick = now; m.do_tick(); run()
    m.spins = spins
    return chip, m, stats


def render(chip, path):
    txt = os.path.splitext(path)[0] + '.chip.txt'
    with open(txt, 'w') as f:
        for t, r, v in chip: f.write('%d %d %d\n' % (t, r, v))
    subprocess.run([sys.executable, os.path.join(DRUMS, 'amy_model.py'), txt, path], check=True, capture_output=True)


def load_log(path, frames):
    out = []
    for l in open(path):
        p = l.split()
        if len(p) == 3:
            t, r, v = map(int, p)
            out.append((t * 20 if frames else t, r, v))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('log'); ap.add_argument('image'); ap.add_argument('out')
    ap.add_argument('--ref'); ap.add_argument('--frames', action='store_true')
    ap.add_argument('--ms', type=int, default=0, help='only the first MS ms')
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    lines = load_log(a.log, a.frames)
    if a.ms: lines = [l for l in lines if l[0] < a.ms]
    img = open(a.image, 'rb').read()
    chip, m, st = replay(lines, img)
    render(chip, os.path.join(a.out, 'copper.wav'))
    print('%s: %d 6502 writes over %.1f s; %d AMY writes from the copper and the 6502' % (
        a.log, len(lines), lines[-1][0] / 1000.0, len(chip)))
    print('  ' + ', '.join('%s %d' % kv for kv in sorted(st.items())))
    print('  copper: %d instructions, %d RAM accesses (%.0f, %.0f per start)' % (
        m.instr, m.ramacc, m.instr / max(1, st['starts']), m.ramacc / max(1, st['starts'])))
    if m.spins:
        fr = collections.defaultdict(lambda: [0, 0])
        for t, f, s_ in m.spins:
            fr[t // 20][0] += f; fr[t // 20][1] += s_
        worst = max(fr.values(), key=lambda x: x[1])
        print('  6502 waiting on the start latch (estimate): %d starts; %.0f / %.0f us per such start, worst frame %.0f / %.0f us (core-clock RAM / 2xPHI2 RAM)' % (
            len(m.spins), sum(x[1] for x in m.spins) / len(m.spins), sum(x[2] for x in m.spins) / len(m.spins), worst[0], worst[1]))
    if a.ref:
        ref = load_log(a.ref, a.frames)
        if a.ms: ref = [l for l in ref if l[0] < a.ms]
        eng_chip, _ = engine.expand(['%d %d %d' % l for l in ref])
        render(eng_chip, os.path.join(a.out, 'engine.wav'))
        def per_ms(cl):
            d = collections.defaultdict(collections.Counter)
            for t, r, v in cl: d[t][(r, v)] += 1
            return d
        x_, y_ = per_ms(chip), per_ms(eng_chip)
        ms = sorted(set(x_) | set(y_))
        same = sum(1 for t in ms if x_[t] == y_[t])
        print('  AMY writes: copper version %d, engine version %d; ms with writes %d, identical %d (%.1f%%)' % (
            len(chip), len(eng_chip), len(ms), same, 100.0 * same / len(ms)))
        for t in [t for t in ms if x_[t] != y_[t]][:3]:
            print('    %d ms: copper-only %s  engine-only %s' % (t, dict((x_[t] - y_[t]).most_common(4)), dict((y_[t] - x_[t]).most_common(4))))
        import wave, numpy as np
        def load(f):
            w = wave.open(f); return np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(float)
        x, y = load(os.path.join(a.out, 'copper.wav')), load(os.path.join(a.out, 'engine.wav'))
        n = min(len(x), len(y)); e = x[:n] - y[:n]
        print('  audio: rms copper %.0f engine %.0f, difference rms %.2f max %.0f (%d vs %d samples)' % (
            np.sqrt((x[:n] ** 2).mean()), np.sqrt((y[:n] ** 2).mean()), np.sqrt((e ** 2).mean()), np.abs(e).max(), len(x), len(y)))


if __name__ == '__main__':
    main()
