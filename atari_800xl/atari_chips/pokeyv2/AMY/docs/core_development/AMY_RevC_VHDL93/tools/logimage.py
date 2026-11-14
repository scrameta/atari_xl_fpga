#!/usr/bin/env python3
"""logimage.py in.hex out_dir: the memory image with logical harmonic and voice RAM
addresses (word a of HARM / VOICE = the netlist's word NOT a)."""
import sys, os, struct
w = [l.strip() for l in open(sys.argv[1]) if l.strip()]
for base, n in ((1024, 64), (1184, 16)):
    w[base:base + n] = w[base:base + n][::-1]
o = sys.argv[2]
open(os.path.join(o, 'amy1_mem.hex'), 'w').write('\n'.join(w) + '\n')
open(os.path.join(o, 'amy1_mem.bin'), 'wb').write(b''.join(struct.pack('<I', int(x, 16)) for x in w))
print(len(w), 'words')
