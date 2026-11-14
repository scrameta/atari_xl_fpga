#!/bin/bash
# The phase-B checks (GHDL 4.1, Python 3 with numpy). Builds into test/work:
#   1. aligned replay: the phase-A core (phaseA_ref/) logs each command's busy start, then
#      tb_amy1b writes the same commands to the phase-B core on the same chip clocks.
#      Samples, host reads and every RAM write must be identical (both memory layouts).
#   2. unaligned: amy1_top with phase A and with phase B inside; timedev.py reports the
#      command timing shift and compares the audio by spectrum and level.
#   3. the note engine's system test on the phase-B amy1_top.
#   4. the noise generators with 64 and 40 harmonics (Q6) against the bit-exact model.
# About 15 minutes on 2 cores.
set -e
T=$(cd "$(dirname "$0")" && pwd); V=$T/../vhdl; A=$T/phaseA_ref; C=$T/cmds; TL=$T/../tools
W=$T/work; mkdir -p $W/a $W/b $W/lb
units="amy1_pkg amy1_host_interface amy1_command_unit amy1_timebase amy1_ram_addressing amy1_envelope_generator
       amy1_noise_generator amy1_exp_rom amy1_phase_generator amy1_sine_rom amy1_output_accumulator amy1_core amy1"
echo "building"
(cd $W/a && rm -f *.cf && ghdl -a --std=08 $V/amy1_mem_pkg.vhd $A/amy1_mem.vhd $V/amy1_dpram_sim.vhd $A/amy1_mem_packed.vhd \
   $(for u in $units; do echo $A/$u.vhd; done) $V/amy1_engine.vhd $A/amy1_top.vhd $A/tb_amy1_log.vhd $A/tb_top_log.vhd)
for d in b lb; do
  (cd $W/$d && rm -f *.cf && ghdl -a --std=08 $V/amy1_mem_pkg.vhd $V/amy1_mem.vhd $V/amy1_dpram_sim.vhd $V/amy1_mem_packed.vhd \
     $(for u in $units; do echo $V/$u.vhd; done) $V/amy1_engine.vhd $V/amy1_top.vhd $V/tb_top.vhd $V/tb_amy1b.vhd $V/tb_engine.vhd)
done
cp $V/amy1_mem.hex $W/b/

# 1. aligned replay
la() {  # name cmds stop [generic]: phase-A logs and the replay schedule
  (cd $W/a && ghdl --elab-run --std=08 tb_amy1_log -gMEM_FILE=$A/amy1_mem.hex -gCMD_FILE=$2 -gOUT_FILE=$1.txt \
     -gSTOP=$3 -gLOG_PREFIX=$1 $4 2>&1 | grep -v metavalue > $1.log
   python3 $TL/mkreplay.py $1 > $1_replay.log
   grep "^D" $1_sched.txt | awk '{print $2, $3, $4}' > $1_rd.txt) ; }
lb() {  # dir name stop spacing packed [generic]
  n=$(( $3 / 48 ))
  (cd $W/$1 && ghdl --elab-run --std=08 tb_amy1b -gMEM_FILE=$V/amy1_mem.hex -gSCHED=$W/a/$2 -gLOG_PREFIX=$2 \
     -gNCLK=$n -gCE_SPACING=$4 -gMEM_PACKED=$5 $6 2>&1 | grep -v metavalue > $2.log)
  s=same; r=same; m=same
  cmp -s $W/$1/$2_samp.txt <(awk -v n=$n '$1<=n' $W/a/$2_samp.txt) || s=DIFF
  cmp -s $W/$1/$2_rd.txt $W/a/$2_rd.txt || r=DIFF
  cmp -s $W/$1/$2_mem.txt <(awk -v n=$n '$1<=n' $W/a/$2_mem.txt) || m=DIFF
  echo "  $2 ($([ $5 = true ] && echo packed || echo rtl), ce every $4 clks): samples $s, host reads $r, RAM writes $m"
  echo "      Q1 check: $(python3 $T/q1check.py $W/a/$2_mem.txt $W/$1/$2_mem.txt $n)"; }
