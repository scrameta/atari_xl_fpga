# AMY1 behavioural specification

This is the spec for the hand-maintained AMY1 core: what each functional unit does, how it is timed,
and which of the original chip's quirks it keeps. It was written block by block with the stage-2 rewrite;
a chapter is marked ✅ once its block has been rewritten and checked against the netlist core. All are.

Sources: the 1983 AMY 1 spec binder (programmer's view), the Dec 1985 SILOS netlist (`SYNCHRO.NET`,
"AMY1 version 3 including host sync modifications") and its `ISSUES.RNO`, and measurements on the
netlist-exact core.

---

## 1. Conformance

**The spec first** (decided 3 Nov 2026). The reference is the 1983 AMY 1 spec. Where the spec is silent,
the netlist decides: the stage-1 split core, which is the netlist statement for statement and was
checked sample for sample against the switch-level model. No software was written for AMY in its day
and the chip was never finished, so simplicity and clarity come before the netlist's edge cases. A
netlist quirk that contradicts the spec, or only adds complexity, may be fixed. Every deviation is
listed in section 5 (D-numbers), with a test showing it stays inside its case.

**Phases of the rewrite.**
* **Stage 2:** each schematic block rewritten behind its netlist boundary, exact.
* **Phase A:** the units regrouped by function with clean interfaces. Still the pins and six-step
  clock, and still sample-identical to the netlist core, apart from D3.
* **Phase B:** one register per chip clock (`ce`), a synchronous register port, logical RAM
  addresses. Done (section 6): exact against phase A when the host accesses are replayed on the
  same chip clocks.
* **Next:** the spec-first fixes, one at a time.

**Verification ladder:**

1. Stage 2: block co-simulation. The new block and the stage-1 block get the same inputs inside the full
   core. Every output is compared at every step. Phase A: the host reads and every RAM write (address,
   data, step) are compared with the stage-2 core (`tb_amy1` READ_FILE and TRACE_FILE).
2. Full-core regressions, which must be sample-identical:
   * quickclr_spec and rich_spec, against Verilator;
   * cmds_noise;
   * the drum test `drums/nzf` with `NOISE_FIX` on and off.
3. Phase B: **aligned replay.** The phase-A core is run with the command files and logs, per chip
   clock, when each command's busy starts, when reset ends, every sample and every RAM write.
   `mkreplay.py` turns that into a schedule that writes each command to the phase-B core two clocks
   before its busy started in phase A. Samples, host reads and RAM writes must then be identical.
4. Phase B: **unaligned.** `amy1_top` (FIFO, RDY handshake) with phase A and with phase B inside. The
   commands now land on different chip clocks, so the report measures that shift and compares the
   audio by short-time spectrum and level (section 6).
5. For a deliberate deviation, a targeted test shows that the difference stays inside the quirk case.

---

## 2. Clocking and timing

### 2.1 The chip clock and registers

The core has one clock enable, **`ce`**: one internal chip clock (CLOCK / 2, 4 MHz at the spec's
8 MHz). Every register updates on `clk` when `ce` is high, and nothing else is clocked. The PokeyMAX
wrapper makes `ce` once every six steps of its step generator (375/896 of 57.344 MHz gives 24 MHz of
steps, so a 4 MHz `ce`), or from PHI2 ticks.

The chip's registers are two-phase: they sample at the end of CLKN and show the new value from CLK.
Each is one register here. The macros are DREG/DREG1/DREGR (load-enabled), DL (always loads) and
TOG (toggle with reset). Where the chip computes something combinationally from a register (a ROM
address folded from a latched argument, say), the rewrite keeps that order: register, then logic.
The register's initial value then gives the same power-up behaviour.

**Memories.** The core gives each memory an address, write enable and data in every chip clock, and
takes its read data in the same clock:

* the address presented in chip clock n has its data before the `ce` that ends clock n;
* a write enabled in clock n happens at that `ce` (read before write within the clock).

So `ce` must be low on at least one `clk` before each `ce` (the `rtl` memory layout reads in between),
and on at least two for the packed layout (4 M9Ks, which take the address on the first `clk` after a
`ce`). The wrapper's `ce` is at least six clks apart.

**Register port.** `addr`, `we`, `wdata` write a register at the `clk` edge (any `clk`, `ce` or not);
`rdata` is the addressed register. A command written in chip clock n is busy from clock n+2 (4.7).

**Timing closure.** All paths are `ce`-to-`ce`. On the PokeyMAX (10M16) the design closes timing at
57.344 MHz with no multicycle constraint (a multicycle of 6 on the `ce` registers would also be valid).

**What phase B removed** (phase A still had them, to stay pin-exact): the six steps (PRECH, CLK,
T10MHZ, CLKN), the `tick` and `sample` enables, the CLKN latches (the sample strobe, end40, the RAM
write strobes) and the two T10MHZ flip-flops of the host handshake, the pin cycles (CSN, RDN, WRN, DB
with its charge, the SAMP pins with SAMP0 multiplexing, OE) and the test pins.

### 2.2 Slots and the sample period

A **slot** is four internal clocks, P0–P3. Each slot handles two harmonics: CNT, the harmonic counter,
advances at P0 and at P2. A sample period has 32 slots in 64-harmonic mode (128 clocks) or 20 slots in
40-harmonic mode (80 clocks).

| | P0 | P1 | P2 | P3 |
|---|---|---|---|---|
| CNT | 2s | 2s | 2s+1 | 2s+1 |
| HADR (harmonic RAM address) | 2s | 2s+1 | 2s | 2s + ODDEV |
| noise row | load address s | read row s | – | write row s |

(s = slot number. Measured on the reference core in 64-harmonic mode.)

* `SYNC` is high in P3 of the last slot.
* `ODDEV` toggles every sample period. It picks the noise generator processed in that period.
* `ZEROB` is never high during P3.

At 8 MHz a sample period is 32 µs (31.25 kHz) with 64 harmonics and 20 µs (50 kHz) with 40.

---

## 3. Number formats

