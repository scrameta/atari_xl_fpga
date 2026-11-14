"""Run a TYPE B SAP in py65 and capture the POKEY registers once per player call.
capture(path, song, frames) -> header dict, list of frames, each [AUDF1, AUDC1, ..., AUDF4, AUDC4, AUDCTL]"""
import sys
from py65.devices.mpu6502 import MPU
from py65.memory import ObservableMemory

def load(path):
    b = open(path, 'rb').read()
    i = b.index(b'\xff\xff')
    hdr = {}
    for l in b[:i].decode('latin1').replace('\r', '').split('\n')[1:]:
        if l.strip():
            k, _, v = l.partition(' ')
            hdr.setdefault(k, []).append(v.strip().strip('"'))
    mem = ObservableMemory()
    j = i
    while j < len(b):
        if b[j] == 0xFF and b[j + 1] == 0xFF: j += 2
        s = b[j] | b[j + 1] << 8; e = b[j + 2] | b[j + 3] << 8; j += 4
        for a in range(s, e + 1): mem[a] = b[j + a - s]
        j += e - s + 1
    return hdr, mem

def capture(path, song=0, frames=3000):
    hdr, mem = load(path)
    assert hdr['TYPE'][0] == 'B', hdr['TYPE']
    pk = [0] * 9
    def wr(a, v):
        r = a & 0x0F
        if r < 9: pk[r] = v
    mem.subscribe_to_write(range(0xD200, 0xD210), wr)
    mem.subscribe_to_write(range(0xD210, 0xD220), wr)     # stereo second POKEY ignored (mirror)
    mem.subscribe_to_read([0xD20A], lambda a: 0x55)        # RANDOM
    mem.subscribe_to_read([0xD40B], lambda a: 0)           # VCOUNT
    cpu = MPU(memory=mem)
    def call(addr, a=0):
        mem[0x00F0:0x00F4] = [0x20, addr & 255, addr >> 8, 0xEA]
        cpu.pc = 0xF0; cpu.a = a; cpu.x = 0; cpu.y = 0; cpu.sp = 0xFF
        n = 0
        while cpu.pc != 0xF3:
            cpu.step(); n += 1
            if n > 2000000: raise RuntimeError('player runs away')
    call(int(hdr['INIT'][0], 16), song)
    out = []
    for f in range(frames):
        call(int(hdr['PLAYER'][0], 16))
        out.append(list(pk))
    return hdr, out

if __name__ == '__main__':
    hdr, fr = capture(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]))
    for i, f in enumerate(fr[:int(sys.argv[4]) if len(sys.argv) > 4 else 50]):
        print(i, ' '.join('%02X' % x for x in f))
