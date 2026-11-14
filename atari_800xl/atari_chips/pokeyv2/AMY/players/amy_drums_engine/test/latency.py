#!/usr/bin/env python3
"""Engine latency on the full RTL (amy1_top, 8.192 MHz, ENGINE): the
drum program's set-up from its log, then one busy step (kick, snare,
wires, closed hat with its note-off, clap) written at once.  Reports
how long after the step's first EVENT write each event's last chip
write lands.  usage: latency.py amy_log.txt workdir"""
import sys, os, subprocess
log, wd = sys.argv[1], sys.argv[2]
lines = [tuple(map(int, l.split())) for l in open(log) if l.strip()]
first_ev = next(i for i, (t, r, v) in enumerate(lines) if r == 11 and v >= 0x90 and v < 0xA0)
setup = lines[:first_ev]
US = 200
t = 2000; c = []
for _, r, v in setup:
    c.append((t, r if r < 8 else 16 + r, v)); t += 10 * US
t0 = t + 2000 * US                       # 2 ms of quiet
t = t0
def ev(b3, w0=0, w1=0, w2=0):
    global t
    for r, v in ((8, w0), (9, w1), (10, w2), (11, b3)):
        c.append((t, 16 + r, v)); t += 3 * US
step = [(0x90 | 0, 3, 0xFF, 8), (0x90 | 1, 13, 0xFF, 8), (0x90 | 2, 53, 0xFF, 8),
        (0x90 | 3, 61, 0xFF, 8), (0x80 | 3,), (0x90 | 5, 33, 0xFF, 8)]
for e in step:
    ev(*e)
stop = t0 + 40000 * US
open(os.path.join(wd, 'lat_cmds.txt'), 'w').write(''.join('%d %d %d\n' % x for x in c))
r = subprocess.run(['ghdl', '--elab-run', '--std=08', '-frelaxed', 'tb_top', '-gENGINE=true',
                    '-gSTEP_NUM=3', '-gSTEP_DEN=7', '-gUNIT_LOG2=15',
                    '-gCMD_FILE=lat_cmds.txt', '-gCHIP_FILE=lat_chip.txt', '-gOUT_FILE=lat_samp.txt',
                    '-gPCM_FILE=lat_pcm.txt', '-gREAD_FILE=lat_reads.txt', '-gSTOP=%d' % stop,
                    '-gMEM_FILE=amy1_mem.hex'], cwd=wd, capture_output=True, text=True)
if r.returncode:
    print(r.stdout[-500:], r.stderr[-500:])
W = []
for l in open(os.path.join(wd, 'lat_chip.txt')):
    f = l.split()
    if f[0] == 'W':
        W.append((int(f[1]), int(f[2]), int(f[3])))
S = [int(l.split()[1]) for l in open(os.path.join(wd, 'lat_chip.txt')) if l.startswith('S')]
per = sorted(b - a for a, b in zip(S, S[1:]))[len(S) // 2]       # tb steps per sample
# the chip-write log is in tb steps; samples are 31.25 us
after = [w for w in W if w[0] >= 0]
cmds = [(s, v) for s, r, v in W if r == 0]
# commands of the step: everything after the last set-up command (select pushes end before t0)
t0_step = None
ser = []
for s, v in cmds:
    ser.append((s, v))
# find the step: the first FFBP $08 (kick note-on) after set-up
k = next(i for i, (s, v) in enumerate(ser) if v == 0x08)
base = ser[k][0]
last = {}
for s, v in ser[k:]:
    grp = {0x08: 'kick', 0x09: 'snare', 0x0A: 'wires', 0x0B: 'hat', 0x0D: 'clap'}.get(v)
    if 0x40 <= v < 0x80:
        grp = ['kick', 'snare', 'wires', 'hat', 'metal', 'clap', 'tom', 'rim'][(v & 63) >> 3]
    if grp:
        last[grp] = s
print('step written over %.0f us; samples every %d steps' % ((t - t0) / US, per))
for g in ('kick', 'snare', 'wires', 'hat', 'clap'):
    if g in last:
        print('  %-6s last write %.2f ms after the kick\'s first' % (g, (last[g] - base) / per * 31.25 / 1000))
print('  chip commands in the step (incl. clap retriggers): %d' % (len(ser) - k))
