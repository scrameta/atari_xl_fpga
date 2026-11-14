"""copbench.py SET [secs] - each tune of a set: the copper player (build/setN/player.xex) in py65,
its register writes (AMY and copper) logged per frame, then through the copper model and the AMY
model (copsim.py), against the engine version (preview.player_log through engine.py); Rev C on
and off. Also the player's cycles per frame."""
import sys, os
H = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, H)
n = sys.argv[1]
os.environ['AMYCONV_SET'] = n
from py65.devices.mpu6502 import MPU
from py65.memory import ObservableMemory
import mkconv, arrange, preview
COPPER = os.environ.get('COPPER', os.path.join(H, '..', '..', 'copper'))
sys.path.insert(0, COPPER)
import copsim


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
        self.log = []; self.frame = 0
        self.mem.subscribe_to_read(range(0xD2C0, 0xD2D0), lambda a: 0)            # AMY never busy
        cfg = {0xD21C: 1, 0xD217: 0x3F, 0xD220: 0x07}                              # a PokeyMAX with the copper
        self.mem.subscribe_to_read(list(cfg), lambda a: cfg[a])
        self.mem.subscribe_to_read(range(0xD295, 0xD2A0), lambda a: 1 if a == 0xD295 else 0)   # copper running, latch free
        self.mem.subscribe_to_write(range(0xD2C0, 0xD2C8), lambda a, v: self.log.append((self.frame, a - 0xD2C0, v)))
        self.mem.subscribe_to_write([0xD20C], lambda a, v: None)                    # the configuration window
        self.mem.subscribe_to_write(range(0xD295, 0xD2A0), lambda a, v: self.log.append((self.frame, a & 255, v)))
        self.mpu = MPU(memory=self.mem)

    def call(self, addr, a=0):
        m = self.mem; m[0x600:0x604] = [0x20, addr & 255, addr >> 8, 0xEA]
        c = self.mpu; c.pc = 0x600; c.a = a; c.sp = 0xFF
        c0 = c.processorCycles
        while c.pc != 0x603: c.step()
        return c.processorCycles - c0 - 12


def main():
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else None
    d = os.path.join(H, 'build', 'set' + n)
    base = 0x2E00
    for t, (name, who, sap, song, fr) in enumerate(mkconv.TUNES):
        if secs: fr = min(fr, int(secs * 50))
        hdr, ev, vi, st = arrange.arrange(os.path.join(mkconv.SAP, sap), song, fr)
        for revc in (1, 0):
            rig = Rig(os.path.join(d, 'player.xex'))
            rig.frame = -2
            rig.call(base + 3)                      # chip_init
            rig.call(base + 6)                      # cop_init
            rig.mem[rig_sym(d, 'revc')] = revc
            rig.call(base + 15)                     # ext_mode
            rig.call(base + 9, t)                   # start_tune (two quiet frames)
            cyc = []
            for f in range(-2, fr):
                rig.frame = f
                c = rig.call(base + 12)
                if f >= 0: cyc.append(c)
            log = [((f + 2) * 20, r, v) for f, r, v in rig.log]
            ref = preview.player_log(ev, revc, fr)
            out = os.path.join(d, 'check_%d_%s' % (t, 'on' if revc else 'off'))
            os.makedirs(out, exist_ok=True)
            with open(os.path.join(out, 'player.log'), 'w') as f:
                f.write(''.join('%d %d %d\n' % x for x in log))
            with open(os.path.join(out, 'engine.log'), 'w') as f:
                f.write(''.join('%d %d %d\n' % x for x in ref))
            print('%s, Rev C %s: cycles/frame mean %.0f max %d (%.1f scanlines)' % (
                name, 'on' if revc else 'off', sum(cyc) / len(cyc), max(cyc), max(cyc) / 114.0), flush=True)
            sys.argv = ['copsim', os.path.join(out, 'player.log'), os.path.join(d, 'copper_conv.bin'), out,
                        '--ref', os.path.join(out, 'engine.log')]
            copsim.main()


def rig_sym(d, name):
    for l in open(os.path.join(d, 'amyconv.lbl')):
        p = l.split()
        if len(p) == 3 and p[2] == '.' + name:
            return int(p[1], 16)
    raise KeyError(name)


if __name__ == '__main__':
    main()
