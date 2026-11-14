#!/usr/bin/env python3
"""copper.py - behavioural model of the PokeyMAX copper (copper_spec.md v0.7), and a small
assembler. The model follows copper.vhd's scheduling (round robin, 16-instruction
slices, tail calls, starts served between instructions), so the two give the same register
writes in the same order.

Model.run(events, ticks) -> list of (tick, addr, data) register writes.
events: {tick: [('start', t, addr, base[, params]) | ('kill', mask) | ('ctrl', CCTRL)]}, applied after that
tick's pass. A start goes through the host's start latch: it is served when thread t is at
rest (stopped, or waiting at a WAIT), in the order the starts were made; the 6502 waits for
the latch to be free (CCTRL bit 6) before setting up the next one, which the queue models.

copper++ (per thread: ACC, carry C, R0-R15 in the context area; Z means ACC = 0):
  F0 r      MOVA r        register base+r <= ACC
  F1 n      STA Rn        Rn = ACC
  F2 v      LDA #v        ACC = v
  F3 n      LDA Rn        ACC = Rn
  F4 v      ADD #v        ACC += v, C = carry out
  F5 n      ADD Rn
  F6 v      SUB #v        ACC -= v, C = borrow (ACC was < v)
  F7 n      SUB Rn
  F8 lo hi  LDT addr      ACC = RAM[addr + ACC]
  F9 lo hi  JZ addr       (ACC = 0)    FA JNZ    FB JC    FC JNC
  FD lo hi n DJNZ addr,Rn Rn -= 1; jump if Rn != 0
  C1        LOCK          the slice doesn't end at the instruction budget (until UNLOCK,
  C2        UNLOCK        or the end of the slice: a WAIT, a stall or STOP ends a lock)"""

AREA = {1: 0, 2: 1, 3: 2, 4: 3, 5: 3, 6: 4, 7: 4, 8: 5, 9: 5, 10: 6, 11: 7, 12: 8}
NPAR = 8                              # start parameters: R0-R7


def allowed(a, area_en):
    if a in (0x0C, 0x1C) or 0x95 <= a <= 0x9F:
        return False
    hi = a >> 4
    if hi == 0:
        return True
    if hi in AREA:
        return bool(area_en >> AREA[hi] & 1)
    return False


def nops(op):
    if op >> 6 == 0: return 1
    if op >> 6 == 1: return 0
    if op >> 6 == 2: return 2
    if op in (0xC0, 0xC4): return 1
    if op == 0xC5: return 3
    if op in (0xC6, 0xC7, 0xCA, 0xCB): return 2
    if op >> 3 == 0b11100: return 2
    if 0xF0 <= op <= 0xF7: return 1
    if 0xF8 <= op <= 0xFC: return 2
    if op == 0xFD: return 3
    return 0


class Thread:
    def __init__(self):
        self.pc = 0; self.base = 0; self.wait = 0; self.stack = []; self.rem = 0
        self.acc = 0; self.c = False; self.r = [0] * 16; self.locked = False


