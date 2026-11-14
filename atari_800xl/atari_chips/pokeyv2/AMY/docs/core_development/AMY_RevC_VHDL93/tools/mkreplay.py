#!/usr/bin/env python3
"""mkreplay.py <prefix>: phase-A schedule (<prefix>_sched.txt, <prefix>_busy.txt) ->
<prefix>_replay.txt for tb_amy1b: lines 'n W reg data' (write in chip clock n),
'n D reg' (read), and 'r R' (the core's reset ends in clock r).
A command is written two clocks before the clock its busy started in phase A, with the
value phase A executed: the last command written up to that clock (a command written
while the previous one was still waiting for its busy replaced it, as on the chip)."""
import sys
p = sys.argv[1]
cs, ws, ds = [], [], []
for l in open(p + '_sched.txt'):
    f = l.split()
    if f[0] == 'C': cs.append((int(f[1]), int(f[2], 16)))
    elif f[0] == 'W': ws.append((int(f[1]), int(f[2]), int(f[3], 16)))
    elif f[0] == 'D': ds.append((int(f[1]), int(f[2])))
bs, rclk = [], None
for l in open(p + '_busy.txt'):
    f = l.split()
    if f[0] == 'B': bs.append(int(f[1]))
    else: rclk = int(f[1])
acts = []
replaced = 0
for b in bs:
    prior = [c for c in cs if c[0] <= b]
    if not prior:
        continue                      # power-up busy, no command
    acts.append((b - 2, 1, 'W', 0, prior[-1][1]))
used = set()
for b in bs:
    prior = [c for c in cs if c[0] <= b]
    if prior: used.add(prior[-1])
replaced = len([c for c in cs if c not in used and c[0] <= (bs[-1] if bs else 0)])
for n, r, d in ws: acts.append((n, 0, 'W', r, d))
for n, r in ds: acts.append((n, 2, 'D', r, 0))
acts.sort()
with open(p + '_replay.txt', 'w') as fo:
    fo.write(f'{rclk} R\n')
    for n, _, k, r, d in acts:
        fo.write(f'{n} {k} {r} {d}\n')
print(f'{len(bs)} commands executed, {replaced} replaced before execution, '
      f'{len(ws)} register writes, {len(ds)} reads')
