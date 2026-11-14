"""py65 rig: loads an XEX, logs engine events / RAM writes, AMY registers read as idle."""
from py65.devices.mpu6502 import MPU
from py65.memory import ObservableMemory

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