| quantity | format |
|---|---|
| frequency destination | 13 bits, 1/64 semitone per unit (an "ATARI tone"), 128 semitones; A 440 = `$138C` |
| frequency current value | 18 bits: the destination's 13 bits plus 5 fraction bits (1/2048 semitone) |
| amplitude destination | 8 bits, 1/4 dB per unit, 0 = silent, 255 = 63.75 dB |
| amplitude current value | 13 bits, 1/128 dB per unit (destination × 32) |
| slope byte | bit 7 sign; bits 6–5 rate (00/01/10/11 = once every 128/32/8/2 samples); bits 7,4–0 a 6-bit two's-complement step, −31..+31 (sign 1 with mantissa 0, i.e. −32, is "not allowed") |
| voice type | 2 bits: 0 harmonic, 1 noise generator 0, 2 noise generator 1, 3 illegal |
| noise word | 12-bit two's complement (B10..B0 + BSIGN) |
| HS (sine_rom output) | 13-bit two's complement |
| output | 17-bit two's complement sample (`sample`; the chip's latch is offset binary, bits 16 and 15 inverted) |

A slope of 0 in a breakpoint write means "jump": the destination becomes the current value.

---

## 4. Functional units

| unit (`amy1_<unit>.vhd`) | schematic block | role | memories | stage 1 (in/out/step regs) | status |
|---|---|---|---|---|---|
| host_interface | BUS | command register, registers A/B/C | – | 62/45/213 | ✅ phase B |
| command_unit | SEQCONT 16–18 | reset, handshake, decode, SCR/SOR, INT/RDY, read-back loads | – | – | ✅ phase B |
| timebase | SEQCONT 15, 17 | counters, slot phases, voice and sample strobes | – | – | ✅ phase B |
| ram_addressing | SEQCONT 15, 18 | harmonic and voice RAM addresses | – | – | ✅ phase B |
| envelope_generator | ENVGEN | 72 envelope generators, noise add, voice types, LHP flags | HARMBRKPOINT 64×16, HARMCURNTVAL 64×13, LHPRAM 64×1, VOICE18 16×18, VOICE3 16×3 | 63/96/498 | ✅ rewritten |
| exp_rom | XROM | exponential ROM: log value → linear | XROMBS 128×15, XROMINT 128×5 (OCTSPL 32×4 no longer read) | 20/30/215 | ✅ rewritten |
| phase_generator | PHASE | per-voice phase accumulators, harmonic arguments | PHASERAM 8×20 | 34/17/256 | ✅ rewritten |
| sine_rom | SINROM | sine lookup with interpolation | SROMBS 256×17, SROMINT 512×5 | 19/15/170 | ✅ rewritten |
| output_accumulator | ACC | output accumulator and sample latch | – | 20/34/123 | ✅ rewritten |
| noise_generator | NOISE | two noise generators | NOISE 64×3 | 24/21/198 | ✅ rewritten |

The data path runs:

```
host → host_interface → command_unit ─┐
                          timebase ─────┼→ envelope_generator → exp_rom → phase_generator → sine_rom → output_accumulator → sample
                    ram_addressing ─────┘        ↑ noise word
                                          noise_generator
```

### 4.1 noise_generator (NOISE) ✅

Two band-limited noise generators share one 64×3 RAM. File: `amy1_noise_generator.vhd`, about 300
lines, 81 flip-flops.

**Ports.**

| group | ports |
|---|---|
| clocking | `clk`; `ce` (registers update; the RAM write happens at it) |
| timebase | `p(0 to 3)` slot phase; `sync` last slot; `odd` generator of this period; `sel40` 40-harmonic mode |
| ram_addressing, command unit | `hadr(5 downto 0)` harmonic address; `host_mode` (NZINIT); `cmd` (the command); `host_data(2 downto 0)` (Reg A 2..0) |
| to the command unit | `host_wr`: the Noise RAM host write (P2 of a WR_NOISE command, one clock later) is happening |
| envelope generator | `noise_gen` (the voice's generator); `mute` (ZEROB); `noise(11 downto 0)` out, two's complement |
| test | `serial` (BOUT, the serial sum; unconnected) |
| Noise RAM | `ram_addr(5 downto 0)`, `ram_we`, `ram_wdata(2 downto 0)`, `ram_q(2 downto 0)` |

The block owns the Noise RAM: it writes its own write-back data and the host's (from Reg A, in NZINIT
mode). The netlist sent the write-back data out as NOMXA, round the host interface's NRIN mux and back;
that path is gone.

**RAM layout.** RAM address = row × 2 + not gen. The command's Noise RAM address is the RAM address
with bit 0 inverted, so even command addresses belong to generator 0. Bit 2 of a word is column A,
bit 1 is B, bit 0 is C.

| rows | contents |
|---|---|
| 0–14 | three 15-bit pseudo-random registers PRB A, B, C; bit i at row 14−i |
| 15 | shift overflow (unused) |
| 16 | the random bits of the last pass |
| 17–19 | (unused) |
| 20–31 | UD up/down counter (column A), VAL noise value (column B, "B" in the 1983 spec), SHIFT control (column C, "S"); bit i at row 20+i |

**What it computes.** Each generator is a second-order random walk:

* The three 15-bit pseudo-random registers give three random bits per pass, ra, rb and rc: the XOR of
  each register's taps, bits 14, 11, 6 and 0.
* The up/down counter steps by ra + rc − 2·rb, from −2 to +2: UD += ra + rc − 2·rb.
* The noise value integrates it: VAL += UD (the new UD).
* SHIFT picks the bits of VAL that make the output word. Each selected bit, LSB first, is shifted into
  an 11-bit output register. At the end of the pass the word is {VAL bit 11, the output register}, so
  it is the last 11 selected bits under VAL's sign bit.

So the host sets bandwidth and level by the RAM it loads. In the unrepaired netlist the
pseudo-random registers never get their feedback (Q3), so the random bits repeat with the 15-pass
shift.

These identities were checked against the bit-level model (`amynoise.py`) on 2,000 random RAM states.

**A pass.** One generator is processed per pass, the two alternately: one row per slot, rows 0 to 31.
With 64 harmonics a pass is a sample period: row s in slot s, the generator chosen by ODDD (ODDEV
latched). With 40 harmonics see "40 harmonics" below. In each row:

* **P0.** Load the row address. While the address still points at the previous row, three things happen:
  * if that previous row is a tap (0, 3, 8 or 14), the random bits take its data, XOR style;
  * `upper` latches whether the previous row was ≥ 16;
  * `first` (CNT20 in the netlist) latches whether the previous row was 0, 4, 16 or 20, the LSB of a word.
* **P1.** Read the row into `data`. Latch the two adder carries. For rows < 16, also move the previous
  row into `prev`.
* **P3.** Write back. When the row's SHIFT bit is 1, shift the new VAL bit into the output register.

**Write-back data**, chosen from the previous row and this row:

