# AMY Rev C: combined synthesis extensions — validation candidate

**Status: VHDL-93 compatibility refactor; not yet HDL-compiled or regression-certified. See `README_VHDL93.md`.**

This working package builds on the cleaned November 6 / Stage 1 AMY1 project, and includes white-noise type 3, a gated extension command interface, eight voice-attenuation registers, six-bit per-harmonic detuning and independent six-bit per-harmonic phase diffusion.

## Hardware/compatibility contract

- System CLK remains 57.344 MHz; effective AMY CLOCK 8.192 MHz (`STEP_NUM=3`, `STEP_DEN=7`), hence 4.096 MHz internal CE and 32 kHz for 64-harmonic output.
- All extensions are **locked after reset**. Original Atari command semantics, FIFO and note engine remain in place when locked.
- Read `$D2C7` remains **status**, including when unlocked. Write the key sequence at `$D2C7` only when FIFO/engine are idle (status busy=0): `$A5`, then `$5A` to unlock. Write `$00` at `$D2C7` to lock again and clear coefficients. An AMY reset also locks and clears.
- When unlocked only, command bytes `$34`, `$35`, `$36`, `$39` are intercepted; other Atari opcodes go unchanged to the original command unit. These previously alias SCR. No extension processing occurs while locked.
- Original A/B/C interface is used: write A=voice/harmonic index, C=value, then write command to `$D2C0`. B currently ignored for extension commands. **Do not use reserved `$37`/`$38` yet**: readback/capability opcodes are *not* implemented in this candidate.

| Command when unlocked | A (`$D2C1`) | C (`$D2C3`) | Action |
|---|---|---|---|
| `$34` | 0–7 | unsigned 0–255 | voice attenuation, each count = 0.25 dB (0 = unity) |
| `$35` | harmonic 0–63 | signed six-bit in C[5:0] | detune (`−32..+31`)/64 of fundamental |
| `$36` | harmonic 0–63 | unsigned six-bit in C[5:0] | phase-diffusion intensity 0–63 |
| `$39` | ignored | ignored | clear all detune/stochasticity/attenuation state |

Original voice type 3 selects an experimental pseudo-random white excitation only while unlocked. When locked, it retains its previous behaviour. **This has not been shown spectrally flat yet.**

### Coefficient arithmetic

A separate 18-bit modulo phase offset `P[h]` is updated **once per harmonic pair**:

```
P[h] := P[h]
      + arithmetic_shift_right(signed6(detune[h]) * unsigned18(freq_increment), 8)
      + signed8(prbs_byte) * unsigned6(stochasticity[h])
        (mod 2^18)
```

The upper 14 bits of `P[h]` are added to both sine arguments of the harmonic, retaining phase continuity and a stable centre frequency at stochasticity zero. The arithmetic uses the voice frequency increment, not its wrapped oscillator phase. Zero coefficients must leave legacy audio bit-exact.

Logarithmic per-voice attenuation subtracts 32 AMY log units per coefficient step, with underflow forced silent; the frequency subcycle bypasses attenuation.

### RAM structure

M9K3 uses `128 x 36`: addresses `0..63` original 30-bit harmonic state plus six detune bits; `64..71` existing voice phase; `72..87` four six-bit stochasticity values per word; `88..119` two 18-bit phase offsets per word. No new port or extra cycle of AMY time is requested, but **this layout requires >=9 system-CLK edges per CE** (14 are available at 8.192 MHz). Valid-bit flags logically zero the new state after reset or `$39`. All access scheduling and block inference need Quartus confirmation; **the four-M9K count is a target, not a new measurement**.

### Integration

- Add `vhdl/amy1_ext_phase.vhd` to the Quartus project file list **before** `amy1_core.vhd` (direct entity instantiation).
- Use the supplied complete `vhdl/` directory (all other original sources are included).
- No `DETUNE_MEM_PROBE` remains; `$D2C7` is now the extension-control register.
- Default `ENGINE_UNIT_LOG2=15`: 8 ms engine time unit at 8.192 MHz.
- Note-engine instrument memory format is unchanged. **New coefficients are currently programmed through ordinary host A/B/C commands, not embedded in instrument entries**. Updating the instrument format would be a separate backwards-compatible revision.
- Non-packed `amy1_mem(rtl)` is legacy-only; extension-coefficient paths are implemented only for the packed memory architecture.

## Combined test suite

Requires **GHDL with VHDL-1993 support** and Python 3. See `README_VHDL93.md` for the portable testbench limitations. From the root:

```sh
bash test/revc/run_combined.sh
```

This compiles a frozen clean Stage 1 baseline and the new candidate in separate libraries, runs two directed unit testbenches, compares their full legacy sample traces and PCM for representative command sets (including 40-harmonic mode) at 8.192 MHz, verifies unlock-with-zero-coefficients is unchanged, and renders new-feature PCM reports for attenuation, detuning, diffusion, noise and combined commands.

The new-feature audio traces are **smoke tests, not proof of correct acoustics**. Quantitative spectrum/level tests still require a controllable single-voice instrument and a successful GHDL run. A warning of no PCM difference means that stimulus did not exercise an audible contribution, not that the feature is validated.

For Python-only checks (available here):

```sh
python3 test_stage1.py
python3 test/revc/test_reference.py
python3 test/revc/static_interface_check.py
```

### Quartus acceptance checklist

1. Compile the actual MAX 10 10M16 build with the new unit in the QSF.
2. Report: **Total logic elements**, registers, combinational cells, memory bits, embedded 9-bit multipliers, **physical M9K count**, worst setup slack, any unconstrained paths.
3. Compare against your previous **13,792 LEs / 551,936 memory bits / 51 multiplier elements**, noting those numbers are from the **detuning-memory probe**, not the present multi-feature RTL.
4. Confirm the harmonic memory stays in one inferred M9K and total AMY footprint stays four M9Ks. Quartus may reject 36-bit packaging or map logic differently due to the additional read/write schedule.
5. Run hardware sound tests with extension locked, unlocked with zeros, and each coefficient independently. Use a consistent 8.192 MHz pitch table for all comparisons.

## Known outstanding validation questions

- This candidate has **not** been compiled by an HDL compiler here (GHDL and Quartus are unavailable). Only Python source/interface checks and reference arithmetic have run.
- Audio quality of the white PRBS output and the phase-diffusion spectrum are unmeasured.
- How the added memory read stages affect Quartus M9K inference and timing is unknown.
- Attenuation alignment with the audio pipeline and selection of harmonic 0 should be confirmed in waveform traces (note the voice-register path remains an independent storage array).
- `$37`/`$38` are not yet allocated. No coefficient readback is available via the host in this candidate.
- The programme interface is provisional pending regression and hardware results, **not yet a final amendment to the Rev C programmer specification**.
