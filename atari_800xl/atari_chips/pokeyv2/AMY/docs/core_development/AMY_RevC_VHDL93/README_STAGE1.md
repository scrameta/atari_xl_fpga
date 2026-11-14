# AMY FPGA Rev. C — Stage 1 experimental synthesis patch

**Basis:** 6 November 2026 `amy1_vhdl_6nov_fjump.zip` plus the already Quartus-fitted 36-bit harmonic M9K detuning *storage probe*. The **detuning hardware is not yet implemented**. The probe generic defaults to `false` to preserve normal `$D2C7` reads.

## Functional scope

- At power-on and on a chip-reset request, extensions are disabled. Old synthesis is selected by default.
- `$D2C7` **write `$A5`** enables Rev. C extensions; **write `$5A`** disables them. All other `$D2C7` writes are ignored. **Reads still return the original status** (busy/FIFO-full). This encoding is *experimental*, not a frozen Rev. C register assignment.
- With extensions enabled, voice type `3` (`11` binary) uses an independent 16-bit maximal-length LFSR to supply a pseudo-random signed 12-bit word to AMY's existing logarithmic amplitude-noise path. Voice types `0`, `1`, and `2` are unchanged. When disabled, type `3` continues to follow its *previous undefined-type implementation*, not the new white path.
- The LFSR updates once per harmonic slot (`P0`, outside Noise RAM initialization). It is independent of the two legacy Noise RAM generators and does not need new RAM accesses. **This is an experimental broadband excitation source, not yet verified as spectrally flat white-noise audio**. The downstream oscillator and amplitude architecture is unchanged.
- `amy1_top` defaults to 8.192 MHz effective main AMY frequency with `STEP_NUM=3`, `STEP_DEN=7`, at 57.344 MHz `CLK`. The note-engine divider default is 15 (8 ms quantum). If your PokeyMAX top-level supplies explicit generic values, change them there too.

## Replace / compile

Replace the **seven files** in your project `vhdl/` directory with the seven files in this archive's `vhdl/` directory: `amy1_top.vhd`, `amy1.vhd`, `amy1_core.vhd`, `amy1_envelope_generator.vhd`, `amy1_noise_generator.vhd`, `amy1_mem.vhd`, `amy1_mem_packed.vhd`. The other source files stay unchanged. The archive contains these seven replacement files plus a unified patch against the original November 6 project. **Don't regenerate these from `gen/vhdlgen.py`.**

For a first low-risk Quartus fit, enable `MEM_PACKED => true`, `DETUNE_MEM_PROBE => false`, and retain existing I/O and PLL settings. Check the clock settings in the PokeyMAX top-level. **Not yet compiled in this environment.**

## 6502 example

```asm
; $D2C7 only acts as the extension configuration writer.
LDA #$A5
STA $D2C7             ; enables Rev C type-3 random excitation
; Set an AMY voice's type to 3 using the ORIGINAL voice-type command
; and its existing A/B/C operand convention.
; ... original 6502 AMY programming ...
LDA #$5A
STA $D2C7             ; revert to legacy mode
```

Do not use this as a production software contract until command allocations are reviewed.

## Verification already performed

- Python static wiring/enable checks (`python3 test_stage1.py`).
- Complete 65,535-state LFSR period and 12-bit histogram range checks.

**Not performed:** HDL compilation, GHDL simulation, byte-level CPU protocol tests, legacy sample-stream regression, audio spectrum/RMS analysis, Quartus resources and timing. These are required before calling Stage 1 complete. Because the new word drives a logarithmic envelope path, listen and analyze the output before describing it as white noise.

## Quartus checkpoints

- Confirm still four AMY M9Ks (61/61 total in PokeyMAX) and no new inferred RAM block.
- Confirm timing meets the constraints with `STEP_NUM=3 / STEP_DEN=7` and engine divider 15.
- Check status reads at `$D2C7` are unchanged (probe generic off).
- Verify `$D2C7` enable/disable, voice type 3, and that voice types 0–2 sound identical with extensions on/off.
- Capture a long type-3 sample and compute frequency-domain power / RMS. Compare to the old two noise types.

## Next stage

After validating the type-3 excitation's spectrum, adjust the algorithm if needed to obtain genuinely broadband noise, then add per-voice attenuation, detuning, stochasticity and the final original-command-compatible extension interface.
