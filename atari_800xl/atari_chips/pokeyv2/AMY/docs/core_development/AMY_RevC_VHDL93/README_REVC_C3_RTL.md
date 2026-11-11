# AMY Rev C — C.3 RTL changes

Patches, all applied with `patch -p1` from the folder that contains `vhdl/`:

| Patch | Contents |
|---|---|
| `revc_engine.patch` | **New: the engine extensions (§5 below) only.** Apply on top of `revc_prop.patch`. |
| `revc_prop.patch` | Proportional envelope mode (§4 below) only. For a tree that already has the C.3 changes, such as your local one. |
| `revc_c3_rtl.patch` | Everything, against `AMY_RevC_Combined_VHDL93_next_reg` as sent. |
| `revc_aux2.patch` | Everything except `revc_white_noise.patch`, for applying on top of it. |

The patched VHDL files are also included under `vhdl/`.

## 1. White noise and exponential diffusion (spec §7.1, §7.4)

Same as `revc_white_noise.patch`. It touches `amy1_ext_phase`, `amy1_envelope_generator` and `amy1_core`.

- **White noise:** a type-3 voice gets a full-circle random phase step every sample, and the log-level noise path is no longer used for it.
- **Diffusion:** the step is now `r × (8 + s[2:0]) << s[5:3]`, and s = 0 adds exactly nothing.

## 2. Slot alignment and RMW forwarding (both from the 8 November session)

This RTL doesn't have the `revc_slot_align` fix, and the white-noise vector exposed that.

**The problem.** `phase_slot` came straight from `cnt(6:1)`, so each harmonic's detune, diffusion and phase offset landed on the harmonic 4 slots away.

**Why nothing caught it:**
- The existing `detune` vector detunes harmonics 0–7 all by the same +16, which hides the shift.
- In the `white` vector, the randomised offsets were those of a silent voice, so the output was byte-identical to legacy. That's the "white produced no PCM change" warning.

**The fixes:**
- **`amy1_core`:** `phase_slot` is now an 8-stage, `ce`-clocked delay of `cnt(6:1)`, and `white_sel` goes through the same delay (as `white_slot`) before ext_phase. Both now refer to the harmonic the phase generator is looking up.
- **`amy1_mem_packed`:** the core's read-modify-write at `ce` merges `harm_hold`, which is read at e1, before the extension detune write at e8. If both hit the same harmonic word, the new detune is now forwarded into `harm_hold`, so it can't be undone.

## 3. Extension page in M9K 3, and XPAGE (spec §6.8)

- **`amy1_mem_packed`:** M9K 3 grows from 128 to 256 words of 36 bits. That's the same block, since Quartus already used a whole M9K for 128 × 36. Words 128–255 belong to a new **aux2 port**, which uses the same handshake as the existing aux port:
  - **Reads** are granted in any clock in which the core neither reads M9K 3 (e1–e5, e7) nor uses `harm_rd` in the next clock. At 14 clocks per chip clock that leaves 8 free clocks; at the Rev C minimum of 9 it leaves 3.
  - **Writes** take the lowest priority of the write mux. Words 128–255 are never part of a core read-modify-write, so a write only needs the port to be free.
  - The core's own addressing just gets a leading `0`.
- **`amy1_mem`:** the entity gets the aux2 ports, with defaults. The reference `rtl` architecture ties its acks to 0: the extension page exists in the packed layout only.
- **`amy1` and `amy1_top`:** aux2 is wired from the engine to the memory. `amy1_top` now asserts the Rev C minimum of 9 clocks per chip clock (`2*STEP_DEN >= 3*STEP_NUM`, when not `USE_TICK`).
- **`amy1_engine`:**
  - `CONFIG` bit 2 is `XPAGE`, and `CONFIG` reads back bits 2:0.
  - With `XPAGE` set, `ADDR`/`WRITE` go to extension word `ADDR`, 0–127; higher addresses are ignored. Busy covers the pending write.
  - The engine doesn't read the page yet: instrument select, note-on and retrigger behaviour for §6.8 is the next step.
  - The `AUX2_STRESS` generic is for tests only and defaults to false. When true, it drives an aux2 read and write in every clock.

No new M9K. The extra logic is a few address and data muxes, one pending flag and the `CONFIG` bit.

