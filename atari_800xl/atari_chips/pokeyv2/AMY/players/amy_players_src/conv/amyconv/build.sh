#!/bin/sh
# amyconv.xex (set 1: Draconus, Zybex, Warhawk), amyconv2.xex (set 2: Happy Train, Axel F,
# Bitter Reality), amyconv3.xex (set 3: International Karate, Jet Set Willy), amyconv4.xex
# (set 4: Axel F, the MOD).  Each XEX is the set's copper note engine (copgen.py: a load segment
# that puts it in the PokeyMAX sample RAM) followed by the player; each is checked with
# copbench.py.  Needs cc65 on PATH, py65, and the ASMA tree at ../asma/asma/Composers.
set -e
cd "$(dirname "$0")"
CFG=${CC65_HOME:-$(dirname $(dirname $(command -v ca65)))}
COPPER=${COPPER:-../../copper}
for n in 1 2 3 4; do
  d=build/set$n
  mkdir -p $d
  AMYCONV_SET=$n python3 mkconv.py $d/convset.inc
  python3 $COPPER/copgen.py $d/copper_words.json $d/copper_conv
  ca65 -g -t atari -I $d amyconv.s -o $d/amyconv.o
  ld65 -C $CFG/cfg/atari-asm.cfg -o $d/player.xex $d/amyconv.o $CFG/lib/atari.lib -Ln $d/amyconv.lbl
  out=amyconv$n.xex; [ $n = 1 ] && out=amyconv.xex
  cat $d/copper_conv.xex $d/player.xex > $out
  echo "$out: $(wc -c < $out) bytes (player $(wc -c < $d/player.xex))"
done
