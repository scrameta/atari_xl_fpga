"""Bit-exact model of the AMY1 noise generators (as recreated from the netlist).

Noise RAM: 32 rows x 2 generators x 3 bits (A, B, C), command address = row*2 + gen.
  rows 0-14  : three 15-bit pseudo-random registers A, B, C (bit i at row 14-i)
  rows 20-31 : UD (A column), B (B column), S (C column), bit i at row 20+i
Each sample one generator (alternating) is processed row by row, rows 0..31.
fix=True models the PRB feedback repair (row 0 <- XOR of rows 0,3,8,14 of the previous pass)."""
TAPS = (0, 3, 8, 14)
C20 = (0, 4, 16, 20)
def maj(a, b, c): return (a & b) | (a & c) | (b & c)

class Noise:
    def __init__(self, ram=None, fix=False):
        self.ram = list(ram) if ram else [0] * 64          # values 0..7 = A<<2 | B<<1 | C
        self.fix = fix
        self.chain = [0] * 11                              # BOUTD1..11 (shared by both generators)
        self.out = [0, 0]                                  # output words (12-bit, two's complement)
        self.g = 0                                         # generator processed next

    def pass_(self, g=None):
        g = self.g if g is None else g
        ram = self.ram
        L = [0, 0, 0]                                      # feedback toggles LSB2, LSB1, LSB0 (A, B, C)
        cu = cb = 0
        prev = None
        fb0 = ram[0 * 2 + g] ^ ram[3 * 2 + g] ^ ram[8 * 2 + g] ^ ram[14 * 2 + g]
        for r in range(32):
            v = ram[r * 2 + g]
            A, B, C = v >> 2 & 1, v >> 1 & 1, v & 1
            Z = 1 if L[0] == L[1] == L[2] else 0
            if r in C20:
                ub = (1 - L[1]) & (1 - Z); ciu = maj(*L) & (1 - Z); cib = 0
            else:
                ub = L[1] & (1 - Z); ciu = cu & (1 - Z); cib = cb
            udo = A ^ ub ^ ciu
            bo = B ^ udo ^ cib
            cu_in = cu
            if C:
                self.chain = [bo] + self.chain[:-1]
            last_bo = bo
            if 1 <= r <= 15:
                w = prev
            elif r == 16:
                w = L[0] << 2 | L[1] << 1 | L[2]
            else:
                w = udo << 2 | bo << 1 | C
                if r == 0 and self.fix:
                    w = fb0
            if r in TAPS:
                L = [L[0] ^ A, L[1] ^ B, L[2] ^ C]
            # the carries are latched at the next P1, after this row's toggle (P0): recompute
            # this row's adders with the updated toggles for the carry out
            Z = 1 if L[0] == L[1] == L[2] else 0
            if r in C20:
                ub2 = (1 - L[1]) & (1 - Z); ciu2 = maj(*L) & (1 - Z)
            else:
                ub2 = L[1] & (1 - Z); ciu2 = cu_in & (1 - Z)
            udo2 = A ^ ub2 ^ ciu2
            cu = maj(A, ub2, ciu2); cb = maj(B, udo2, cib)
            prev = v
            ram[r * 2 + g] = w
        word = last_bo << 11
        for i, b in enumerate(self.chain): word |= b << (10 - i)
        self.out[g] = word
        self.g = 1 - g
        return word

def image(gens):
    m = [0] * 64
    for g, d in enumerate(gens):
        for i in range(15):
            m[(14 - i) * 2 + g] = ((d['a'] >> i) & 1) << 2 | ((d['b'] >> i) & 1) << 1 | ((d['c'] >> i) & 1)
        for i in range(12):
            m[(20 + i) * 2 + g] = ((d.get('ud', 0) >> i) & 1) << 2 | ((d.get('bb', 0) >> i) & 1) << 1 | ((d.get('s', 0) >> i) & 1)
    return m
