#!/usr/bin/env python3
"""py65: amyconv's OPTION handler (set_mode).  Locking writes $00 to $D2C7, puts the original
noise voice types back with raw $10+v commands, then re-selects each voice's instrument;
unlocking writes $A5,$5A, EXT_RESET, then the selects.  usage: test_mode.py xex lbl"""
import sys, os, re
H = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, H); sys.path.insert(0, os.path.join(H, '..', 'vbi'))
import bench as vb
import instruments as I
lbl = {m.group(2): int(m.group(1), 16) for m in re.finditer(r'al 00([0-9A-F]{4}) \.(\w+)', open(sys.argv[2]).read())}
rig = vb.Rig(sys.argv[1]); base = 0x2E00
w = []
orig = rig.wr
def wr(a, v):
    orig(a, v); w.append((a - vb.AMY, v))
rig.mem.subscribe_to_write(range(vb.AMY, vb.AMY + 16), wr)
rig.call(base + 3); rig.call(base + 6); rig.call(base + 9, 0)
for f in range(5): rig.call(base + 12)
vinst = [rig.mem[lbl['vinst'] + v] for v in range(8)]
ok = True
for mode in (0, 1):
    rig.mem[lbl['revc']] = mode; w.clear()
    rig.call(lbl['set_mode'])
    ev = [(v, rig.regs[8]) for r, v in w if r == 11]
    sel = [(e & 7, x) for e, x in [(v, None) for r, v in w if r == 11]]
    got_sel = [x for r, x in w if r == 11]
    if mode == 0:
        want_pre = [(7, 0)] + sum([[(1, I.VOICE_TYPE[v]), (0, 0x10 + v)] for v in range(8)], [])
    else:
        want_pre = [(7, 0xA5), (7, 0x5A), (1, 0), (2, 0), (3, 0), (0, 0x39)]
    pre = [x for x in w if x[0] < 8 and x[0] not in (4, 5, 6)]
    sels = [x for x in w if x[0] == 11]
    w0 = [x[1] for x in w if x[0] == 8]
    good = pre == want_pre and [s for _, s in sels] == [0xA0 + v for v in range(8)] and w0 == vinst
    print('Rev C %s: chip writes %s, selects %s, instruments %s: %s' % (
        'on ' if mode else 'off', pre if len(pre) < 8 else '%d (lock + 8 voice types)' % len(pre),
        [hex(s) for _, s in sels][:2] + ['...'], vinst, 'OK' if good else 'WRONG'))
    ok &= good
print('MODE', 'PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
