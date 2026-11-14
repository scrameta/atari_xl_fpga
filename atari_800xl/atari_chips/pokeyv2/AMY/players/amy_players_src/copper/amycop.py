#!/usr/bin/env python3
"""amycop.py - the AMY note engine as one generic copper++ program (copper_spec.md v0.7: it needs
the register bus to hold AMY writes while AMY's FIFO is full, so it never polls AMY).

The program doesn't depend on the instruments: it reads them from tables built from the
engine's own RAM image (the words a player used to upload to the engine), so a player keeps
its instrument data and the 6502 only changes how it sends events.

One copper start per engine event, on the voice's thread (thread v = voice v), or one for two
events on the same voice in a row (the combined entries, so the 6502 doesn't wait for the copper
to finish the first before it can send the second):
  note on   params R0 note, R1 level, R2 harmonics (band limit)      entry ON(instrument)
  note off  no params                                                 entry OFF(instrument)
  select    no params                                                 entry SEL(instrument)
  select, then note on      params as ON                              entry SELON(instrument)
  note on, then note off    params as ON                              entry ONOFF(instrument)
  note on, then a second    params as ON, R3 note 2, R4 level 2       entry ON2(instrument)
    note on (legato)        (the same harmonics)
  note off, then note on    params as ON                              entry OFFON(instrument)
  vinit     R0 = harmonics per voice x v, R1 = v (once, at start)     entry VINIT
  cut       every harmonic of the voice jumps to 0                     entry CUT
  vib       R0 = frequency low, R1 = high: a frequency jump            entry VIB
The entry's instrument is the voice's current one (the 6502 keeps track of it, as the
engine did). The entries are 5-byte stubs, two pages per Rev C mode: extensions on STUBS
(sel, on, off, vinit, cut, vib) and STUBS + $100 (the combined ones), off STUBS + $200 and
+ $300. A start needs the parameters, CADDRL and CSTART, and CADDRH when the page changes.
CBASE is $C0 (AMY) for every start.

Layout in sample RAM: STUBS ($E000, four pages), tables, then the code. 1 tick = 1 ms
(CTICK = 16 scanlines; retriggers and the release ceiling's decay count 8-tick steps)."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from copper import Asm

# registers (per thread)
R_NOTE, R_LVL, R_HM = 0, 1, 2            # a note on's parameters
R_N2, R_L2 = 3, 4                        # ON2: the second note's (then free: the retrigger counters)
R_CNT, R_T3 = 3, 4
R_RISE, R_T, R_K, R_IX, R_T2 = 5, 6, 7, 8, 9
R_I8, R_HB, R_V = 10, 11, 12             # instrument x harmonics per voice; voice constants
R_CEIL, R_OLD, R_REL = 13, 14, 15        # the voice's state between starts

STUBS = 0xE000
TABLES = 0xE400
OPS = ('sel', 'on', 'off')
COMBOS = ('selon', 'onoff', 'on2', 'offon')
PI_FIELDS = ('rel', 'dcy', 'drop', 'vty', 'trim', 'gup', 'gdown', 'rate', 'offf', 'olo', 'ohi', 'cnt', 'per')


def sx8(x): return x - 256 if x & 128 else x


class CopperAmy:
    def __init__(self, ram, xram, hpv=8, ninst=12):
        self.ram, self.xram, self.hpv, self.ninst = ram, xram, hpv, ninst
        self.tables = bytearray()
        self.T = {}
        self._tables()
        self.a = Asm(TABLES + len(self.tables))
        self.n = 0
        self._code()
        self._stubs()

    # ------------------------------------------------------------------ tables
    def table(self, name, data):
        self.T[name] = TABLES + len(self.tables)
        self.tables += bytes(data)

    def inst(self, i):
        hpv = self.hpv
        hdr = self.ram.get(48 + i, 0)
        harm = [self.ram.get(((i + 4) & 15) * 16 + k, 0) for k in range(hpv)]
        xh = self.xram.get(i, 0)
        co = []
        for k in range(hpv):
            hw = (self.xram.get(32 + 8 * i + (k >> 1), 0) >> (16 * (k & 1))) & 0xFFFF
            co.append(dict(det=hw & 63, sto=(hw >> 8) & 63, pfa=(hw >> 14) & 1, pfd=(hw >> 15) & 1))
        off = sx8((xh >> 16) & 255)
        o16 = (16 * off) & 0xFFFF
        return dict(rel=hdr & 255, gup=(hdr >> 8) & 255, drop=(hdr >> 16) & 31, dcy=(hdr >> 23) & 1,
                    gdown=(hdr >> 24) & 255, vty=xh & 3, per=(xh >> 2) & 3, cnt=(xh >> 4) & 15,
                    trim=(xh >> 8) & 255, offf=1 if off else 0, olo=o16 & 255, ohi=o16 >> 8,
                    rate=(xh >> 24) & 255,
                    h=[dict(lo=x & 255, atk=(x >> 8) & 255, dec=(x >> 16) & 255, sus=(x >> 24) & 255) for x in harm],
                    co=co)

    def _tables(self):
        hpv, n = self.hpv, self.ninst
        I = [self.inst(i) for i in range(n)]
        self.I = I
        f0 = self.ram.get(40, 0)
        f = [(f0 + k * 64) & 0x1FFF for k in range(128)]
        self.table('flo', [x & 255 for x in f])
        self.table('fhi', [x >> 8 for x in f])
        self.table('fhi80', [0x80 | (x >> 8) for x in f])
        def per_h(name, g):
            self.table(name, [g(I[i], k) & 255 for i in range(n) for k in range(hpv)])
        per_h('lo', lambda x, k: x['h'][k]['lo'])
        per_h('atk', lambda x, k: x['h'][k]['atk'])
        per_h('dec', lambda x, k: x['h'][k]['dec'])
        per_h('losus', lambda x, k: min(255, x['h'][k]['lo'] + x['h'][k]['sus']))
        per_h('pfa', lambda x, k: 0x80 * x['co'][k]['pfa'])
        per_h('pfd', lambda x, k: 0x80 * x['co'][k]['pfd'])
        per_h('det', lambda x, k: x['co'][k]['det'])
        per_h('sto', lambda x, k: x['co'][k]['sto'])
        # per instrument: packed, field f at slot f % hpv of block f // hpv (index 8 i or 16 i)
        nb = (len(PI_FIELDS) + hpv - 1) // hpv
        base = TABLES + len(self.tables)
        blk = bytearray(nb * n * hpv)
        for fi, name in enumerate(PI_FIELDS):
            b, s = divmod(fi, hpv)
            self.T[name] = base + b * n * hpv + s
            for i in range(n):
                blk[b * n * hpv + i * hpv + s] = I[i][name] & 255
        self.tables += blk

    # ------------------------------------------------------------------ code
    def L(self, s):
        self.n += 1; return '%s_%d' % (s, self.n)

    def cmd_start(self):                 # a command is not interrupted; a write waits while AMY's FIFO is full
        a = self.a; a.lock()

    def hcmd(self):                      # command $40 + HB + K
        a = self.a; a.ldr(R_HB); a.addr(R_K); a.add(0x40); a.mova(0); a.unlock()

    def fcmd(self):                      # command $08 + V
        a = self.a; a.ldr(R_V); a.add(0x08); a.mova(0); a.unlock()

    def kloop(self, body):
        a = self.a; lp = self.L('k')
        a.lda(0); a.sta(R_K)
        a.label(lp)
        a.ldr(R_I8); a.addr(R_K); a.sta(R_IX)
        body()
        a.ldr(R_K); a.add(1); a.sta(R_K); a.sub(self.hpv); a.jnz(lp)

    def release(self, xen):
        a = self.a; T = self.T
        self.cmd_start(); a.ldr(R_I8); a.ldt(T['rel']); a.mova(1)
        if xen: a.move(2, 0)
        a.move(3, 0); self.hcmd()

    def _code(self):
        a = self.a; T = self.T
        # shared subroutines
        a.label('rise')                  # RISE = level >= ceiling + 8
        nr = self.L('nr'); rd = self.L('rd')
        a.ldr(R_CEIL); a.add(8); a.jc(nr); a.sta(R_T)
        a.ldr(R_LVL); a.subr(R_T); a.jc(nr)
        a.lda(1); a.sta(R_RISE); a.ret()
        a.label(nr); a.lda(0); a.sta(R_RISE); a.ret()

        a.label('vinit')
        a.ldr(0); a.sta(R_HB); a.ldr(1); a.sta(R_V)
        a.lda(0); a.sta(R_CEIL); a.sta(R_OLD); a.lda(1); a.sta(R_REL); a.stop()

        a.label('cut')
        def cutb():
            self.cmd_start(); a.move(1, 0); a.move(2, 0); a.move(3, 0); self.hcmd()
        self.kloop(cutb); a.stop()

        a.label('vib')
        self.cmd_start(); a.move(1, 0); a.ldr(1); a.mova(2); a.ldr(0); a.mova(3); self.fcmd(); a.stop()

        for xen in (True, False):
            x = 'x' if xen else 'l'
            # ---- the bodies (subroutines) and their tails
            a.label('selb_' + x)
            if xen:
                self.cmd_start(); a.ldr(R_I8); a.ldt(T['vty']); a.mova(1); a.ldr(R_V); a.add(0x10); a.mova(0); a.unlock()
                self.cmd_start(); a.ldr(R_V); a.mova(1); a.ldr(R_I8); a.ldt(T['trim']); a.mova(3); a.move(0, 0x34); a.unlock()
                def selb():
                    self.cmd_start(); a.move(1, 0); a.move(3, 0); self.hcmd()
                    self.cmd_start(); a.ldr(R_HB); a.addr(R_K); a.mova(1); a.ldr(R_IX); a.ldt(T['det']); a.mova(3); a.move(0, 0x35); a.unlock()
                    self.cmd_start(); a.ldr(R_HB); a.addr(R_K); a.mova(1); a.ldr(R_IX); a.ldt(T['sto']); a.mova(3); a.move(0, 0x36); a.unlock()
                self.kloop(selb)
            a.lda(1); a.sta(R_REL); a.lda(0); a.sta(R_CEIL); a.ret()

            a.label('onb_' + x)                                  # note on: rise, pitch, the harmonics
            a.call('rise'); a.call('freq_' + x); a.jump('harm_' + x)

            a.label('offb_' + x)                                 # note off
            self.kloop(lambda: self.release(xen))
            a.lda(1); a.sta(R_REL); a.ret()

            a.label('rt_' + x)                                   # after a note on: with Rev C its retriggers
            if xen:
                rl = self.L('rl'); wl = self.L('wl')
                a.ldr(R_I8); a.ldt(T['cnt']); a.jz('stop'); a.sta(R_CNT)
                a.label(rl)
                a.ldr(R_I8); a.ldt(T['per']); a.add(1); a.sta(R_T3)
                a.label(wl); a.wait(8); a.djnz(wl, R_T3)
                a.call('rise'); a.call('harm_' + x)
                a.djnz(rl, R_CNT)
            a.stop()

            a.label('dk_' + x)                                   # after a note off: the ceiling falls by the drop every 8 ms
            lp = self.L('dk'); z = self.L('z')
            a.label(lp); a.ldr(R_I8); a.ldt(T['drop']); a.jz('stop'); a.sta(R_T)
            a.wait(8); a.ldr(R_CEIL); a.subr(R_T); a.jc(z); a.jz(z); a.sta(R_CEIL); a.jump(lp)
            a.label(z); a.lda(0); a.sta(R_CEIL); a.stop()

            # ---- the entries (the stub leaves 8 x instrument in ACC)
            a.label('sel_' + x); a.sta(R_I8); a.call('selb_' + x); a.stop()
            a.label('on_' + x); a.sta(R_I8); a.call('onb_' + x); a.jump('rt_' + x)
            a.label('off_' + x); a.sta(R_I8); a.call('offb_' + x); a.jump('dk_' + x)
            a.label('selon_' + x); a.sta(R_I8); a.call('selb_' + x); a.call('onb_' + x); a.jump('rt_' + x)
            a.label('onoff_' + x); a.sta(R_I8); a.call('onb_' + x); a.call('offb_' + x); a.jump('dk_' + x)
            a.label('offon_' + x); a.sta(R_I8); a.call('offb_' + x); a.call('onb_' + x); a.jump('rt_' + x)
            a.label('on2_' + x); a.sta(R_I8); a.call('onb_' + x)
            a.ldr(R_N2); a.sta(R_NOTE); a.ldr(R_L2); a.sta(R_LVL)
            a.call('onb_' + x); a.jump('rt_' + x)

            # ---- the pitch
            a.label('freq_' + x)
            if xen:
                op = self.L('op'); a.ldr(R_I8); a.ldt(T['offf']); a.jnz(op)
            g0 = self.L('g0'); gu = self.L('gu'); gd = self.L('gd'); fe = self.L('fe')
            self.cmd_start()
            a.ldr(R_REL); a.jnz(g0); a.ldr(R_OLD); a.subr(R_NOTE); a.jc(gu)
            a.ldr(R_I8); a.ldt(T['gdown']); a.jump(gd)
            a.label(gu); a.ldr(R_I8); a.ldt(T['gup']); a.jump(gd)
            a.label(g0); a.lda(0)
            a.label(gd); a.mova(1)
            a.ldr(R_NOTE); a.ldt(T['fhi']); a.mova(2); a.ldr(R_NOTE); a.ldt(T['flo']); a.mova(3); self.fcmd()
            a.label(fe); a.ldr(R_NOTE); a.sta(R_OLD); a.ret()
            if xen:
                # pitch offset: a jump to f + 16 off (clamped to 0..8191), then glide to f at the rate
                nc = self.L('nc'); cc = self.L('cc'); ok = self.L('ok'); big = self.L('big')
                a.label(op)
                a.ldr(R_NOTE); a.ldt(T['flo']); a.sta(R_T)
                a.ldr(R_I8); a.ldt(T['olo']); a.addr(R_T); a.sta(R_T)            # low byte, C = carry
                a.jnc(nc); a.lda(1); a.jump(cc)
                a.label(nc); a.lda(0)
                a.label(cc); a.sta(R_T2)
                a.ldr(R_NOTE); a.ldt(T['fhi']); a.addr(R_T2); a.sta(R_T2)
                a.ldr(R_I8); a.ldt(T['ohi']); a.addr(R_T2); a.sta(R_T2)          # high byte, signed
                a.sub(0x20); a.jc(ok)                                             # 0..$1FFF
                a.ldr(R_T2); a.sub(0x80); a.jc(big)
                a.lda(0); a.sta(R_T); a.sta(R_T2); a.jump(ok)                     # below 0
                a.label(big); a.lda(0xFF); a.sta(R_T); a.lda(0x1F); a.sta(R_T2)  # above 8191
                a.label(ok)
                self.cmd_start(); a.move(1, 0); a.ldr(R_T2); a.mova(2); a.ldr(R_T); a.mova(3); self.fcmd()
                self.cmd_start(); a.ldr(R_I8); a.ldt(T['rate']); a.mova(1)
                a.ldr(R_NOTE); a.ldt(T['fhi80']); a.mova(2); a.ldr(R_NOTE); a.ldt(T['flo']); a.mova(3); self.fcmd()
                a.jump(fe)

            # ---- the harmonics: ceiling, attack pass, decay pass
            a.label('harm_' + x)
            keep = self.L('keep')
            a.ldr(R_LVL); a.subr(R_CEIL); a.jc(keep); a.ldr(R_LVL); a.sta(R_CEIL)
            a.label(keep); a.lda(0); a.sta(R_REL)
            def atk():
                rel = self.L('ar'); nxt = self.L('an'); jmp = self.L('aj'); com = self.L('ac')
                a.ldr(R_HM); a.subr(R_K); a.jc(rel); a.jz(rel)                 # harmonics <= k
                a.ldr(R_IX); a.ldt(T['lo']); a.sta(R_T)
                a.ldr(R_LVL); a.subr(R_T); a.jc(rel); a.jz(rel); a.sta(R_T)     # level - offset > 0
                self.cmd_start()
                a.ldr(R_RISE); a.jz(jmp)
                a.ldr(R_IX); a.ldt(T['atk']); a.mova(1)
                if xen: a.ldr(R_IX); a.ldt(T['pfa']); a.mova(2)
                a.jump(com)
                a.label(jmp); a.move(1, 0)
                if xen: a.move(2, 0)
                a.label(com); a.ldr(R_T); a.mova(3); self.hcmd(); a.jump(nxt)
                a.label(rel); self.release(xen)
                a.label(nxt)
            self.kloop(atk)
            nod = self.L('nod')
            a.ldr(R_I8); a.ldt(T['dcy']); a.jz(nod)
            def dec():
                nxt = self.L('dn'); okk = self.L('dk'); go = self.L('dg')
                a.ldr(R_HM); a.subr(R_K); a.jc(nxt); a.jz(nxt)
                a.ldr(R_IX); a.ldt(T['atk']); a.jz(go)                          # attack 0: always
                a.ldr(R_RISE); a.jnz(nxt)                                        # after a rising attack: none
                a.label(go)
                a.ldr(R_IX); a.ldt(T['lo']); a.sta(R_T)
                a.ldr(R_LVL); a.subr(R_T); a.jc(nxt); a.jz(nxt)
                a.ldr(R_IX); a.ldt(T['losus']); a.sta(R_T)                       # max(0, level - (offset + sustain))
                a.ldr(R_LVL); a.subr(R_T); a.jnc(okk); a.lda(0)
                a.label(okk); a.sta(R_T)
                self.cmd_start(); a.ldr(R_IX); a.ldt(T['dec']); a.mova(1)
                if xen: a.ldr(R_IX); a.ldt(T['pfd']); a.mova(2)
                a.ldr(R_T); a.mova(3); self.hcmd()
                a.label(nxt)
            self.kloop(dec)
            a.label(nod); a.ret()
        a.label('stop'); a.stop()
        self.code = a.bytes()

    # ------------------------------------------------------------------ entries
    def _stubs(self):
        """four pages of stubs, LDA #I8 ; JUMP op (the op stores ACC to I8): per mode, the
        single events and the fixed entries, then the combined events"""
        self.entry = {}
        pages = bytearray(1024)
        for m, xen in enumerate((True, False)):
            x = 'x' if xen else 'l'
            for g, ops in enumerate((OPS, COMBOS)):
                p = 2 * m + g
                s = Asm(STUBS + 256 * p)
                if g == 0:
                    for name in ('vinit', 'cut', 'vib'):
                        self.entry[(name, xen)] = s.here(); s.jump(self.a.labels[name])
                for op in ops:
                    for i in range(self.ninst):
                        self.entry[(op, i, xen)] = s.here()
                        s.lda(i * self.hpv); s.jump(self.a.labels['%s_%s' % (op, x)])
                b = s.bytes(); assert len(b) <= 256, len(b)
                pages[256 * p:256 * p + len(b)] = b
        self.stubs = bytes(pages)

    def image(self):
        """(address, bytes): one block, STUBS up to the end of the code"""
        end = TABLES + len(self.tables) + len(self.code)
        assert end <= 0xFE00, 'runs into the context area'
        return STUBS, self.stubs + bytes(self.tables) + self.code

    def entry_lo(self, op, i):
        """CADDRL of an entry (the same in both pages)"""
        return self.entry[(op, i, True)] & 255


if __name__ == '__main__':
    c = CopperAmy({40: 2418}, {}, int(sys.argv[1]) if len(sys.argv) > 1 else 8)
    base, img = c.image()
    print('code %d bytes, tables %d bytes, image %d bytes at $%04X' % (len(c.code), len(c.tables), len(img), base))