class Model:
    def __init__(self, ram, area_en=0x1FF, regs=None, ctx_page=0xFF):
        self.ram = ram                    # bytearray(65536); the context page is modelled separately
        self.area_en = area_en
        self.regs = dict(regs or {})      # bus read-back: what the copper's reads see
        self.th = [Thread() for _ in range(8)]
        self.running = 0; self.ready = 0; self.err = 0; self.sig = 0
        self.cur = 0
        self.writes = []
        self.tick = 0
        self.queue = []                   # host starts not yet served: (t, addr, base, params)
        self.blocked = 0                  # serve attempts that found the next start's thread busy
        self.late = 0                     # starts served in a later tick than they were made
        self.run_on = True                # CCTRL bit 0 (0: frozen; the latch is still served)
        self.tpend = False                # a tick while frozen (more than one count as one)
        self.instr = 0                    # instructions executed
        self.ppops = 0                    # ... of them copper++ instructions
        self.ramacc = 0                   # RAM accesses (fetches, context, registers, tables)

    # ---------------------------------------------------------------- host side
    def start(self, t, addr, base, params=()):
        """a FORK, or a host start being served: thread t starts now"""
        th = self.th[t]
        th.pc = addr; th.base = base; th.wait = 0; th.stack = []; th.rem = 0
        th.acc = 0; th.c = False; th.locked = False
        for i, v in enumerate(params): th.r[i] = v & 255
        self.running |= 1 << t; self.ready |= 1 << t; self.err &= ~(1 << t)
        self.ramacc += 7 + len(params)

    def post(self, t, addr, base, params=()):
        assert len(params) <= NPAR
        self.queue.append((t, addr, base, list(params), self.tick))

    def at_rest(self, t):
        bit = 1 << t
        return not (self.running & bit and self.ready & bit)

    def serve(self, exclude=None):
        """the start latch: the next start is taken once its thread is at rest"""
        while self.queue:
            t = self.queue[0][0]
            if t == exclude or not self.at_rest(t):
                self.blocked += 1
                return
            t, addr, base, params, k = self.queue.pop(0)
            self.late += self.tick != k
            self.start(t, addr, base, params)

    def kill(self, mask):
        self.running &= ~mask; self.ready &= ~mask

    def host_kill(self, mask):
        """CKILL: the 6502 waits for the start latch first, so earlier starts have been served"""
        self.serve(); self.kill(mask)

    # ---------------------------------------------------------------- execution
    def fetch(self, th):
        b = self.ram[th.pc]; th.pc = (th.pc + 1) & 0xFFFF; self.ramacc += 1
        return b

    def count(self, th):
        """an instruction at the current level is done"""
        if th.rem == 1:
            th.pc, th.rem = th.stack.pop(); self.ramacc += 3
        elif th.rem:
            th.rem -= 1

    def write(self, a, v):
        if allowed(a, self.area_en):
            self.writes.append((self.tick, a, v))
            if a != 0xC0: self.regs[a] = v        # $C0 (AMY) reads STATUS, not the command

    def fail(self, bit):
        self.err |= bit; self.running &= ~bit; self.ready &= ~bit

    def one(self, t, th):
        """one instruction: 'go' (on to the next), 'wait' (the slice ends after it), 'save'
        (the slice ends at once: STOP, KILL of itself, an error), 'stall'"""
        bit = 1 << t
        ipc = th.pc
        op = self.fetch(th)
        o = [self.fetch(th) for _ in range(nops(op))]
        if 0xF0 <= op <= 0xFD or op in (0xC1, 0xC2): self.ppops += 1
        top = op >> 6
        if top == 0:                                    # MOVE
            self.write((th.base + (op & 63)) & 255, o[0]); self.count(th)
        elif top == 1:                                  # WAIT
            th.wait = op & 63; self.ready &= ~bit; self.ramacc += 1
            self.count(th); return 'wait'
        elif top == 2 or op in (0xC5, 0xC7):            # REF, REFL, CALL
            target = o[0] | o[1] << 8
            n = 0 if op == 0xC7 else ((op & 63) + 1 if top == 2 else o[2] + 1)
            if th.rem == 1:
                th.pc = target; th.rem = n
            elif len(th.stack) == 8:
                self.fail(bit); return 'save'
            else:
                th.stack.append((th.pc, 0 if th.rem == 0 else th.rem - 1)); self.ramacc += 3
                th.pc = target; th.rem = n
        elif op == 0xC0:
            th.base = o[0]; self.count(th)
        elif op == 0xC1:
            th.locked = True; self.count(th)
        elif op == 0xC2:
            th.locked = False; self.count(th)
        elif op == 0xC4:                                # WAITL
            th.wait = o[0]; self.ready &= ~bit; self.ramacc += 1
            self.count(th); return 'wait'
        elif op == 0xC6:
            th.pc = o[0] | o[1] << 8; self.count(th)
        elif op == 0xC8:                                # RET
            if not th.stack:
                self.fail(bit); return 'save'
            th.pc, th.rem = th.stack.pop(); self.ramacc += 3
        elif op in (0xCA, 0xCB):                        # WAITBIT / WAITCLR
            a = (th.base + o[0]) & 255
            v = self.regs.get(a, 0) if allowed(a, self.area_en) else 0
            stall = (v & o[1]) != 0 if op == 0xCA else (v & o[1]) == 0
            if stall:
                th.pc = ipc; return 'stall'
            self.count(th)
        elif op == 0xFF:
            self.running &= ~bit; self.ready &= ~bit; return 'save'
        elif op >> 3 == 0b11010:
            self.sig |= 1 << (op & 7); self.count(th)
        elif op >> 3 == 0b11100:                        # FORK
            u = op & 7; target = o[0] | o[1] << 8
            if u == t:
                th.pc = target; th.stack = []; th.rem = 0
            else:
                self.start(u, target, th.base); self.count(th)
        elif op >> 3 == 0b11101:                        # KILL
            u = op & 7
            self.kill(1 << u)
            if u == t: return 'save'
            self.count(th)
        elif op == 0xF0:                                # MOVA
            self.write((th.base + o[0]) & 255, th.acc); self.count(th)
        elif op == 0xF1:                                # STA
            th.r[o[0] & 15] = th.acc; self.ramacc += 1; self.count(th)
        elif 0xF2 <= op <= 0xF7:                        # LDA, ADD, SUB: # or Rn
            if op & 1:
                v = th.r[o[0] & 15]; self.ramacc += 1
            else:
                v = o[0]
            if op <= 0xF3:
                th.acc = v
            elif op <= 0xF5:
                s = th.acc + v; th.c = s > 255; th.acc = s & 255
            else:
                th.c = th.acc < v; th.acc = (th.acc - v) & 255
            self.count(th)
        elif op == 0xF8:                                # LDT
            th.acc = self.ram[((o[0] | o[1] << 8) + th.acc) & 0xFFFF]; self.ramacc += 1
            self.count(th)
        elif 0xF9 <= op <= 0xFC:                        # JZ JNZ JC JNC
            z = th.acc == 0
            if (z, not z, th.c, not th.c)[op - 0xF9]: th.pc = o[0] | o[1] << 8
            self.count(th)
        elif op == 0xFD:                                # DJNZ
            k = o[2] & 15; th.r[k] = (th.r[k] - 1) & 255; self.ramacc += 2
            if th.r[k]: th.pc = o[0] | o[1] << 8
            self.count(th)
        else:                                           # reserved
            self.fail(bit); return 'save'
        return 'go'

    def slice(self, t):
        """run thread t until WAIT, stall, stop or 16 instructions (more while locked);
        True if it made progress"""
        th = self.th[t]; bit = 1 << t
        th.locked = False
        self.ramacc += 12                               # context load and save
        n = 0
        while True:
            self.instr += 1; n += 1
            r = self.one(t, th)
            if r == 'stall': th.locked = False; return False
            if r == 'save': th.locked = False; return True
            self.serve(exclude=t)                       # a host start, between instructions
            if r == 'wait' or not self.running & bit or (n >= 16 and not th.locked):
                th.locked = False; return True

    def pick(self):
        r = self.ready & self.running
        for i in range(1, 9):
            t = (self.cur + i) % 8
            if r >> t & 1: return t
        return None

    def ctrl(self, v):
        """a CCTRL write between passes: STOPALL, run (a tick that came while frozen is
        counted once, as soon as the copper runs again)"""
        if v & 2:
            self.kill(0xFF); self.queue.clear(); self.err = 0; self.sig = 0
        self.run_on = bool(v & 1)
        if self.run_on and self.tpend:
            self.tpend = False; self.do_tick()

    def tick_now(self):
        if self.run_on: self.do_tick()
        else: self.tpend = True

    def run_pass(self):
        stalled_only = 0
        while True:
            self.serve()
            if not self.run_on: return
            t = self.pick()
            if t is None: return
            self.cur = t
            if self.slice(t):
                stalled_only = 0
            else:
                stalled_only += 1
                if stalled_only > 8 and bin(self.ready & self.running).count('1') <= 1 and not self.queue:
                    return
                if stalled_only > 64:
                    return

    def do_tick(self):
        for t in range(8):
            bit = 1 << t
            if self.running & bit and not self.ready & bit:
                th = self.th[t]
                if th.wait == 0: self.ready |= bit
                else: th.wait -= 1

    def run(self, events, ticks):
        for k in range(ticks):
            self.tick = k
            if k: self.tick_now()
            self.run_pass()
            for e in events.get(k, []):
                if e[0] == 'start': self.post(e[1], e[2], e[3], e[4] if len(e) > 4 else ())
                elif e[0] == 'kill': self.host_kill(e[1])
                elif e[0] == 'ctrl': self.ctrl(e[1])
            self.run_pass()
        return self.writes


