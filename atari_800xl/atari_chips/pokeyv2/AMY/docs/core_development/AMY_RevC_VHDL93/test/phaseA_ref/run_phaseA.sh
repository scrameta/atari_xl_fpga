#!/bin/sh
# The phase-A check: samples, host reads and every RAM write, against the stage-2 core's logs
# in results/phaseA (the stage-2 core is sample-identical to the netlist core).
# Phase-A sources (pin-level, six steps per chip clock) with the netlist-order memory image.
set -e
cd "$(dirname "$0")"; mkdir -p work; cd work
cp ../*.vhd ../../../vhdl/amy1_mem_pkg.vhd ../../../vhdl/amy1_dpram_sim.vhd ../amy1_mem.hex .
ghdl -a --std=08 amy1_mem_pkg.vhd amy1_mem.vhd amy1_dpram_sim.vhd amy1_mem_packed.vhd \
  amy1_pkg.vhd amy1_host_interface.vhd amy1_command_unit.vhd amy1_timebase.vhd amy1_ram_addressing.vhd \
  amy1_envelope_generator.vhd amy1_noise_generator.vhd amy1_exp_rom.vhd amy1_phase_generator.vhd \
  amy1_sine_rom.vhd amy1_output_accumulator.vhd amy1_core.vhd amy1.vhd tb_amy1.vhd
R=../../results/phaseA; C=../../cmds; ok=1
run() {  # name cmds stop [generic]
  ghdl --elab-run --std=08 tb_amy1 -gMEM_FILE=amy1_mem.hex -gCMD_FILE=$2 -gOUT_FILE=pa_$1.txt \
    -gSTOP=$3 -gREAD_FILE=pa_$1_rd.txt -gTRACE_FILE=pa_$1_tr.txt $4 2>&1 | grep -v metavalue > pa_$1.log
  s=same; cmp -s pa_$1.txt $R/$1.txt || { s=DIFF; ok=0; }
  r=same; cmp -s pa_$1_rd.txt $R/$1_rd.txt || { r=DIFF; ok=0; }
  # the first 40 trace lines are the power-up writes (D3 changes their data)
  t=same; tail -n +40 pa_$1_tr.txt > pa_a.txt; gunzip -c $R/$1_tr.txt.gz | tail -n +40 > pa_b.txt
  cmp -s pa_a.txt pa_b.txt || { t=DIFF; ok=0; }
  echo "$1: samples $s, host reads $r, RAM writes $t"
}
run rb  $C/cmds_readback_rd.txt  500000
run q   $C/cmds_quickclr_spec.txt 1300000
run r   $C/cmds_rich_spec.txt    4000000
run nzf $C/cmds_drums.txt        2600000
run nzn $C/cmds_drums.txt        2600000 -gNOISE_FIX=false
[ $ok = 1 ] && echo "phase A: identical to the stage-2 core" || { echo "phase A: differences"; exit 1; }
