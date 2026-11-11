#!/usr/bin/env python3
"""engine.py - behavioural model of the AMY Rev C note engine (spec 6, 6.8)

Turns a register log ("ms reg value", registers 0-15) into the chip
writes the engine would make, merged with the host's own chip writes,
as a log of registers 0-7 for amy_model.py.

The arithmetic follows the RTL (amy1_engine.vhd) and its test model
(engmodel_x.py, checked against the RTL push for push).  Events are
processed at the time they are written; retriggers at
note + n x (period + 1) x 8 ms; the engine time unit is 8 ms.
"""
import sys


def sx(x, bits):
    return x - (1 << bits) if x & (1 << (bits - 1)) else x


class Engine:
    def __init__(self):
        self.w = [0, 0, 0]
        self.addr = 0
        self.config = 0
        self.ram = {}
        self.xram = {}
        self.ext = False            # chip extensions unlocked (amy1_top)
        self.key = False
        self.pfa = [0] * 64
        self.pfd = [0] * 64
        self.last = {}              # voice -> (lvl, hm) of its note
        self.pending = []           # [due_ms, voice]
        self.out = []               # (t, reg, val) chip writes
        self.pushes = []            # the engine's own, (t, reg, val)

    # ---- the host's register writes -----------------------------------
    def write(self, t, reg, val):
        self.run_due(t)
        if reg < 8:
            if reg == 7:
                if val == 0xA5: self.key = True
                elif val == 0x5A and self.key: self.ext = True; self.key = False
                elif val == 0x00: self.ext = False; self.key = False; self.pending = []
                else: self.key = False
            if reg == 0 and val < 8:
                self.ext = False; self.key = False
            self.out.append((t, reg, val))
            return
        r = reg - 8
        if r < 3:
            self.w[r] = val
        elif r == 3:
            if self.config & 1:
                self.event(t, self.w[0] | self.w[1] << 8 | self.w[2] << 16 | val << 24)
        elif r == 4:
            self.addr = val
        elif r == 5:
            word = self.w[0] | self.w[1] << 8 | self.w[2] << 16 | val << 24
            if self.config & 4:
                if self.addr < 128: self.xram[self.addr] = word
            elif self.addr >= 32:
                self.ram[self.addr] = word
        elif r == 7:
            self.config = val & 7

    def finish(self, t_end):
        self.run_due(t_end)
        return self.out

    def run_due(self, t):
        while self.pending:
            self.pending.sort()
            due, v = self.pending[0]
            if due > t:
                break
            self.pending.pop(0)
            self.job(due, ('rt', v))

    # ---- events ----------------------------------------------------------
    def event(self, t, word):
        op = word >> 28
        v = (word >> 24) & 7
        self.pending = [p for p in self.pending if p[1] != v]
        if op == 9:
            self.job(t, ('on', v, word & 127, (word >> 8) & 255, (word >> 16) & 31))
        elif op == 8:
            self.job(t, ('off', v))
        elif op == 10:
            self.job(t, ('inst', v, word & 15))

    def push(self, t, *pairs):
        for r, x in pairs:
            self.out.append((t, r, x))
            self.pushes.append((t, r, x))

    def job(self, t, job):
        xen = self.ext
        hpv8 = bool(self.config & 2)
        hpv = 8 if hpv8 else 16
        kind, v = job[0], job[1]
        hb = v * hpv
        ram = self.ram
        vs = ram.get(32 + v, 0)
        now = (t // 8) & 255
        if kind == 'inst':
            i = job[2]
            if xen:
                xh = self.xram.get(i, 0)
                self.push(t, (1, xh & 3), (0, 0x10 + v))
                self.push(t, (1, v), (3, (xh >> 8) & 255), (0, 0x34))
                for k in range(hpv):
                    h = hb + k
                    hw = (self.xram.get(32 + 8 * i + (k >> 1), 0) >> (16 * (k & 1))) & 0xFFFF
                    self.pfa[h] = (hw >> 14) & 1; self.pfd[h] = (hw >> 15) & 1
                    self.push(t, (1, 0), (3, 0), (0, 0x40 + h))
                    self.push(t, (1, h), (3, hw & 63), (0, 0x35))
                    self.push(t, (1, h), (3, (hw >> 8) & 63), (0, 0x36))
            ram[32 + v] = (i & 15) | (1 << 4) | (now << 8) | (((vs >> 24) & 127) << 24)
            return
        inst = vs & 15
        xh = self.xram.get(inst, 0) if xen else 0
        if kind == 'on':
            note, lvl, hm = job[2] & 127, job[3], job[4] & 31
            self.last[v] = (lvl, hm)
        elif kind == 'rt':
            if not xen:
                return
            note = (vs >> 24) & 127
            lvl, hm = self.last[v]
        else:
            note = (vs >> 24) & 127
            lvl, hm = 0, 0
        legato = not (vs >> 4) & 1
        age = (now - ((vs >> 8) & 255)) & 255
        ceil = (vs >> 16) & 255
        hdr = ram.get(48 + inst, 0)
        rel = hdr & 255
        d = (hdr >> 16) & 31
        x = lvl - ceil
        n = age
        while x < 8 and not legato and n != 0:
            x += d; n -= 1
        rise = x >= 8
        cnew = lvl if (kind != 'off' and x >= 0) else (lvl - x) & 255
        B = [(2, 0)] if xen else []
        if kind == 'off':
            for k in range(hpv):
                self.push(t, (1, rel), (2, 0), (3, 0), (0, 0x40 + hb + k)) if xen else \
                    self.push(t, (1, rel), (3, 0), (0, 0x40 + hb + k))
            ram[32 + v] = inst | (1 << 4) | (now << 8) | (cnew << 16) | (note << 24)
            return
        if kind == 'on':
            up = note > ((vs >> 24) & 127)
            glide = 0
            if legato:
                glide = (hdr >> 8) & 255 if up else (hdr >> 24) & 255
            f = (ram.get(40, 0) + note * 64) & 0x1FFF
            off = sx((xh >> 16) & 255, 8)
            if off:
                s = min(8191, max(0, f + 16 * off))
                self.push(t, (1, 0), (2, s >> 8), (3, s & 255), (0, 0x08 + v))
                self.push(t, (1, (xh >> 24) & 255), (2, 0x80 | (f >> 8)), (3, f & 255), (0, 0x08 + v))
            else:
                self.push(t, (1, glide), (2, f >> 8), (3, f & 255), (0, 0x08 + v))
        decay = (hdr >> 23) & 1
        for pas in (0, 1) if decay else (0,):
            for k in range(hpv):
                h = hb + k
                wd = ram.get(((inst + 4) & 15) * 16 + k, 0)
                lo, atk, dec, sus = wd & 255, (wd >> 8) & 255, (wd >> 16) & 255, (wd >> 24) & 255
                p = lvl - lo
                inn = k < hm and lo != 255 and p > 0
                if pas == 0:
                    if inn:
                        b = 0x80 if (xen and rise and self.pfa[h]) else 0
                        a = atk if rise else 0
                        self.push(t, (1, a), *([(2, b)] if xen else []), (3, p), (0, 0x40 + h))
                    else:
                        self.push(t, (1, rel), *B, (3, 0), (0, 0x40 + h))
                else:
                    if inn and (not rise or atk == 0):
                        b = 0x80 if (xen and self.pfd[h]) else 0
                        self.push(t, (1, dec), *([(2, b)] if xen else []), (3, max(0, p - sus)), (0, 0x40 + h))
        ram[32 + v] = inst | (0 << 4) | (now << 8) | (cnew << 16) | (note << 24)
        if kind == 'on' and xen:
            cnt, per = (xh >> 4) & 15, (xh >> 2) & 3
            for j in range(1, cnt + 1):
                self.pending.append([t + j * 8 * (per + 1), v])


def expand(log_lines):
    eng = Engine()
    t = 0
    for line in log_lines:
        f = line.split()
        if len(f) != 3:
            continue
        t, reg, val = int(f[0]), int(f[1]), int(f[2])
        eng.write(t, reg, val)
    return eng.finish(t + 10_000), eng


if __name__ == '__main__':
    out, _ = expand(open(sys.argv[1]))
    with open(sys.argv[2], 'w') as f:
        for t, r, v in out:
            f.write('%d %d %d\n' % (t, r, v))
    print('%s: %d chip writes' % (sys.argv[2], len(out)))