| condition | data written | rows |
|---|---|---|
| previous row ≥ 16 | arithmetic: (UD sum, VAL sum, SHIFT unchanged) | 17–31 and 0 |
| this row < 16 | previous row (the shift) | 1–15 |
| this row ≥ 16 | the random bits | 16 |

**Arithmetic** (bit-serial, LSB first). The UD step is an operand word plus a carry-in at the LSB:

| random bits | operand | carry-in | step |
|---|---|---|---|
| rb = 1 | −2 (LSB 0, upper bits 1) | ra or rc | −2 or −1 |
| rb = 0 | +1 (LSB 1, upper bits 0) | ra and rc | +1 or +2 |
| ra = rb = rc | 0 | 0 | 0 |

The VAL adder adds the new UD bit, with its carry cleared at the LSB.

**Output.** At the pass end, outside host mode, the word {VAL bit 11, output register} is taken
(`held`), and as the next sample period starts it becomes word 0 (generator 0) or word 1 (generator 1),
NOI1/NOI2 in the netlist. With 64 harmonics that is the next clock; the netlist loaded the word one
clock earlier, at `sync_d`, but in that clock the noise is muted (ZEROB, voice 0 starts every period),
so no sample differs. `noise` = (gen_sel ? word 1 : word 0), or
zero when `mute`. `serial` is the VAL adder's sum.

The output register is shared by the two generators and is never cleared. With fewer than 11 SHIFT bits
set, the low bits of a word are left over from earlier passes, including the other generator's (Q13).
With SHIFT bit 11 set, VAL bit 11 appears twice, as bits 11 and 10.

**40 harmonics (D7, fixes Q6).** A 40-harmonic period has only 20 slots, so the netlist processed rows
0–19 and never the UD, VAL and SHIFT rows: the noise voices did not work. Here, with `sel40`, the block
counts its own rows (`nrow`, one per slot, across the period boundaries) and its own generator
(`ngen`, toggled at each pass end), and the pass end is P3 of row 31 instead of SYNC. A pass is still
32 slots, 128 chip clocks, so each generator updates every 256 clocks in both modes and the noise is
the same random process; the new word waits for the next period, so all harmonics of a voice see one
word in a sample. After NZINIT a pass starts at row 0. Switching from 64 to 40 harmonics carries on
the pass in progress (`nrow` tracks the slot with 64 harmonics).

**Host mode.** The address comes from `hadr`, loaded at P2. The write strobe is the host strobe
and the data is `host_data`. The sequencer only asserts the host strobe in P3, so a host write never
meets the P1 read.

**RAM port.**
* `ram_we` = (host_mode ? the host strobe : P3); the write happens at the `ce` that ends the clock.
* The row is read into `rd` at P1.
* `ram_wdata` = (host_mode ? host_data : the write-back data). In the netlist this was an open-drain bus
  shared with the read data, so it only matches the netlist while `ram_we` is high, which is the only
  time it is used.

**Checked.**
* Co-simulation against the stage-1 block: every output identical at every step after the first step
  of power-up (`ram_wdata` while `ram_we` is high). In the first step the netlist's uninitialised slave
  nodes show their inverse.
* The runs were quickclr_spec, rich_spec, cmds_noise, and drums/nzf with and without NOISE_FIX.
* D7 (40 harmonics): the drum test with 64 and with 40 harmonics, every pass against the bit-exact
  model `test/noise/amynoise.py` (all 32 row writes of 399 passes) and every output word (386), both
  identical (`tools/noisecheck.py`). With 64 harmonics the aligned replay stays exact, and the drum
  test's noise words and samples are unchanged; quickclr_spec with 40 harmonics is sample-identical
  to the build before (no noise voice). Rows written per pass: all 32 in both modes (before: 0–19 with
  40 harmonics). Yosys: 72 LUTs and 81 FFs (before 48 / 59).
* Full-core runs with the new block are sample-identical too.
* Yosys, generic 4-LUT: 46 LUTs + 58 FFs, against 188 LUTs + 117 FFs for the stage-1 block.

### 4.2 envelope_generator (ENVGEN) ✅

The 72 piecewise-linear envelopes: 64 harmonic amplitudes and 8 voice frequencies. It also adds the
noise and drives LOG to exp_rom. File: `amy1_envelope_generator.vhd`.

**RAM words.**
* Harmonic: breakpoint (HARMBRKPOINT) = destination 8 + slope 8; current value (HARMCURNTVAL) =
  13 bits.
* Voice: one word (VOICE18 + VOICE3) holds the breakpoint (destination 13 + slope 8); the other holds
  the current value (18 bits) and the voice type (2 bits).

**The RAMs are the envelopes' state**, and this block owns them: it writes the new values and the
host's breakpoints, LHP flags and voice types. The addresses come from ram_addressing.

| write | when |
|---|---|
| harmonic current value | the envelope update, the clock after P2 |
| harmonic breakpoint (WR_HARM: slope = A, destination = C) | P1 of the command, one clock later |
| LHP flag (WR_LHP: CMND0) | P1 of the command, one clock later |
| voice current value | the update in P0 of an `upd_freq` period, one clock later |
| voice breakpoint / type (WR_FREQ, WR_TYPE: B:C, A) | P3 of the command, one clock later |

Each write enable is a register; the write happens at the `ce` that ends its clock. A RAM is read whenever its group is not
written. `host_wr` tells the command unit that a host write is happening (the end of the command).

**Buses.**
* Inside the block, the RAM data and the write data meet on the H bus (30 bits: LHP flag H0, slope
  H8..1, destination H16..9, current H29..17) and the F bus (21 bits), as in the chip: a 0 from any
  driver wins. The RAM write data is the bus.
* The chip precharges the buses in the first half of the clock and its latches sample them at the end
  of CLKN. That equals the bus as driven, without the precharge, so the registers here take it at `ce`.

**Latching**, with value = harmonic source or voice source:

| what | from | loaded |
|---|---|---|
| slope mantissa, rate, sign | H8..1, or F7..0 with P2X | except in P3 |
| destination 12..5 | H16..9, or F15..8 in P2 | except in P3 |
| destination 4..0 | F20..16 (cleared outside P2, P3) | except in P3 |
| current value 17..5 | H29..17, or F15..3 in P3 | except in P2 |
| current value 4..0, voice type | F20..16, F1..0 | on `ld_flo` |

