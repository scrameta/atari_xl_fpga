#!/bin/sh
# amyconv.xex (set 1: Draconus, Zybex, Warhawk), amyconv2.xex (set 2: Happy Train, Axel F,
# Bitter Reality), amyconv3.xex (set 3: International Karate, Jet Set Willy); each checked
# with bench.py.  Needs cc65 on PATH, py65, and the ASMA tree at ../asma/asma/Composers.
set -e
cd "$(dirname "$0")"
CFG=${CC65_HOME:-$(dirname $(dirname $(command -v ca65)))}
for n in 1 2 3 4; do
  mkdir -p build/set$n
  AMYCONV_SET=$n python3 mkconv.py build/set$n/convset.inc
  out=amyconv$n.xex; [ $n = 1 ] && out=amyconv.xex
  ca65 -g -t atari -I build/set$n amyconv.s -o build/set$n/amyconv.o
  ld65 -C $CFG/cfg/atari-asm.cfg -o $out build/set$n/amyconv.o $CFG/lib/atari.lib -Ln build/set$n/amyconv.lbl
  echo "$out: $(wc -c < $out) bytes"
  AMYCONV_SET=$n python3 bench.py $out build/set$n/amyconv.lbl
done
