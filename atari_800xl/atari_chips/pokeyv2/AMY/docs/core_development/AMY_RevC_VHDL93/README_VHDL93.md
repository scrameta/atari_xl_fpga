# AMY Revision C — strict VHDL-1993 candidate

This is the November 7 combined Rev C extension candidate reformatted for **VHDL-1993** and the preferred `*_reg` / `*_next` state style. No feature or register assignment was intentionally changed. It is **not HDL-compiled or regression-verified** in this environment.

## Changed synthesizable source

- `vhdl/amy1_ext_phase.vhd`: explicit combinational sensitivity list instead of `process(all)`.
- `vhdl/amy1_mem_packed.vhd`: explicit sensitivity for harmonic RAM write mux; removed the conditional signal assignment from a clocked process. Extension control and coefficient latches now have separate `*_reg` / `*_next` paths; RAM read/write remains in its inferred synchronous process.
- `vhdl/amy1_top.vhd`: extension unlock and A/B/C shadow registers split into synchronous register and combinational next-state processes.
- `vhdl/amy1_core.vhd`: attenuation register bank split into synchronous register and combinational next-state processes.
- `vhdl/amy1_noise_generator.vhd`: white-noise LFSR split into synchronous register and combinational next-state processes.

Other legacy RTL is unchanged. **Concurrent** `a <= b when condition else c` assignments are valid VHDL-1993 and remain unchanged. `case ... when` alternatives inside processes are likewise standard VHDL-1993 (not the forbidden sequential conditional signal assignment).

## Tests

- `test/revc/run_combined.sh` now compiles the design and the *portable* benches using `ghdl --std=93`.
- `test/revc/tb_top93.vhd` retains sample, PCM, and public register-read logs; it does **not** use the older VHDL-2008 external-name mechanism to inspect internal signals. Detailed internal busy/chip diagnostics are therefore unavailable in this portable regression (the original `vhdl/tb_top.vhd` remains as a VHDL-2008-only diagnostic testbench).
- `test/revc/tb_ext_phase.vhd` and `tb_ext_memory.vhd` no longer use `std.env.finish`; they can be compiled under VHDL-93.
- `test/revc/check_vhdl93.py` tests key language/style restrictions, but is **not a VHDL compiler**.
- `test_stage1.py` was updated to check the renamed white-noise PRBS register.

### Run from the package root

```bash
python3 test/revc/check_vhdl93.py
python3 test_stage1.py
python3 test/revc/test_reference.py
python3 test/revc/static_interface_check.py
bash test/revc/run_combined.sh
```

For Quartus, use the full `vhdl/` RTL set *except* testbench files named `tb_*.vhd`, and add `amy1_ext_phase.vhd`. Use VHDL-1993 analysis for these RTL files. Compare four M9Ks, LEs, multipliers and slack with the previous build.

## Known limitation

**No GHDL or Quartus run was possible here.** The structural checker and Python tests pass, but synthesis, HDL execution, equivalence, legacy audio regression and spectral/audio correctness remain to be verified. The new clock/state scheduling deserves careful simulation.
