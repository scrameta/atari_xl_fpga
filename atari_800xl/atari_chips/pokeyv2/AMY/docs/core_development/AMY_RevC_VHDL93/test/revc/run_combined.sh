#!/usr/bin/env bash
# Combined original-sound and new-feature test runner (requires GHDL with VHDL-93 support and Python 3).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
REF="$HERE/baseline_vhdl"
NEW="$ROOT/vhdl"
WORK="$HERE/work"
mkdir -p "$WORK/ref" "$WORK/new" "$WORK/output"
python3 "$HERE/test_reference.py"
python3 "$HERE/static_interface_check.py"
python3 "$HERE/make_feature_vectors.py"
python3 "$HERE/make_prop_vectors.py"
if ! command -v ghdl >/dev/null; then
  echo 'ERROR: GHDL is required for VHDL simulation; only Python checks ran.' >&2
  exit 2
fi
compile() {
  local name=$1 src=$2
  cd "$WORK/$name"
  cp "$ROOT/vhdl/amy1_mem.hex" .
  rm -f work-obj08.cf
  local files=( amy1_mem_pkg amy1_mem amy1_dpram_sim amy1_mem_packed
     amy1_pkg amy1_host_interface amy1_command_unit amy1_timebase amy1_ram_addressing
     amy1_envelope_generator amy1_noise_generator amy1_exp_rom amy1_phase_generator
     amy1_sine_rom amy1_output_accumulator )
  for x in "${files[@]}"; do ghdl -a --std=08 -frelaxed "$src/$x.vhd"; done
  [[ "$name" != new ]] || ghdl -a --std=08 -frelaxed "$src/amy1_ext_phase.vhd"
  for x in amy1_core amy1_engine amy1 amy1_top; do
    ghdl -a --std=08 -frelaxed "$src/$x.vhd"
  done
  ghdl -a --std=08 -frelaxed "$HERE/tb_top93.vhd"
  if [[ "$name" == new ]]; then
    ghdl -a --std=08 -frelaxed "$HERE/tb_ext_phase.vhd" "$HERE/tb_ext_memory.vhd"
    : # ghdl -e tb_ext_phase (mcode: -r elaborates)
    : # ghdl -e tb_ext_memory (mcode: -r elaborates)
  fi
  : # ghdl -e tb_top (mcode: -r elaborates)
}
compile ref "$REF"
compile new "$NEW"
(cd "$WORK/new" && ghdl -r --std=08 tb_ext_phase --assert-level=error --stop-time=1us)
(cd "$WORK/new" && ghdl -r --std=08 tb_ext_memory --assert-level=error --stop-time=100us)
# C.3: the aux2 port (extension page in M9K 3) and the engine's XPAGE host path
(cd "$WORK/new" && ghdl -a --std=08 -frelaxed "$HERE/tb_aux2.vhd" "$HERE/tb_xpage.vhd" &&
  for c in 14 10 9; do ghdl -r --std=08 tb_aux2 -gCLKS=$c --assert-level=error | grep passed; done &&
  ghdl -r --std=08 tb_xpage --assert-level=error | grep passed)
run_tb() {
  local name=$1 vector=$2 tag=$3 stop=$4 extra=${5:-}
  local p="$WORK/output/$name-$tag"
  # Use GHDL generic string path options; run from a directory containing the ROM file.
  (cd "$WORK/$name" && ghdl -r --std=08 tb_top \
    -gSTEP_NUM=3 -gSTEP_DEN=7 -gENGINE=true -gUNIT_LOG2=15 \
    -gMEM_FILE="$ROOT/vhdl/amy1_mem.hex" -gCMD_FILE="$vector" \
    -gOUT_FILE="$p.samples" -gPCM_FILE="$p.pcm" \
    -gREAD_FILE="$p.reads" -gBUSY_FILE="$p.busy" -gCHIP_FILE="$p.chip" \
    -gSTOP="$stop" $extra >"$p.log" 2>&1 )
  echo "  $name/$tag: $(wc -l < "$p.pcm") samples"
}
echo 'Running locked-extension/legacy compatibility comparisons at 8.192 MHz'
for case in cmds_quickclr_spec cmds_drums cmds_drums40 cmds_rich_spec; do
  case "$case" in cmds_rich_spec) stop=2600000;; *) stop=1400000;; esac
  v="$ROOT/test/cmds/$case.txt"
  run_tb ref "$v" "legacy-$case" "$stop"
  run_tb new "$v" "legacy-$case" "$stop"
  cmp "$WORK/output/ref-legacy-$case.samples" "$WORK/output/new-legacy-$case.samples"
  cmp "$WORK/output/ref-legacy-$case.pcm" "$WORK/output/new-legacy-$case.pcm"
  cmp "$WORK/output/ref-legacy-$case.reads" "$WORK/output/new-legacy-$case.reads"
  echo "  PASS bit-exact legacy: $case"
done
# The unlock must not itself change the sound.
run_tb new "$HERE/cmds_enabled_zero.txt" enabled-zero 1400000
cmp "$WORK/output/ref-legacy-cmds_quickclr_spec.pcm" "$WORK/output/new-enabled-zero.pcm"
echo '  PASS bit-exact after unlock with all coefficients at zero'
echo 'Running candidate feature audio traces (reports differences; does not assume an expected audio shape)'
for case in att detune detune_h0 stoch white all reset lock; do
  run_tb new "$HERE/cmds_$case.txt" "$case" 2600000
  python3 "$HERE/check_audio.py" "$WORK/output/ref-legacy-cmds_quickclr_spec.pcm" "$WORK/output/new-$case.pcm" "$case"
done
python3 "$HERE/check_revc_c3.py" "$WORK/output/ref-legacy-cmds_quickclr_spec.pcm" \
  "$WORK/output/new-detune_h0.pcm" "$WORK/output/new-white.pcm"
echo 'Proportional envelope mode (spec 7.6): read-backs against the integer recursion'
for case in freq amp lock; do
  stop=$(awk -v c=$case '$1==c{print $2}' "$HERE/prop_stops.txt")
  run_tb new "$HERE/cmds_prop_$case.txt" "prop_$case" "$stop"
  mv "$WORK/output/new-prop_$case.reads" "$WORK/output/prop_$case.reads"
done
python3 "$HERE/check_prop.py" "$WORK/output"
echo 'Combined test suite finished. Review test/revc/work/output/* logs and comparisons.'
