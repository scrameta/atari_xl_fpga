#!/usr/bin/env python3
"""render.py - preview a drum log: note engine model, then chip model.

usage: render.py amy_log.txt out.wav [amy_model options]
Writes the expanded chip log next to the WAV (*.chip.txt)."""
import sys, os, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engine

log, wav = sys.argv[1], sys.argv[2]
out, _ = engine.expand(open(log))
chip = os.path.splitext(wav)[0] + '.chip.txt'
with open(chip, 'w') as f:
    for t, r, v in out:
        f.write('%d %d %d\n' % (t, r, v))
print('%s: %d chip writes' % (chip, len(out)))
subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'amy_model.py'),
                chip, wav] + sys.argv[3:], check=True)
