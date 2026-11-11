#!/bin/sh
# Note engine tests (GHDL 4.1, Python 3).  Builds into ./work, then:
#   edge cases, both layouts                  (a few minutes)
#   full system: amy1_top + the chip           (a few minutes)
#   Rev C extensions (6.8): engine alone and full system, both layouts
#   6 songs x 6 ensembles, both layouts        (~25 minutes on 2 cores)
set -e
cd "$(dirname "$0")"
V=$(pwd)/../../vhdl
mkdir -p work && cd work
cp $V/amy1_mem.hex .
for f in amy1_mem_pkg amy1_mem amy1_dpram_sim amy1_mem_packed amy1_pkg amy1_host_interface amy1_command_unit \
         amy1_timebase amy1_ram_addressing amy1_envelope_generator amy1_noise_generator amy1_exp_rom \
         amy1_phase_generator amy1_sine_rom amy1_output_accumulator amy1_ext_phase amy1_core amy1 amy1_engine amy1_top tb_top tb_engine; do
  ghdl -a --std=08 -frelaxed $V/$f.vhd
done
cd ..
python3 test_eng_edge.py work
python3 sys_eng.py work
python3 sys_eng.py work hpv8
python3 test_eng_ext.py work
python3 sys_eng_x.py work
python3 sys_eng_x.py work hpv8
python3 run_eng_all.py work
python3 run_eng_all.py work hpv8