## 4. Proportional envelope mode (spec §7.6)

`revc_prop.patch` touches three files:

- **`amy1_host_interface`:** latches B bit 7 (`reg_b7`). B still reads back as before, and read commands don't change bit 7.
- **`amy1_core`:** wires `reg_b7`, the RAM addresses and `prop_clear` (reset or `ext_clear`, i.e. reset, lock, timeout or `$39`) to the envelope generator.
- **`amy1_envelope_generator`:**
  - **Flags:** 64 harmonic flags and 8 voice flags, in flops. The RAM words have no spare bit. Each flag is written at the ce of its breakpoint write (`enwrbp`, `enwrvi`) with `reg_b7 and ext_enable`, and read combinationally from the same address as the RAM. So it is latched into `prop_reg` in the same clock as the slope, and needs no extra pipeline.
  - **Step:** with `prop_reg` and `ext_enable` set and a non-zero slope, the new value is `cur + ((dst − cur) >> k)`, k = A[3:0], with a minimum of +1 when the difference is positive. (An arithmetic shift of a negative difference is never 0.) A frequency works on all 18 bits against `dst & "00000"`; an amplitude works on its 13 bits against `C × 32`.
  - **Unchanged:** the arrival compare, the write enables, the rate counter (`ss_reg`, from A[6:5]) and the jumps for A = 0. Without the flag the legacy adder output is selected, so the legacy path is untouched.
- **Cost:** about 72 flag flops, a 19-bit subtract, a 0–15 barrel shift and a 19-bit add, roughly 250–300 LEs (an estimate; I can't run Quartus here). No M9K. The subtract, shift and add are one combinational path between ce-enabled registers. If it limits Fmax at 57.344 MHz, it can take a multicycle constraint, since ce comes every 14 clocks.

## 5. The engine's use of the extension page (spec §6.8)

`revc_engine.patch` touches `amy1_engine`, plus one line in `amy1_top` (`ext_enable` to the engine) and the test bench `tb_engine`. All new behaviour needs `ext_enable`, which is sampled per event. While locked, the engine's command stream is identical to before.

- **Instrument select:** the engine reads the extension header and sends `$10+v` (voice type) and `$34` (trim). Then, for each slot of the voice, it reads the coefficient word and sends a jump to 0, `$35` (detune) and `$36` (diffusion), and keeps the slot's two proportional flags (128 flip-flops).
- **Note-on:** the engine reads the header after the base header.
  - **Pitch:** with a pitch offset, the frequency breakpoint becomes a jump to `note + 16 × offset` (clamped to 0–8191), then a proportional breakpoint to the note, with A = rate and B bit 7 set.
  - **Harmonics:** every harmonic breakpoint now carries B: A, B, C and the command, with B bit 7 set when the slot's attack or decay flag applies. That covers the "B is a register" problem from §7.6.
- **Retrigger:**
  - **Arming:** after a note-on with a count, the engine writes the level, band limit, count, period and due time to extension word 16 + v, and sets a pending bit.
  - **Firing:** each 1/8 unit (1 ms), when the queue is empty, it reads each pending voice's word. When the voice is due, it runs the attack and decay passes again without the frequency, then writes the next due time (previous due + period, so there is no drift).
  - **Cancelling:** any event on the voice clears its pending bit.
  - **Busy:** `STATUS` busy stays set while repeats are pending.
- **The push sequencer is generalised:** `st_push` now takes "send B" and "send C" flags, a command byte and a return state, so the new pushes reuse it. The legacy pushes come out byte for byte the same.
- **Cost:** about 230 flip-flops (128 of them flags), two 64:1 flag muxes, a 15-bit add and clamp for the pitch start, and two 11-bit time adders. That's roughly 400–500 LEs (an estimate; there's no Quartus here). No new memory.

Software has to upload every extension word an instrument uses, including the zero ones, because the page is not cleared by reset. My first system test forgot this and got a garbage pitch offset on an instrument with no extension data. This was already in the spec; I've made it explicit in the test.

## Verification (GHDL 4.1, `--std=08 -frelaxed`)

**Engine extensions** (`test/engine`, all added to `run.sh`):

