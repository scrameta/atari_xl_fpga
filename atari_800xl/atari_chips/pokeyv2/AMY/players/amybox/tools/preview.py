#!/usr/bin/env python3
"""Preview: amybox_host log ("frame reg value") -> note engine model -> Rev C chip model -> WAV.
usage: preview.py log.txt out.wav [seconds]"""
import sys, os, subprocess, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engine
lines = ['%d %s %s' % (int(f) * 20, r, v) for f, r, v in (l.split() for l in open(sys.argv[1]) if l.strip())]
out, _ = engine.expand(lines)
chip = os.path.splitext(sys.argv[2])[0] + '.chip.txt'
open(chip, 'w').write(''.join('%d %d %d\n' % x for x in out))
args = ['--to', sys.argv[3]] if len(sys.argv) > 3 else []
subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'amy_model.py'), chip, sys.argv[2]] + args, check=True)
os.remove(chip)
