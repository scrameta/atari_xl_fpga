"""Run vbiplay's player in py65: the events it posts against engmodel.song_events, and
its cycles per frame.  usage: bench.py vbiplay.xex"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'test', 'engine'))
from py65.devices.mpu6502 import MPU
from py65.memory import ObservableMemory
import engmodel, mkinst
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mkvbi

AMY = 0xD2C0
def load_xex(path, mem):
    b = open(path, 'rb').read(); i = 0
    while i < len(b):
        if b[i] == 0xFF and b[i + 1] == 0xFF: i += 2
        s = b[i] | b[i + 1] << 8; e = b[i + 2] | b[i + 3] << 8; i += 4
        for a in range(s, e + 1): mem[a] = b[i + a - s]
        i += e - s + 1

class Rig:
    def __init__(self, xex):
        self.mem = ObservableMemory()
        load_xex(xex, self.mem)
        self.regs = [0] * 16; self.log = []; self.frame = 0; self.ram = {}
        self.mem.subscribe_to_read(range(AMY, AMY + 16), self.rd)
        self.mem.subscribe_to_write(range(AMY, AMY + 16), self.wr)
        self.mpu = MPU(memory=self.mem)
    def rd(self, a):
        return self.regs[15] if a == AMY + 15 else 0         # never busy or full
    def wr(self, a, v):
        r = a - AMY; self.regs[r] = v
        if r == 11: self.log.append((self.frame, v, self.regs[8], self.regs[9], self.regs[10]))
        if r == 13: self.ram[self.regs[12]] = self.regs[8] | self.regs[9] << 8 | self.regs[10] << 16 | v << 24
    def call(self, addr, a=0):
        m = self.mem; m[0x600:0x604] = [0x20, addr & 255, addr >> 8, 0xEA]
        c = self.mpu; c.pc = 0x600; c.a = a; c.sp = 0xFF
        c0 = c.processorCycles
        while c.pc != 0x603: c.step()
        return c.processorCycles - c0 - 6 - 6                # less the JSR and RTS

def main(xex, clk4='2x'):
    base = 0x2E00
    names = [i['name'] for i in engmodel.instruments(clk4)]
    allc = []; ok = True
    for s, name in enumerate(mkvbi.SONGS):
        rig = Rig(xex)
        rig.call(base + 3); rig.call(base + 6, 0)
        want = {w: x for w, x in engmodel.ram_image(clk4).items() if w >= 40}
        if s == 0:
            print('engine RAM upload: %d words, %s; CONFIG %d' % (len(rig.ram), 'SAME as engmodel' if rig.ram == want else 'DIFFERENT', rig.regs[15]))
            ok &= rig.ram == want and rig.regs[15] == 1
        rig.log = []
        rig.call(base + 9, s)
        nextsong = None; cyc = []
        sym = {}
        while True:
            rig.frame += 1
            cyc.append(rig.call(base + 12))
            # the player sets nextsong (< $80) when the song has ended
            if rig.frame > 20000: break
            if rig.mem[nsaddr] < 0x80: break
        got = []
        for (f, v, w0, w1, w2) in rig.log:
            if v >= 0xA0: got.append((f, 'inst', v & 7, w0, 0, 0))
            elif v >= 0x90: got.append((f, 'on', v & 7, w0, w1, w2))
            elif f > 0: got.append((f, 'off', v & 7, 0, 0, 0))
        ens = mkinst.ENSEMBLES[s % len(mkinst.ENSEMBLES)]
        exp = engmodel.song_events(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'test', 'engine', 'songs', name + '.MUS'),
                                   [names.index(x) for x in ens[1]], clk4=clk4)
        same = got == exp
        ok &= same
        first = next((i for i, (a, b) in enumerate(zip(got, exp)) if a != b), None)
        allc += cyc
        print('%-9s %-9s frames %5d events %4d %s  cycles/frame mean %5.1f max %4d%s' % (
            name, ens[0], len(cyc), len(got), 'SAME' if same else 'DIFFER', sum(cyc) / len(cyc), max(cyc),
            '' if same else ' at %s: %s vs %s' % (first, got[first:first + 2] if first is not None else got[len(exp):len(exp)+2],
                                                  exp[first:first + 2] if first is not None else exp[len(got):len(got)+2])))
    print('all: max %d cycles = %.1f scanlines of 114 cycles' % (max(allc), max(allc) / 114.0))
    print('BENCH', 'PASS' if ok else 'FAIL')

nsaddr = None
if __name__ == '__main__':
    # vbiplay.lbl from ld65 -Ln (see build.sh): the address of nextsong
    import re
    m = re.search(r'al 00([0-9A-F]{4}) \.nextsong', open('vbiplay.lbl').read())
    nsaddr = int(m.group(1), 16)
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else '2x')