| Test | What it covers | Result |
|---|---|---|
| `test_eng_ext.py` (engine alone, both layouts) | A four-voice kit: a kick with pitch envelope, trim, detune, diffusion and both flag kinds; white noise with 3 repeats 2 units apart; a negative pitch offset with 2 repeats, the second cancelled by a note-off; an instrument with no extension data; a second kick; a note whose repeats are cancelled before the first. Every push is compared with `engmodel_x.py`. | Identical (1752 and 984 pushes) |
| | Repeat spacing | 32768 / 32768 clocks (first 32749), as specified |
| | The same host writes with `EXT` false, against the original `engmodel` | Identical |
| `sys_eng_x.py` (`amy1_top` at 8.192 MHz, unlocked through `$D2C7`, both layouts) | The chip writes against the model, without the `$34`–`$36` command bytes, which execute in `amy1_top` | Identical (1620 and 916) |
| | No harmonic is written again within a sample of a jump | Holds |
| | The kick's pitch, read back from the chip: +1442 falling to +1121 (1/64 semitone) over 2 ms | −0.0081 per update, against −0.0078 for k = 7 |
| Legacy engine suite: `test_eng_edge`, `sys_eng` (both layouts), the 6 songs × 6 ensembles × 2 layouts matrix | | Identical to the model, as before |

**Proportional mode** (`make_prop_vectors.py`, `check_prop.py`, now part of `run_combined.sh`). The tests read back the current value every 25,000 time units while one envelope runs. Every reading must lie on the integer recursion of §7.6, within one update of a fitted line, and the fitted rate must match the slope's interval (E = 3: 2 samples):
- frequency 4000 → 5000 with k = 4, then 5000 → 4900 with k = 2, arriving at 4900 and staying
- amplitude 40 → 200 with k = 4, then 200 → 0 with k = 2, arriving at 0
- locked: B bit 7 is ignored, so a linear +4 per update
- unlocked: a proportional glide (+121, +106, +94 …) turns linear after `$39`

All legacy and feature checks below still pass with this change: bit-exact legacy, bit-exact after unlock with zero coefficients, `check_revc_c3`.

**Earlier C.3 checks:**

**Baseline:** `test/revc/run_combined.sh` on the white-noise RTL gives:
- legacy `cmds_quickclr_spec`, `drums`, `drums40` and `rich_spec` bit-exact against the frozen Stage 1 reference (samples, PCM and register reads)
- bit-exact after unlock with zero coefficients
- `tb_ext_phase` (updated for C.3: exponential steps, s = 0 exact, white ±, white bypass while locked) and `tb_ext_memory` pass

**Changes to the regression script:** it now compiles as VHDL-2008, copies `amy1_mem.hex` into the work folders, and drops `ghdl -e` (mcode elaborates on `-r`). These are needed with GHDL 4.1. The "VHDL-93" sources use non-static port-map actuals, which only VHDL-2008 allows.

**C.3 pass/fail check:** `check_revc_c3.py` runs on the new `detune_h0` vector (harmonic 0 only) and on the `white` vector. It checks that:
- harmonic 0 moves from 1070 to 1340 Hz while harmonic 1 stays at 2140 Hz
- white leaves no line at 1070/2140 Hz (40% of the energy before, 1.2% after)
- white has the same power as the tone (RMS ratio 0.95)

The RTL as sent fails the alignment and white checks; this RTL passes all four. Legacy stays bit-exact against the frozen reference, before and after unlock with zero coefficients.

**New directed benches** (in `test/revc/`):
- **`tb_aux2`:** aux2 at 14, 10 and 9 clocks per chip clock. 128 writes and 128 reads round-trip, and no read is ever granted in a core clock.
- **`tb_xpage`:** the engine's `CONFIG` readback; an `XPAGE` write reaching aux2 with the right address and data (`$67600000`, the spec's kick header); `ADDR` ≥ 128 ignored; busy held until accepted; `XPAGE` = 0 still writing the base page.

**System stress:** all 12 regression vectors (4 legacy, enabled-zero, and the att/detune/stoch/white/all/reset/lock features) are run on the new RTL with `AUX2_STRESS` true. Every `.samples`, `.pcm` and `.reads` file must be byte-identical to the baseline. That shows aux2 traffic in every free clock never disturbs the core.