class Asm:
    """tiny assembler: a.label('x'); a.move(r, v); a.ref('x', n) ... a.bytes() at the end"""
    def __init__(self, org):
        self.org = org; self.b = []; self.labels = {}; self.fix = []

    def here(self): return self.org + len(self.b)
    def label(self, name): self.labels[name] = self.here()
    def _addr(self, x, at=1):
        """an address operand, `at` bytes into the instruction being added"""
        if isinstance(x, str):
            self.fix.append((len(self.b) + at, x)); return [0, 0]
        return [x & 255, x >> 8]
    def move(self, r, v): self.b += [r & 63, v & 255]
    def wait(self, n): assert 1 <= n <= 64; self.b += [0x40 | (n - 1)]
    def waitl(self, n): assert 1 <= n <= 256; self.b += [0xC4, n - 1]
    def ref(self, x, n): assert 1 <= n <= 64; self.b += [0x80 | (n - 1)] + self._addr(x)
    def refl(self, x, n): assert 1 <= n <= 256; self.b += [0xC5] + self._addr(x) + [n - 1]
    def base(self, b): self.b += [0xC0, b]
    def jump(self, x): self.b += [0xC6] + self._addr(x)
    def call(self, x): self.b += [0xC7] + self._addr(x)
    def ret(self): self.b += [0xC8]
    def waitbit(self, r, m): self.b += [0xCA, r, m]
    def waitclr(self, r, m): self.b += [0xCB, r, m]
    def signal(self, s): self.b += [0xD0 | s]
    def fork(self, t, x): self.b += [0xE0 | t] + self._addr(x)
    def kill(self, t): self.b += [0xE8 | t]
    def stop(self): self.b += [0xFF]
    # copper++
    def lock(self): self.b += [0xC1]
    def unlock(self): self.b += [0xC2]
    def mova(self, r): self.b += [0xF0, r & 255]
    def sta(self, n): self.b += [0xF1, n]
    def lda(self, v): self.b += [0xF2, v & 255]
    def ldr(self, n): self.b += [0xF3, n]
    def add(self, v): self.b += [0xF4, v & 255]
    def addr(self, n): self.b += [0xF5, n]
    def sub(self, v): self.b += [0xF6, v & 255]
    def subr(self, n): self.b += [0xF7, n]
    def ldt(self, x): self.b += [0xF8] + self._addr(x)
    def jz(self, x): self.b += [0xF9] + self._addr(x)
    def jnz(self, x): self.b += [0xFA] + self._addr(x)
    def jc(self, x): self.b += [0xFB] + self._addr(x)
    def jnc(self, x): self.b += [0xFC] + self._addr(x)
    def djnz(self, x, n): self.b += [0xFD] + self._addr(x) + [n]
    def raw(self, *x): self.b += list(x)
    def bytes(self):
        for i, name in self.fix:
            a = self.labels[name]; self.b[i] = a & 255; self.b[i + 1] = a >> 8
        return bytes(self.b)