**Stepping.**
* new = current + step. The step is the slope's 6-bit signed mantissa (−31..+31):
  * an amplitude adds it at bit 5, the LSB of the 13-bit amplitude;
  * a frequency (P0) adds it at bit 0 of the 18-bit value, below the 13 destination bits, with the
    carry from the 5 fraction bits.
* A mantissa of 0 is a jump: new = destination.
* `upenff` enables the write-back: a jump, or a step when the sequencer's rate counter allows it
  (`ssen`: every 2/8/32/128 sample periods by the rate bits) and the value is not at its destination. A
  frequency compares all 13 destination bits, an amplitude the top 8. The compare is for equality
  only, so a slope pointing away from the destination runs the value round through the whole range
  (Q2). At the destination the value just stops being written, so it stays there.
* The new value goes back on the bus for the sequencer to write, H29..17 or F20..3.
* A harmonic jump (WR_HARM with a zero mantissa) also loads the current value with the destination
  (×32) at once, in the clock of the breakpoint write, as the 1983 spec says ("loaded immediate into the
  HA current value field"). The netlist applied it only at the harmonic's next update, which is every
  other sample period (P3 is 2s + ODDEV), so a second write before then replaced it (Q1, fixed 5 Nov).
  The next update still applies the jump as before.
* A frequency jump (WR_FREQ with a zero mantissa) likewise loads the voice's current value with the
  destination (fraction 0), as the spec says ("loaded immediate into the FF current value field of the
  VRAM"; fixed 6 Nov). The breakpoint and current value are separate voice words, so this is a second
  write, in the P1 straight after the breakpoint write (P0), to the command's voice and word 0
  (`fjump`; ram_addressing). If the envelope updates a voice in that P1, the jump's write takes the
  clock and that voice's step waits for its next update.

**Noise and LOG.**
* The noise word (12-bit, sign-extended) is added to the 13-bit amplitude. On positive overflow the sum
  saturates to all ones; a negative result is flagged. This is one clock late.
* LOG = the noise-added value when NV, P0 or P2, otherwise the current value. NV is the sequencer's ZEROB
  (the noise word muted) one clock later.
* The measured effect is roughly a ring modulation, signed and asymmetric: gain about +0.84 at
  B = −2048, 0 at 0, and −4.9 at +2048. If level×32 + B > 8191 the gain is −0.587, and below 0 the
  harmonic is muted.
* `gen_sel` (CVNL1) gives the voice's noise generator to noise_generator.

**FAN** silences a harmonic, through exp_rom's 6-clock `clrdisp`:

    enaorf = not P0 and not (P2 and not NV)
    FAN    = (P1 and NV) or (enaorf and LOG(12..5) = 0)
             or (not enaorf and (harmonic voice or noise sum < 0 or last LOG(12..5) = 0))

**Also:**
* the Last Harmonic Pair pulse (LHPULSEN: H0 at P0, not in reset, one clock late; or P1 with CLRPH);
* the slope-rate bits SS1..0 to the sequencer;
* the read-back value: `readback(12:8)` for B (F15..11) and `readback(7:0)` for C (F10..3, or H29..22
  for a harmonic), latched in P2.

**Checked.**
* Co-simulation: every output identical at every step after the first 12.
  * The buses are compared while their RAM is written.
  * LOG, FAN, UPENHA and UPENFF are compared outside step 1. In the netlist model, LOG12 and UPENHA
    show one-step transients there, and all four are only sampled later (UPENHA and UPENFF by the
    sequencer's CLKN latches).
  * Register initial values follow the netlist's power-up state: its DREG2 and DLN cells come up 1.
* Full-core regressions: see section 6.
* Yosys: 306 LUTs and 93 FFs, against 709 LUTs and 311 FFs for the stage-1 block.

### 4.3 exp_rom (XROM) ✅

The log-to-linear converter: a 13-bit log value in, an 18-bit linear value out, 5 clocks later. File:
`amy1_exp_rom.vhd`.

**Function.** The log unit is 1/768 octave, which is 1/64 semitone for frequencies.

* log(12..8) + 1 = 3 × octave + third. The netlist does this divide by 3 with a 32-entry ROM (OCTSPL).
  The rewrite computes it, so OCTSPL is no longer read; it was checked equal for all 32 entries.
* The position in the octave is third × 256 + log(7..0), 0 to 767.
* mantissa = base(third, log(7..3)) + interp(slope, log(2..0)), wrapping at 11 bits.
  * The base ROM is XROMBS, 128 × 15, 96 words used. It holds an 11-bit mantissa and a 4-bit slope
    per 1/96 octave.
  * The interpolation ROM is XROMINT, 128 × 5, holding slope × fraction.
* xo = ((2048 + mantissa) × 64) >> (10 − octave). In the netlist this is a pass-transistor barrel
  shifter decoded from the octave.

**Pipeline**, one stage per clock:

1. latch log;
2. octave and third, then the base ROM address;
3. base data, then the interpolation address;
4. interpolation data;
5. add and shift, giving xo.

FAN rides alongside and comes out as `clrdisp`, 6 clocks later.

**Ports.**
* `log(12..0)`, `fan` in; `xo(17..0)`, `clrdisp` out.
* The shift travels down the pipeline as the netlist's octave code (octave + 5, so 5 to 15). Codes
  below 5 occur only in the power-up state; they select no shift, and xo holds.
* `base_addr`/`base_q` and `int_addr`/`int_q` for the two ROMs.
* The adapter makes the test-mode read-back drivers (XO7..0 onto IB with TST1) from `xo`.

**Checked.**
* Co-simulation: every output identical at every step from step 30. Before that, the netlist model's
  shifter nodes float and show a power-up transient (Q12).
* Full-core regressions: see section 6.
* Yosys: 76 LUTs and 93 FFs, against 419 LUTs and 214 FFs for the stage-1 block. The divide by 3 is
  a 32-entry constant table: written as `/` and `mod`, Quartus built a 74-LE divider for it.

**Quirk.** The v1 chips had a ROM address polarity error and missing ROM implants. Both are fixed in this
netlist.

### 4.4 phase_generator (PHASE) ✅

The voice phases and the two sine arguments of each harmonic. File: `amy1_phase_generator.vhd`.

**Voice phase.** Each voice has a 20-bit phase in the phase RAM, which has 8 words. The sequencer pulses
`ld_voice` on the first clock of a voice's harmonics. Then, one clock apart:

| clock | what happens |
|---|---|
| +1 | read the voice's phase φ |
| +2 | φ′ = φ + xo, where xo is the voice's frequency increment at this clock; the harmonic phase register h takes φ′ |
| +3 | write φ′ back |

In the chip the write strobe is a CLKN latch; here the write is enabled in the clock after the add
(`ram_we` = the delayed load) and happens at its `ce`. After the write the RAM is read again, and every second clock h += φ′, so h = k·φ′ for harmonic k.

**Two lookups per harmonic.** `sel_h` alternates, so each harmonic takes two clocks, a and b.
* At a, the argument is θ + ½ cycle, where θ = h(19..6).
* At b, the argument is θ + d(b−1) − d(a). d is `disp`, which is xo(17..8) latched each clock and
  cleared by `clrdisp`. It is formed with ones' complements: at a, dsum = d + not dsum; at b, the
  argument is not dsum.
* The output accumulator adds the two sines: sin(θ + δ) − sin θ = 2·sin(δ/2)·cos(θ + δ/2), with
  δ = d(b−1) − d(a).

So the amplitude enters as the displacement between the two lookups, the "argument formation" of the
1983 block diagram; with δ = 0 the pair cancels exactly. Which xo value lands on which clock, and so on
which harmonic, is decided by the envelope generator. That is to be documented with it. In a trace of
quickclr, `disp` was cleared on every clock except the two at a voice start.

**Harmonic offset.** The bit-reversed harmonic number cnt is added to the top 6 bits of every
argument, so the harmonics do not all start in phase. Harmonic 1 is offset half a cycle, harmonic 2 a
quarter, and so on.

**clrph** clears h. In HALT mode this zeroes the phases of the selected voices.

**Ports.**
* `ld_voice`, `voice(2..0)`, `cnt(5..0)` (CNT6..1) and `clrph` from the sequencer.
* `xo(17..0)` and `clrdisp` from exp_rom.
* `arg(13..0)` to sine_rom.
* The phase RAM port.
* `clk`, `ce`.

**Checked.**
* Co-simulation: every output identical at every step after the first 12. `ram_wdata` is compared while
  `ram_we` is high, and SARG from step 2: in the netlist it comes from precharged adders and is wrong in
  steps 0 and 1. The netlist's power-up value of the write strobe latch (on) is kept, since it writes
  phase RAM word 0.
* Full-core regressions: see section 6.
* Yosys: 189 LUTs and 53 FFs, against 386 LUTs and 162 FFs for the stage-1 block.

### 4.5 sine_rom (SINROM) ✅

The sine of a 14-bit phase: 13 bits out, 4 clocks later. File: `amy1_sine_rom.vhd`.

**Function.** arg(13) is the half, arg(12) the quarter.

* One quarter wave is stored. a = arg(11..0), inverted in the even quarters: quarters 0 and 2 read the
  table backwards.
* mag = base(a(11..4)) + interp(slope, a(3..0)), wrapping at 12 bits.
  * The base ROM is SROMBS, 256 × 17. It holds a 12-bit magnitude and a 5-bit slope.
  * The interpolation ROM is SROMINT, 512 × 5.
* hs = {sign, sign ? not mag : mag}, with sign = arg(13) xor arg(12). This is a ones' complement
  negation: −mag − 1. The output accumulator adds the missing 1 for negative values (4.6), so in the
  sum it is exact.

**Pipeline**:

1. latch the argument; folding the quarter gives the base address;
2. base data, then the interpolation address;
3. interpolation data;
4. add and sign, giving hs.

The argument came from precharged adders in stage 1, so stage 2 captured it at the end of CLKN into an
input latch. The hand-written phase generator's argument is valid for the whole clock, so it is taken
at `ce`, with identical samples.

**Ports.**
* `arg(13..0)` in; `hs(12..0)` out.
* `base_addr`/`base_q` and `int_addr`/`int_q` for the two ROMs.

**Checked.**
* Co-simulation: every output identical at every step after the first 12.
* Full-core regressions: see section 6.
* Yosys: 38 LUTs and 81 FFs, against 221 LUTs and 169 FFs for the stage-1 block.

### 4.6 output_accumulator (ACC) ✅

Sums the sine values into samples. File: `amy1_output_accumulator.vhd`.

**Function.**
* Every clock: acc = (load ? 0 : acc) + hs + (hs < 0 ? 1 : 0). It is 17 bits. The carry-in turns
  sine_rom's ones'-complement negatives into two's complement, so a harmonic's two lookups cancel exactly
  when they are half a cycle apart.
* On `load` (LDSAMP: not ILDSAMPN, or TST), the total is latched as the sample, and the sum restarts with
  this clock's hs.
  * SUM mode: one load per period.
  * INDIVIDUAL mode: one per voice.
* `sample` is the latch as two's complement. (The chip's latch is offset binary, with bits 16 and 15
  inverted, so silence is $8000 on its SAMP15..0 pins; SAMP0 carried bit 16 during OUTSTB. Phase B has
  no pins.)
* `sample_stb` (amy1_core) is high for the one chip clock in which OUTSTB starts; `sample` is the new
  value from that clock on. `sample_v0` marks voice 0 in INDIVIDUAL mode.

**Checked.**
* Co-simulation: every output identical at every step after the first 12. The OUTSTB latch keeps the
  netlist's power-up value (active).
* Full-core regressions: see section 6.
* Yosys: 81 LUTs and 34 FFs (phase A, with the pins: 102 / 51), against 181 LUTs and 102 FFs for the
  stage-1 block.

### 4.7 sequencer: timebase, command_unit, ram_addressing ✅

The netlist draws the sequencer on five pages (SEQCONT 15–19). Stage 2 first rewrote it page by
page; phase A regrouped it by function into three units. The pages' RAM write control moved into
the envelope generator, which owns those RAMs (4.2). Their test pads went too: the core has no pins
for them.

| file | does |
|---|---|
| `amy1_timebase.vhd` | clock, sample and voice counters; P0–P3; period end and sync; voice and sample strobes |
| `amy1_command_unit.vhd` | reset synchroniser, command handshake and busy, decode, SCR and SOR, INT/RDY, read-back loads |
| `amy1_ram_addressing.vhd` | harmonic and voice RAM addresses |

Types shared between the units are in `amy1_pkg.vhd`:

* `host_cmd_t`: the decoded command `op` and its harmonic, voice, word and LHP bit.
* `config_t`: NZINIT, CLRPH, INT mode, INDIVIDUAL mode, SEL40H.

**Timebase.**
* `cnt`, 7 bits, counts the clocks of the period. cnt(6:2) is the slot, and P0–P3 are cnt(1:0) one
  clock late (reset forces P0).
* The period-end decode is cnt = 125 (64 harmonics) or cnt = 77 with SEL40H (40 harmonics). It clears
  the voice counter. Two clocks later `sync` (or RST) restarts `cnt` and advances the sample counter, so
  a period is 128 or 80 clocks.
* The sample counter `sam`, 7 bits: bit 0 is `odd`. `ssen`, the envelope's slope enable, is on every 2, 8,
  32 or 128 samples (slope rate 11, 10, 01, 00: sam(k:1) = 0).
* The voice counter `cntv`, 3 bits, advances on each last-pair pulse and stops at 7.
  * `new_voice` marks a new voice (or the period end).
  * `upd_freq` = new_voice and (cntv(0) xor odd): each voice's frequency envelope is updated every
    other period, odd and even voices alternately.
  * `voice` is cntv taken at P1.
* Strobes:
  * `zerob` mutes the noise word from a new voice's P0 to P3; `nv` is zerob one clock later.
    `ld_voice` follows in P3, and `ld_flo` loads the voice's low frequency bits and type.
  * The sample is taken (`ld_samp`, P0) two slots after a voice load: for every voice in INDIVIDUAL
    mode, for voice 0 in SUM mode. `outstb` follows two clocks later.
  * `v0` marks voice 0's sample in INDIVIDUAL mode, held to clock 15.
  * `newout` marks the period in SUM mode, from the clock-77 decode to one clock after sync.

**Command unit.** `reset` (synchronous, active high) is registered once to give RST; the netlist's
two T10MHZ flip-flops before it are gone. While
a command executes (`busy`), CMND decodes as:

| CMND | `op` | CMND | `op` |
|---|---|---|---|
| 11hhhhhh | RD_HARM: read harmonic amplitude | 00011vvv | RD_FREQ: read frequency |
| 01hhhhhh | WR_HARM: write harmonic breakpoint | 00001vvv | WR_FREQ: write frequency breakpoint |
| 10hhhhhh | WR_LHP (SC1 = 0) or WR_NOISE (SC1 = 1) | 00010vvv | WR_TYPE: write voice type |
| 0011xxxx | SCR (done here) | 0010xxxx | SOR (done here) |

* SCR: bit 0 run, bit 1 NZINIT request, both cleared by reset. They take effect at SYNC. CLRPH (the
  phases are cleared) = not running, or reset.
* SOR: bit 1 INT mode, bit 2 INDIVIDUAL mode, bit 3 SEL40H; cleared by reset (READY, SUM, 64
  harmonics). Bit 0 (ALE mode) has no pins here and is ignored.
* Handshake: writing CMND sets a request (`req_reg`, at the write's `clk` edge). It passes two
  registers (SEQ1D, SEQB2); SEQB2 sets the busy latch and clears the request. `busy` is the latch and
  its copy one clock later. A command written in chip clock n is busy from clock n+2. (The netlist
  had two T10MHZ master-slave flip-flops before SEQ1D to synchronise the asynchronous host write; the
  register port is synchronous, so they are gone. Measured in phase A, busy came two or three clocks
  after the clock in which the write cycle ended, depending on the write's phase.)
* SCR and SOR are done while SEQB2 is high. A write command ends with its RAM write (the envelope's or
  the noise generator's `host_wr`), a read with the load of B. Busy ends two clocks later.
* INT/RDY: READY mode = no command pending or busy and not in reset, `not (req or SEQ1D or bsy or RST)`; INT mode = the
  end-of-command pulse. Phase B counts the pending request too, so RDY falls in the clock after the
  command write (in the netlist only from SEQ1D on: a host that polled RDY at once could see it high
  and overwrite the command; phase A's replay found 5–6 such races per test). This is spec-first: the
  spec's READY means the chip will take a new command.
* Read-back (RD_HARM, or RD_FREQ outside the voice's update): `ld_rc` loads C at P3 and `ld_rb` loads B
  at P1 of the following slot, from the envelope's `readback` value. This overwrites B (Q11).

**RAM addressing.**
* Harmonic RAMs (and the Noise RAM row in host mode): (cnt(6:2), halsb), where halsb = P0, or P2 of
  odd periods. In P2 of a host harmonic command (CLK latch) it is the command's harmonic.
* Voice RAMs: (cntv, not P2X), or the command's voice and word (P1 of a frequency read, P3 of a voice
  write).
* The addresses are logical. The netlist drives the envelope RAMs' address lines inverted; phase B
  drops that, so the memory image holds the harmonic and voice words in logical order (word h is
  harmonic h, word v voice v's).

**Netlist fixes already in v3:** reset forces P0, with one clock in each P-time after it (note 8); the
ZEROB flip-flop has a reset (note 6); the voice counter LSB cell (note 4); host command
synchronisation (ISSUES 50).

**Chip-clock state.** The ZEROB and V0 gate latches and the CLKN latches (the sample strobe, end40)
of phase A are chip-clock registers in phase B; `ld_samp` = P0 and the delayed voice load.

**Checked.** Section 6. Yosys: timebase 51 LUTs / 38 FFs, command_unit 40 / 17, ram_addressing
14 / 2 (phase A: 55 / 43, 48 / 25, 15 / 3).

### 4.8 host_interface ✅

The command register and registers A, B, C. File: `amy1_host_interface.vhd`.

| A1 A0 | write | read |
|---|---|---|
| 0 | command register CMND | FF |
| 1 | A, 8 bits | A |
| 2 | B, 5 bits | B (bits 7..5 read 1) |
| 3 | C, 8 bits | C |

* A synchronous port: `we` writes `wdata` to register `addr` at the `clk` edge; `rdata` is the
  addressed register (combinational). The command register reads FF.
* A read command loads B and C from the envelope generator's `readback` (`ld_rb`, `ld_rc`).
* The block gives the other units the register values: `reg_a` (slopes, Noise RAM data), `reg_b:reg_c`
  (destinations, voice type), `cmnd` and `cmd_wr`.
* The netlist's internal bus IB, with its read-back and test sources, is gone, and so are the pin
  cycles (CSN, RDN, WRN, DB). The 6502 bus adaptor is outside the chip (amy1_top).

**Deviation D3.** In the netlist, the envelope generator reads Reg A through IB, so a host access
during a command wired-ANDs into the command's data. Here it reads `reg_a` directly. The only other
visible difference is the netlist's power-up write (before the first clock): it writes voice word
15 with IB's pull-up value, and here it writes A's value. (Phase B has no power-up write: the
core starts in reset.)

**Checked.** As 4.7. Yosys: 32 LUTs and 29 FFs (phase A, with the pin cycles: 76 / 37).

---

## 5. Quirks and decisions

Keep = the rewrite reproduces it. Fix = deliberate deviation, behind a generic, with the default shown.

| # | quirk | where | decision |
|---|---|---|---|
| Q1 | **Lost jump.** A jump (slope 0) takes effect when the envelope generator next updates that harmonic, every other sample period. A second write to the same harmonic before then replaces it, so the jump never happens; a decay written next then points the wrong way and wraps (Q2), a loud blat. | envelope_generator | **Fixed 5 Nov for harmonics** (the spec says "loaded immediate"): the jump loads the current value with the breakpoint write. Phase B's fast bus made it frequent with the note engine (beeps in amyconv's Warhawk). **Frequency jumps fixed 6 Nov** the same way (a second voice-RAM write in the P1 after the breakpoint). |
| Q2 | **Wrong-way slope.** A slope pointing away from its destination wraps through the 13-bit range and arrives from the other side, which comes out as a loud blat. | envelope_generator | **Keep.** Software always points slopes at the destination. Candidate fix: saturate at the range ends. |
| Q3 | **PRB never gets feedback.** SELXOR lags one row, so row 0 is rewritten by the arithmetic path, and the feedback toggles land in row 16 where nothing reads them. The pseudo-random registers become shift registers and the noise turns into a buzz. | noise_generator | **Fix: D1 `NOISE_FIX`, default on.** Row 0 is written with the XOR of rows 0, 3, 8 and 14 from the generator's previous pass, a maximal LFSR with period 32767. It is off while NZINIT is set and for the first pass after it. It is implemented in `amy1.vhd` on the RAM port. It could move into noise_generator as a generic. |
| Q4 | **NZINIT name clash.** Two nets named NZINIT meant two drivers, and a Write Noise RAM hung. | netlist | **Fixed** in generation (`fixnzinit`). |
| Q5 | **Noise spikes.** Without S bit 11 set, the noise word reaches ±2048 and spikes into the overflow region. | noise_generator, envelope_generator | **Keep.** It is a property of the data; software chooses S (`$80F`/`$FFF` keep \|B\| ≤ 1024). |
| Q6 | **Noise needs 64 harmonics.** In 40-harmonic mode the sequencer visits rows 0–19 only. Rows 20–31 (UD/BB/S) are never processed, so the noise voices do not work. The 1983 spec offers both modes and noise voices with no such restriction. | sequencer, noise_generator | **Fixed: D7.** The noise passes run on their own row counter with 40 harmonics (4.1). |
| Q7 | **Noise gain shape.** Adding B in the log domain gives an asymmetric, ring-modulation-like gain, with a clamp above 8191 and a mute below 0. | envelope_generator | **Keep.** It is the sound. |
| Q8 | **Ones'-complement sine.** sine_rom negates by inverting the magnitude (−mag − 1). | sine_rom, output_accumulator | **Keep.** The accumulator's carry-in adds the 1 back, so sums are exact and silent harmonics cancel to 0. |
| Q9 | **SAMP0 pin multiplexing.** The pin carries bit 0 or bit 16 depending on OUTSTB. | output_accumulator | **Gone** with the pins (phase B): `sample` is the latch. |
| Q10 | **Power-up state.** The noise RAM, the LHP flags and the phases are never reset. | all | **Keep.** The FPGA loads the deck's power-up image, so runs are reproducible. The spec's initialisation (voice types for all voices, amplitudes to zero, LHP flags) is required. |
| Q11 | **Read HA modifies Reg B** (spec 7.5.4). | sequencer, host_interface | **Keep.** |
| Q12 | **Power-up transient of the netlist model.** In the stage-1 model, every node starts at 0. For the first step the latches show their inverse, and exp_rom's floating shifter nodes show junk for 4 clocks. | all | **Not preserved.** Registers start at their reset-free power-up values. No output sample differs. |
| Q13 | **Shared output register.** The noise output register is shared by both generators and never cleared. With fewer than 11 SHIFT bits, a word's low bits come from earlier passes, including the other generator's. | noise_generator | **Keep.** It only adds a little more noise. |

**Deviations in force:**
* D1 `NOISE_FIX` (Q3).
* D2 (phase A only): with OE off, the SAMP pins held the value of the last clock in which they were
  driven. Phase B has no pins.
* D3: the envelope generator and the noise generator take Reg A directly, not through the IB bus. In
  the netlist a host register access during a command wired-ANDs into the command's data (the spec
  requires the host to wait for READY). The test modes (TEST pin, TST0..2) and ALE mode are not
  modelled.
* D4 (phase B): the register port is synchronous and the T10MHZ synchroniser is gone, so a command is
  busy two clocks after the clock of its write (the netlist: two or three after the end of a write
  cycle that is itself at least two clocks long).
* D5 (phase B): READY falls in the clock after a command write, not two clocks later, and is low
  while the reset is still in effect (RST, the chip clock after `reset` falls), when a command
  would be dropped (4.7).
* D6 (phase B): the envelope RAMs' address lines are not inverted; the memory image is reordered to
  match (word h = harmonic h).
* D7 (spec first): with 40 harmonics the noise generators run full 32-row passes (Q6).

---

## 6. Status and checks

**Phase B**: one `ce`, the synchronous register port, logical RAM addresses, both memory layouts.

*Aligned replay* (`tb_amy1b`, schedule from the phase-A logs by `mkreplay.py`): in quickclr_spec,
rich_spec, the read-back test with host reads and the drum test with NOISE_FIX on and off, the samples,
host reads and every RAM write (chip clock, RAM, address, data) are identical to phase A, with the
packed memories at 3 and 4 clks per `ce` and the `rtl` memories at 2 and 4.

*Unaligned* (`amy1_top` at 375/896 of 57.344 MHz, phase B against phase A, `timedev.py`):

| test | busy start, B − A (chip clocks) | samples identical | spectrum error (64-sample frames), median / max | level, max \|ΔdB\| |
|---|---|---|---|---|
| quickclr_spec | median −4, −75 .. −3 | 210 of 212 | 0.000 / 0.061 | 0.36 |
| quickclr_spec, 40 harmonics | median −4, −75 .. −3 | 20 of 339 | 0.029 / 0.039 | 0.20 |
| rich_spec (SUM, and INDIVIDUAL with all voices on both channels) | median −4, −75 .. −3 | 57 of 651 | 0.002 / 0.079 | 0.59 |
| rich_spec, INDIVIDUAL, voice 0 left, voice 1 right | median −4, −75 .. −3 | 57 of 651 | 0.001 / 0.091 | 0.34 |
| read-back (writes only) | median −5, −139 .. −3 | 82 of 82 | – | 0 |
| drums, NOISE_FIX | median −33, −108 .. −3 | 30 of 424 | 4.0 / 30 | 29 |
| drums, NZINIT release delayed 100 clocks | median −8 | 60 of 424 | 0.24 / 0.52 | 1.4 |

* Every command executes, in the same order. (Until 4 Nov the first command after reset did not:
  amy1_top wrote it in the chip clock after releasing `reset`, while the core's registered RST still
  cleared requests, and RDY said ready. The SOR command that starts every test was lost, which the
  default SOR value hid; a program starting with INDIVIDUAL or 40 harmonics would have lost the
  setting. Fixed both ways: RDY is low while RST is (D5) and amy1_top waits one more chip clock
  after reset. The deviation report had been dropping phase A's extra busy as D3's power-up write.) In steady state each is 3–4 chip clocks earlier: up to one
  from the synchroniser (D4), the rest from the wrapper's old pin cycle (WR low for two clocks). Bursts drain faster through the
  FIFO, so the shift grows to 75–140 clocks inside a burst.
* An earlier command moves oscillator phases and envelope steps by a few clocks, so samples stop being
  identical, but the spectra agree to 0.2% (median) and the levels to 0.6 dB.
* The drum test differs most, by design of the noise: NZINIT ends at the first SYNC after the SCR
  command. Here that is one sample period earlier, so the other generator runs first and every noise
  value after it is a different realisation. With the SCR held back 100 clocks (same SYNC as phase A),
  the noise matches to within the usual timing differences. The Noise RAM host writes themselves are
  identical.
* Read-back through amy1_top: 45 of 48 values identical; the other 3 are amplitude reads of rising
  envelopes, taken earlier or later after the run command.
* amy1_top with the note engine: every chip write identical to the engine model (16 x 4, 8 x 8, 4 x PHI2,
  CLK / 8), no jump followed by a write within a sample; the engine edge tests identical.

* Noise with 40 harmonics (D7): every pass and every output word identical to the bit-exact model,
  with 64 and with 40 harmonics (4.1).

* Packed memories (5 Nov): every read registered, PHASERAM in M9K 3. The whole check above is
  unchanged, and `amy1_top`'s output is bit-identical to the build before.

* Immediate harmonic jumps (Q1 fix, 5 Nov): in every aligned replay the RAM writes equal phase A's
  apart from the added current-value write at each jump (66-78 per test, about 120,000 others
  identical; `test/q1check.py`). Samples differ in one burst of 2-3 samples where the jumps land.
  Warhawk frames 1-50 and 790-845 through `amy1_top` with the engine: 33 and 36 lost jumps, 5 and 7
  amplitude wraps before; no wraps after. Engine system tests and noise checks pass.

* Immediate frequency jumps (6 Nov): apart from the added writes (2 per test) and the envelope write a
  jump displaces in its clock (0 or 1 per test), every RAM write equals phase A's except PHASERAM: a
  frequency applied up to two periods earlier gives that voice a lasting phase offset (the spectra
  match; rich_spec, which has no such offset, is identical including PHASERAM). Warhawk frames 1-50:
  2 lost frequency jumps before, none after; no frequency wraps either way.
* Wrong-way slopes over whole tunes (`test/engine/dircheck.py`: the engine model's writes, jumps
  immediate): Draconus, Zybex and Warhawk in full, 278,598 harmonic and 32,907 frequency breakpoints,
  none pointing away from its destination. So Q2 (wrapping) is not reached by the engine.

Yosys (flattened, 4-LUT, memories outside): 815 LUTs and 514 FFs with D7 (793 / 492 before it; phase A
899 / 534); longest path 16 LUT levels. On the PokeyMAX (the build before D7 and the reset fix):
works, timing closed at 57.344 MHz without a multicycle constraint, 88% utilisation.

**Phase A** (`work/phaseA`): twelve units, hand-written `amy1_core.vhd`, no generated logic.
Against the stage-2 core (itself sample-identical to the netlist core), in quickclr_spec, rich_spec,
the read-back test with host reads (`cmds_readback_rd.txt`), and the drum test with NOISE_FIX on and
off:

* the samples are identical;
* the host reads are identical;
* every RAM write (step, RAM, address, data) is identical, apart from D3's power-up write.

Yosys (flattened, 4-LUT, memories outside): 899 LUTs and 534 FFs, against 970 / 558 for stage 2
and 2,202 / 1,437 for stage 1; the longest path is 16 LUT levels. The blocks and the core are strict
VHDL-93.

---

## 7. Stage 2: rewrite order and checks

Order, simplest first: noise_generator ✅ → exp_rom ✅, sine_rom ✅ → output_accumulator ✅ → phase_generator ✅ →
envelope_generator ✅ → sequencer ✅ (seq_pads, seq_commands, seq_ram_control, seq_timing, seq_counters) →
host_interface ✅.

A block's rewrite is done when:

* it has clean ports (vectors, one polarity, meaningful names), wired to the core by an adapter in
  `stage2_wiring.py`;
* the co-simulation shows every output identical at every step (any difference is a listed deviation);
* the full-core regressions are sample-identical;
* its chapter here is complete.

**Status.** Every block is hand-written; `amy1_core.vhd` is only their wiring and adapters. With all twelve in the
core:

* co-simulation (quickclr_spec, rich_spec, the drum test, the read-back test, and cmds_noise for the
  noise generator) shows every output identical at every compared step (see each block's chapter for
  its comparison window);
* the full-core regressions are sample-identical to the netlist core: quickclr_spec, rich_spec, and the
  drum test with NOISE_FIX on and off;
* the whole core (Yosys, flattened, 4-LUT, memories outside) is 970 LUTs and 558 FFs, against 2,202
  LUTs and 1,437 FFs for stage 1; the longest path is 16 LUT levels (stage 1: 18).

Co-simulation harness: `splitgen.py` writes `cosim/amy1_core_cosim.vhd`. In it, each hand-written block's
stage-1 version (`ref/amy1_<unit>_ref.vhd`) drives the core and the new block runs alongside through its
adapter, and it reports `MISMATCH <net> step <n> ph <step>`.
