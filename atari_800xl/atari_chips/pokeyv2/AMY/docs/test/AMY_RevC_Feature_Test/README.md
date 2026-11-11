# AMY Rev. C — hardware audio feature test (8.192 MHz)

This package contains an **Atari executable (`AMY_FEATURE_TEST.xex`)**, which plays **37 sequential diagnostic sounds** through PokeyMAX `$D2C0–$D2CF`. Its intended purpose is to capture the output as a WAV and investigate each legacy and new synthesis feature individually and in selected combinations.

## Running it

Load `AMY_FEATURE_TEST.xex` from DOS or an Atari XEX loader on your PokeyMAX-equipped 6502 Atari. Keep the Atari OS VBI clock running; this test is not suitable for a no-OS bare-metal loader. The program reads the PAL/NTSC video mode and uses the system video-frame clock, **not a cycle-counted delay loop**.

- Initial approximately one-second silence to arm your recorder (plus startup initialization).
- Then each of **37** segments is **0.500 seconds ON**, **0.100 seconds muted**.
- Duration from the first audible onset to the final mute: approximately **22.1 seconds**. Including pre-roll and the final gap: approximately **23.2 seconds**.
- On PAL the ON/OFF interval is **25/5 frames**; on NTSC **30/6 frames**.
- Each segment resets and reconfigures AMY **while globally muted**, so previous voices and extension coefficients cannot accidentally contaminate the next test. The note engine is disabled between tests.
- No keyboard interaction or file I/O is needed. The program mutes at the end and returns to the loader.

**Expected machine:** AMY Rev. C candidate from `AMY_RevC_Combined_VHDL93_next_reg.zip`, at **8.192 MHz**. The extension unlock is `$A5`, `$5A` written to `$D2C7`, then `$34` / `$35` / `$36` / `$39` through normal A/B/C/command writes. If your RTL differs, rebuild from the source generator.

## Test groups

The precise segment list is in **`MANIFEST.csv`** (also JSON). The sound types are:

- **Core (15):** sine, two/four/eight-harmonic timbres, attack and decay, upward/downward frequency glide, original noise generator 0/1, 40/64-harmonic modes, global level, stereo independent voices, mixed noise+tonal voices, note-engine playback.
- **Extensions (9):** unlocked zero-parameter compatibility control, illegal type-3 while locked, white excitation, −6/−12 dB per-voice attenuation, ±24/64 harmonic detuning, medium/maximum diffusion.
- **Combinations (13):** selected pairwise interactions and representative 3-/4-feature cases, including 40-harmonic operation and stereo.

There are 15 + 9 + 13 = 37 cases, rather than an exhaustive cross-product. Selected combination tests cover each new parameter with several partners, without filling the capture with redundant permutations.

## How to align a WAV capture

The CSV time column is **relative to the first sound onset**. Case 1 starts at `t0`. Case `n` is at `t0 + (n - 1) × 0.6 s` and runs for 0.5 s, followed by 0.1 s silence. Timing is quantised to one video frame (approximately 20 ms PAL or 16.67 ms NTSC). For best results, record the PokeyMAX audio output **directly**, in **stereo**, without normalisation/AGC/noise suppression, ideally as 48 kHz or 96 kHz, 16/24-bit PCM.

The optional analyzer uses NumPy:

```bash
python3 analyze_wav.py your_capture.wav
# If onset detection selects a later burst or captures other machine audio:
python3 analyze_wav.py your_capture.wav --start 1.42
```

It reports RMS level, dominant spectral peak, a broadband spectral-flatness estimate, left/right levels and the residual level in the nominal silent gaps. It generates a CSV for comparisons. No audio waveform or spectral output has been assumed to be correct before hardware testing.

### Useful cross-checks

- **1 vs 16:** original sine compared with unlocked, zero coefficients. RMS and frequency should match closely (phase need not match between independent resets).
- **1 vs 12:** `$D2C6` half volume (`$10` rather than `$20`) should lower RMS by approximately 6 dB.
- **1 vs 19 and 20:** per-voice attenuation by 6 dB and 12 dB should lower RMS by those amounts, barring unexpected logarithmic saturation.
- **21 vs 22:** signed detune +24 vs −24 should move partial frequencies in opposite directions.
- **23 vs 24:** spectral broadening should increase with diffusion coefficient, though flatness is not a definitive white-noise criterion.
- **13 and 32:** capture both stereo channels; voices are directed to different sides.
- **17 vs 18:** locked type-3 control against unlocked white excitation. Type-3 while locked is historically reserved/illegal; do not infer a guaranteed silent output from the original specification.

**Cautions:** This is an *audio feature test*, not a complete test of readable status bits, the FIFO full condition or every historical AMY command. The white-noise algorithm in the Rev. C RTL is experimental and has not been demonstrated spectrally flat. It will be useful to compare its captured spectrum with the two original noise modes. Some combinations (for example white excitation + detuning) may have little audible difference even when register programming is working, so use the command/PCM reference tests to discriminate faults.

## Source / reproducible build

- `AMY_FEATURE_TEST.asm` — generated readable 6502 source with all command streams as `.byte` tables.
- `create_test.py` — the self-contained Python generator and assembler. **No ca65/MADS dependency required.** Run `python3 create_test.py` to regenerate the `.xex`, manifest, and assembly listing under `release/`. The distributed ready-to-run `.xex` is also at the archive root.
- `validate_xex.py` — independent instruction-level 6502 runner that verifies PAL and NTSC control flow, script execution and timings. This emulates *host-side status as always ready* and does **not** simulate the AMY synthesizer or its audio.

The executable is a standard Atari load-file containing a `$4000–$92AC` segment and the RUNAD vector at `$02E0`. The program is written for a standard 6502 and has no 65C02-only instructions.