echo "1. aligned replay (since the Q1 fixes, samples/reads/RAM writes differ from phase A by design:"
echo "   the Q1 check line is the test: only the added jump writes may differ)"
la rb $C/cmds_readback_rd.txt 500000 & la q $C/cmds_quickclr_spec.txt 1300000 & wait
la r $C/cmds_rich_spec.txt 4000000 & la nzf $C/cmds_drums.txt 2600000 & wait
la nzn $C/cmds_drums.txt 2600000 -gNOISE_FIX=false
for t in "rb 500000" "q 1300000" "r 4000000" "nzf 2600000" "nzn 2600000 -gNOISE_FIX=false"; do
  set -- $t
  lb b $1 $2 3 true $3 & lb lb $1 $2 2 false $3 & wait
done

# 2. unaligned, through amy1_top
lt() {  # name cmds stop [generic]
  (cd $W/b && ghdl --elab-run --std=08 tb_top -gMEM_FILE=$V/amy1_mem.hex -gCMD_FILE=$2 -gOUT_FILE=$1.txt \
     -gPCM_FILE=$1_pcm.txt -gREAD_FILE=$1_rd.txt -gBUSY_FILE=$1_busy.txt -gSTOP=$3 $4 2>&1 | grep -v metavalue > $1.log) &
  (cd $W/a && ghdl --elab-run --std=08 tb_top -gMEM_FILE=$A/amy1_mem.hex -gCMD_FILE=$2 -gOUT_FILE=t$1.txt \
     -gPCM_FILE=$1_pcm.txt -gREAD_FILE=$1_rd.txt -gBUSY_FILE=$1_busy.txt -gSTOP=$3 $4 2>&1 | grep -v metavalue > t$1.log) &
  wait; }
echo "2. unaligned (amy1_top, phase B - phase A)"
lt tq $C/cmds_quickclr_spec.txt 1300000
lt tq40 $C/cmds_quickclr40.txt 1300000
lt tr $C/cmds_rich_spec.txt 4000000
lt tri $C/cmds_rich_ind.txt 4000000 -gV0_COL=true
lt tlr $C/cmds_rich_ind.txt 4000000 "-gVOICES_L=00000001 -gVOICES_R=00000010"
lt trb $C/cmds_readback_top.txt 500000
lt tnz $C/cmds_drums.txt 2600000
# the drums again, phase B with the SCR that ends NZINIT 100 chip clocks later (the same SYNC
# as phase A), against phase A's original run
(cd $W/b && ghdl --elab-run --std=08 tb_top -gMEM_FILE=$V/amy1_mem.hex -gCMD_FILE=$C/cmds_drums_scr_late.txt \
   -gOUT_FILE=tnzd.txt -gPCM_FILE=tnzd_pcm.txt -gBUSY_FILE=tnzd_busy.txt -gSTOP=2600000 2>&1 | grep -v metavalue > tnzd.log)
cp $W/a/tnz_pcm.txt $W/a/tnzd_pcm.txt; cp $W/a/tnz_busy.txt $W/a/tnzd_busy.txt
for n in tq tq40 tr tri tlr trb tnz tnzd; do python3 $TL/timedev.py $W/b $W/a $n | sed 's/^/  /'; done
echo "  read-back through amy1_top: $(paste $W/b/trb_rd.txt $W/a/trb_rd.txt | awk '$5==$10{s++} END{print s+0 " of " NR " identical"}')"

# 3. the note engine on the phase-B amy1_top
echo "3. note engine"
for m in "" hpv8 x4 clk8; do python3 $T/engine/sys_eng.py $W/b $m | tail -1 | sed "s/^/  ${m:-16x4}: /"; done

# 4. the noise generators, 64 and 40 harmonics, against the bit-exact model
echo "4. noise generators (bit-exact model)"
for t in "n64 cmds_drums.txt" "n40 cmds_drums40.txt"; do
  set -- $t
  (cd $W/b && ghdl --elab-run --std=08 tb_top -gMEM_FILE=$V/amy1_mem.hex -gCMD_FILE=$C/$2 -gOUT_FILE=$1.txt \
     -gPCM_FILE=$1_pcm.txt -gBUSY_FILE=$1_busy.txt -gNZ_ALL=true -gNZ_WORDS=true -gSTOP=2600000 2>&1 | grep -v metavalue > $1.log) &
done; wait
echo "  64 harmonics: $(python3 $TL/noisecheck.py $W/b/n64_busy.txt $T/noise)"
echo "  40 harmonics: $(python3 $TL/noisecheck.py $W/b/n40_busy.txt $T/noise)"
