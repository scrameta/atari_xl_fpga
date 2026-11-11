#!/usr/bin/env python3
"""Run the drum log's engine writes through the RTL engine (tb_engine) and
compare every push with tools/engine.py.

usage: rtl_engine.py amy_log.txt tb_workdir [end_ms]
The run starts at the drum program's set-up (the unlock with Rev C on, the
core reset with it off) and goes to the end of the log, or end_ms.
tb_engine ticks every clock with a unit of 2^14 clocks, so 1 ms = 2048
clocks keeps the engine's 8 ms unit."""
import sys, os, subprocess
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
import engine

log, wd = sys.argv[1], sys.argv[2]
end_ms = int(sys.argv[3]) if len(sys.argv) > 3 else None
lines = [tuple(map(int, l.split())) for l in open(log) if l.strip()]
unlocks = [i for i, (t, r, v) in enumerate(lines) if r == 7 and v == 0x5A]
resets = [i for i, (t, r, v) in enumerate(lines) if r == 0 and v < 8]
ext = bool(unlocks)
a = unlocks[0] if ext else resets[0]
b = next((i for i in resets if i > a), len(lines))
if end_ms:
    b = min(b, next((i for i in range(a, len(lines)) if lines[i][0] > end_ms), len(lines)))
segn = 1 if ext else 2
# the model runs over the whole log up to the segment's end (state carries
# over, as in the chip); only the segment's pushes are compared
eng = engine.Engine()
for t, r, v in lines[:b]:
    eng.write(t, r, v)
t_end = lines[b - 1][0] + 200
eng.finish(t_end)
t_a = lines[a][0]
exp = [(r, v) for t, r, v in eng.pushes if t_a <= t < t_end]
cmds = []; cur = t_a * 2048 - 100
for t, r, v in lines[a:b]:
    if r < 8:
        continue
    d = max(8, t * 2048 - cur)
    cmds.append((d, r - 8, v)); cur += d
cmds.append(((t_end - lines[b - 1][0]) * 2048, 6, 0))
tag = 'seg%d' % segn
open(os.path.join(wd, tag + '_cmds.txt'), 'w').write(''.join('%d %d %d\n' % c for c in cmds))
for x in ('_out.txt', '_now.txt'):
    p = os.path.join(wd, tag + x)
    if os.path.exists(p):
        os.remove(p)
r = subprocess.run(['ghdl', '--elab-run', '--std=08', 'tb_engine', '-gCMD_FILE=%s_cmds.txt' % tag,
                    '-gOUT_FILE=%s_out.txt' % tag, '-gNOW_FILE=%s_now.txt' % tag,
                    '-gEXT=' + ('true' if ext else 'false')],
                   cwd=wd, capture_output=True, text=True)
if r.returncode:
    print(r.stdout[-600:], r.stderr[-600:])
got = [tuple(map(int, l.split())) for l in open(os.path.join(wd, tag + '_out.txt'))]
first = next((i for i, (x, y) in enumerate(zip(got, exp)) if x != y), None)
ok = got == exp
print('segment %d (%s, %.1f-%.1f s): RTL engine %d pushes, model %d, %s%s' % (
    segn, 'unlocked' if ext else 'locked', t_a / 1000, t_end / 1000, len(got), len(exp),
    'IDENTICAL' if ok else 'DIFFER',
    '' if ok or first is None else ' at %d: %s vs %s' % (first, got[first:first + 6], exp[first:first + 6])))
sys.exit(0 if ok else 1)
