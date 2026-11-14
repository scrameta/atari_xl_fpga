#!/bin/sh
# vbiplay.xex (AMY at 2 x PHI2), vbiplay_4xphi2.xex (4 x PHI2), vbiplay_clk8.xex
# (PokeyMAX CLK / 8 = 7.168 MHz), each checked against the reference player and
# cycle-counted (needs cc65, py65)
set -e
cd "$(dirname "$0")"
for c in 2x 4x clk8; do
  case $c in 2x) inc=vbidata.inc; def=; out=vbiplay.xex;;
             4x) inc=vbidata4.inc; def="-D CLK4"; out=vbiplay_4xphi2.xex;;
             clk8) inc=vbidata8.inc; def="-D CLK8"; out=vbiplay_clk8.xex;; esac
  python3 mkvbi.py $inc $c
  ca65 -g -t atari $def vbiplay.s -o vbiplay.o
  ld65 -C atari-asm.cfg -o $out vbiplay.o atari.lib -Ln vbiplay.lbl
  echo "$out:"
  python3 bench.py $out $c
done
rm -f vbiplay.o
