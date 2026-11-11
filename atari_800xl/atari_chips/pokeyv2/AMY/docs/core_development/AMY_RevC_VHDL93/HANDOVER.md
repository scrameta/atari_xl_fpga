# AMY1 VHDL: handover notes (6 Nov 2026)

For continuing this work in a new session. Read with `README.md` (overview, files, verification),
`AMY1_SPEC.md` (behaviour, quirks Q1–Q13, deviations D1–D7, status) and `INTERFACE_REVIEW.md` (why the
units and interface are as they are, the decisions, phase B as built).

## 1. What this is

Atari's AMY 1 additive synthesis chip (1983–85, never shipped), rebuilt in VHDL from its Dec 1985 SILOS
netlist for **PokeyMAX** (MAX 10 10M16, 57.344 MHz system clock; AMY registers at `$D2C0`), alongside
POKEY/SID/PSG etc. in the same bitstream.

History:

1. **Stage 1:** netlist-exact generated VHDL (`gen/`: `silos2v.py`, `vhdlgen.py`, `stepcut.py`).
2. **Stage 2:** each schematic block rewritten by hand, co-simulated against stage 1, sample-identical.
3. **Phase A:** regrouped into ten functional units with clean interfaces; still pins and a six-step
   clock; sample-identical to the netlist core (`test/phaseA_ref/`). Mark's "v9".
4. **Phase B:** one clock enable per chip clock (`ce`), a synchronous register port, logical RAM
   addresses, no pins or test modes. Exact against phase A under aligned replay. Mark's "v10".
5. **Spec-first fixes:** Q3 (`NOISE_FIX`); Q6 (noise with 40 harmonics, D7, 4 Nov); the first command
   after reset was dropped (4 Nov); **Q1 lost jumps, harmonics (5 Nov) and frequencies (6 Nov)**.
6. **Size work (5 Nov):** packed memories with registered reads and PHASERAM in an M9K: −229 LEs.

## 2. The owner's decisions and preferences (Mark)

* **Spec first:** the 1983 AMY 1 spec binder is the reference. Where it is silent, keep the netlist's
  behaviour. Netlist quirks that contradict the spec or only add complexity may be fixed and listed (D
  numbers). Simplicity and clarity over netlist edge cases: no software depends on them, the chip was
  never finished.
* No pins: a plain RTL `clk`/`ce`/`reset`/register-port interface; the 6502 bus adaptor is outside
  (`amy1_top`). No test modes (TST0–2, TEST pin, ALE): use SignalTap or simulation.
* Logical RAM addresses (done). The envelope owns the envelope RAMs (they are state, not a cache).
* **Q1 fixed** (the spec says jumps are "loaded immediate"). **Q2 (wrong-way slopes wrap) kept**, agreed
  6 Nov: the spec is silent, and nothing reaches it now (section 3). Revisit only if a wrap shows up.
* Keeps the bitstream at **CLK / 8** (`STEP_NUM/DEN = 3/8`, a 7.168 MHz AMY, 28.0 kHz output), not the
  spec's 8 MHz (375/896): the players (`vbiplay_clk8.xex`, `amyconv_clk8.xex`) are built for CLK / 8.
* Possible cheap features were discussed but **not requested yet** (section 7).
* He builds in Quartus and tests on the real PokeyMAX; he reports utilisation, timing and recordings.

## 3. Current state (6 Nov)

| item | status |
|---|---|
| Package | `amy1_vhdl_6nov_fjump.zip`: everything below. Flash image `vhdl/amy1_mem.bin` unchanged since 4 Nov |
| On the board | **5 Nov Q1 build works** (harmonic jumps immediate + memory changes): the Warhawk beep at ~17 s is gone (Mark's recording). The 6 Nov frequency-jump change is **not yet built** |
| Utilisation (5 Nov Q1 build) | 13,818 LEs (87%), all 61 M9Ks used (57 sample RAM, 4 AMY). AMY: 1,966 LEs / 978 registers (4 Nov: 2,195 / 1,204), 4 M9Ks, 6 DSP 9-bit, no RAM pass-through registers |
| Timing (5 Nov Q1 build) | slow 85C setup: clk[0] (57.344 MHz) +0.244 ns; **clk[1] (114.69 MHz) −0.639 ns, TNS −2.419**; other corners pass. Failing paths not yet reported (likely clk[0]↔clk[1] crossings, not AMY). Command for Mark in section 8 |
| Yosys core estimate | 842 LUTs / 515 FFs (4 Nov: 815 / 514; phase A 899 / 534) |
| Regression | `test/run_phaseB.sh`, results in `test/results/phaseB/run_phaseB.txt` (6 Nov). Section 1's "samples/RAM writes DIFF" is by design now; the **Q1 check** line is the test |
| Q2 evidence | `test/engine/dircheck.py`: Draconus, Zybex, Warhawk in full (528 s; 278,598 harmonic and 32,907 frequency breakpoints), none pointing away from its destination. RTL monitor on Warhawk frames 1–50 and 790–845: no wraps |

What changed in this session (5–6 Nov), in order:

1. **Memories (`amy1_mem_packed.vhd`)**: every read registered (Quartus had added 92 pass-through
   registers on M9K 3 and 4); PHASERAM moved into M9K 3 words 64–71 (read at e2, written at e1). The
   first version read each RAM in two `if/elsif` branches and Quartus did not infer the RAMs (224%,
   section 8); rewritten as one write and one registered read per RAM. Bit-identical behaviour.
2. **Q1, harmonics (`amy1_envelope_generator.vhd`, `jump_now`)**: a WR_HARM with a zero slope mantissa
   also writes the current value (destination × 32) in the clock of the breakpoint write. Cause of the
   beeps: a harmonic is only updated every *other* sample period (P3 is 2s + ODDEV), so a jump could wait
   ~256 internal clocks; phase B's one-clk register writes let the engine's next pass (1–2 samples
   later) replace it; the decay then started below its destination and wrapped (Q2). Found by bisecting
   on hardware: v9 (phase A) fine, v10 (phase B) beeps; the beep was voice 2's 8th harmonic (1,568 Hz on
   note 59), harmonic 23. Phase A's slow pin bus (12+ clocks per command) had hidden it.
3. **Q1, frequencies (`fjump`, envelope + `amy1_ram_addressing.vhd` + core)**: a WR_FREQ jump writes the
   voice's current value (destination, fraction 0) in the P1 after the breakpoint write (P0), address
   = the command's voice and word 0. If the envelope updates a voice in that P1, the jump's write wins
   and that voice's step waits for its next update (at most one displaced write per test).

**Next steps:**

1. Mark builds the 6 Nov package and listens (Warhawk, and kick/tom glides, which post a jump and a
   legato glide in one frame); reports utilisation and timing.
2. Find the clk[1] slow-85C failing paths (section 8 command).
3. Features, if Mark picks any (section 7).
4. amyconv's vibrato routine writes C, B, A, CMD for each vibrato voice after one engine-idle check
   and never checks FIFO-full (bit 6); its comment assumes the FIFO drains faster than writes arrive.
   Not seen to fail, but with several vibrato voices in one frame a write could be dropped. Worth a
   look if pitch glitches appear (amyconv source: Mark's `amyconv_src.zip`, `amyconv.s` `vibrato:`).

**Environment for a new session** (cloud container; installs do not survive a new session):

```
apt-get update && apt-get install -y ghdl-mcode yosys     # GHDL 4.1 mcode backend, Yosys 0.33
pip install --break-system-packages py65 numpy            # py65: amyconv's SAP capture
```

* GHDL must be the **mcode** backend (`ghdl --version` says "mcode code generator"). The LLVM backend
  writes an executable per testbench into the work directory, so the scripts' parallel runs overwrite
  each other ("NULL access" / missing logs). If `ghdl-llvm` is also installed, `/usr/bin/ghdl` may
  pick it: check, or call the mcode binary. (Ubuntu's ghdl-llvm also wanted `libLLVM-18.so.18.1`.)
* mcode re-reads the sources at elaboration: **never edit `vhdl/` while a run is going**; run baselines
  and debug builds from separate copies.
* Yosys can't estimate `amy1_mem` (it turns these RAMs into flip-flops): use Quartus for memory-side
  sizes. The core estimate (section 5) is fine.
* Runs: `run_phaseB.sh` ~25 min on 2 cores; tb_top with the engine ~30 min per simulated second.

## 4. Interfaces and timing contracts (the facts that matter)

**Chip (`amy1.vhd`)**: `clk`, `ce`, `reset` (sync, active high); `addr(1:0)`, `we`, `wdata`, `rdata`,
`rdy`; `sample` (17-bit two's complement), `sample_stb`, `sample_v0`; `load_*` image port; `aux_*`
(note engine's port on the VOICE M9K). Generics `NOISE_FIX` (default true), `MEM_PACKED` (default true).

* Every register updates on `clk` when `ce` = 1. `ce` must be low ≥ 1 clk before each `ce` (`rtl`
  memories), ≥ 2 clks (packed). amy1_top: `ce` = every 6th step, so ≥ 6 clks apart.
* Memory contract: the address of chip clock n has its data before the `ce` ending clock n; a write
  enabled in clock n happens at that `ce`. Packed layout: e1 (first clk after `ce`) all M9K ports take
  the read address; e2 NOISE is read on M9K 2 port B, PHASERAM on M9K 3 (words 64–71), and the
  XROMINT, harmonic and VOICE data are held; writes at `ce` (merged read-modify-write for the shared
  harmonic and voice words), except PHASERAM's, which is written at e1 of the next chip clock. Every
  read is registered (one write and one read expression per RAM, for Quartus).
* Register port: writes at the `clk` edge (any clk). A command written in chip clock n is busy from
  n+2 (`req_reg` → SEQ1D → SEQB2). READY-mode `rdy = not (req or SEQ1D or bsy or RST)`; INT mode = the
  end pulse. The core's RST is `reset` registered at `ce`, so the core takes writes from the chip clock
  *after* the one in which `reset` was seen low; amy1_top's `up_reg` waits for that.
* `sample_stb` is high for one whole chip clock: count it at `ce`.
* Timebase phases: P0–P3 = cnt(1:0) one clock late. **SYNC is in P3 of the last slot**, the clock in
  which noise row 31 is written (traced: the noise word latch `sync1` is the following P0, with
  `row_reg` still 31). Working it out from the counter equations gave P2 and cost a debugging round
  on 4 Nov: trust a trace, not arithmetic.
* ZEROB mutes the noise word from a voice's P0 to P3; voice 0 starts every period, so the first clock
  of a period never sees the noise word (this is why the held-word Q6 implementation adds no change).

**amy1_top** (PokeyMAX wrapper): step generator (375/896 of 57.344 MHz = 24 MHz of steps = 4 MHz `ce`,
or `USE_TICK` from PHI2), flash loader for the image, host write FIFO (one clk per write; after a
command waits for RDY; read-backs copy B, C into shadows), chip reset after `$00–$07` or a 255-clock RDY
timeout, stereo/INDIVIDUAL mixing, volume, the note engine (`ENGINE`).

## 5. Verification and how to run it

`test/run_phaseB.sh` (about 25 minutes on 2 cores; GHDL 4.1 mcode, Python 3 + numpy). Results stored in
`test/results/phaseB/run_phaseB.txt`. Sections:

1. **Aligned replay.** `tb_amy1_log` (phase-A core, `test/phaseA_ref/`, netlist-order image) logs, per
   chip clock: each command's busy start (B), reset release (R), the host schedule (C command writes,
   W register writes, D reads), samples and every RAM write. `tools/mkreplay.py` turns that into
   `<name>_replay.txt`: each command written at (its phase-A busy clock − 2), with the command value
   phase A actually executed (5–6 per test were overwritten before execution in phase A, a netlist RDY
   race). `vhdl/tb_amy1b.vhd` replays it into the phase-B chip and logs in the same format; samples,
   host reads and RAM writes must be identical. RAM addresses in the logs are in the netlist (inverted)
   order, so tb_amy1b logs `not harm_addr` / `not voice_addr`.
2. **Unaligned**, through amy1_top with phase A and phase B inside: `tools/timedev.py` (busy-start shift
   per command, sample identity, 64-sample-frame magnitude-spectrum error, frame RMS).
   * Steady state: phase B commands 3–4 chip clocks earlier. Bursts: up to 75–140 clocks earlier,
     because **the old phase-A wrapper had a 12-clock floor per command** (4-clock pin write cycle + a
     fixed 6-clock GAP before polling RDY); the test command files write some bursts every 9.8 clocks.
   * Drums differ most: NZINIT ends one SYNC earlier, so the other noise generator runs first and the
     noise is another realisation. `cmds_drums_scr_late.txt` (that one SCR written 100 clocks later in
     the *stimulus*; nothing in the design) brings it back in line. It is a diagnostic only.
3. **Note engine** system tests (`test/engine/sys_eng.py`: 16x4, 8x8, 4 x PHI2, CLK/8): every chip write
   identical to `engmodel.py`. `test/engine/run.sh` has the longer song matrix and edge tests.
4. **Noise** with 64 and 40 harmonics: `tools/noisecheck.py` checks every pass's 32 row writes and every
   output word against the bit-exact model `test/noise/amynoise.py` (399 passes, 386 words, all equal).

Since the Q1 fixes, section 1's strict comparison reports DIFF by design (a jump is heard and read
back from the command on). **`test/q1check.py`** (run by the script, the "Q1 check" lines) is the
test: it removes the added jump writes (harmonic: an `hcv` write in the clock of a mantissa-0 `hbp`
write; voice: a `v18` write to word 0 the clock after a mantissa-0 breakpoint) and the envelope write a
jump displaces, then requires every other RAM write to equal phase A's. PHASERAM may differ after a
frequency jump (a frequency applied up to two periods earlier gives a lasting phase offset; spectra
match); rich_spec has none and is identical throughout. Samples differ in one 2–3 sample burst.

Music-level checks (need amyconv's source, Mark's `amyconv_src.zip`; set `AMYCONV` to its folder):

* `test/engine/mkwh2.py out.txt F0 F1`: a tb_top command file for Warhawk with real 20 ms frames
  (chip_init, engine RAM, start_tune, the instrument events, frames F0–F1 with vibrato), and the STOP
  value to use. Run tb_top with `-gENGINE=true -gUNIT_LOG2=15 -gSTEP_NUM=3 -gSTEP_DEN=8`.
* `test/debug/amy1_monitor.vhd.txt`: simulation-only monitor processes for a copy of `amy1.vhd`
  (LOST JUMP / WRAP for harmonics, LOST FJUMP / FWRAP for frequencies). Instructions and the
  before/after numbers are in its header.
* `test/engine/dircheck.py`: wrong-way slopes over whole tunes with the engine model (fast, frame
  resolution).

Other: `test/phaseA_ref/run_phaseA.sh` (phase A vs stored stage-2 logs); `tools/pcmdev.py`;
`tools/logimage.py` (generated image → logical order). Synthesis estimate used throughout:

```
ghdl --synth --std=08 --out=verilog <amy1_pkg + ten units + amy1_core> -e amy1_core > core.v
yosys -p "read_verilog core.v; synth -top amy1_core -flatten; abc -lut 4; opt_clean; stat; ltp -noff"
```

tb_top logging generics: `BUSY_FILE` (per chip clock: `clock CMND` at each busy start; with `NZ_ALL`, or
in NZINIT, `N clock ramaddr data` per Noise RAM write; with `NZ_WORDS`, `Z clock gen word` per new noise
word), `CHIP_FILE` (with `ENGINE`). Command files: `time addr data` per line, 5 ns units, 8 per step;
addr 8+r reads register r (logged to READ_FILE), 16+r writes engine register r. `std_logic_vector`
generics are given in binary (`-gVOICES_L=00000001`). Command files were made with `tools/mkcmd.py`
(the GENERATOR.PAS API: `Stim().system_options()`, `voice_type()`, `amplitude()`, `frequency()`...).
The drum test's script is in section 9.

## 6. Quirks and deviations (detail in AMY1_SPEC.md section 5)

* Fixed: Q3 (`NOISE_FIX`, PRB feedback), Q4 (NZINIT name clash, in generation), Q6 (D7), D5 (RDY covers a
  pending request and reset), D3 (Reg A read directly), D4 (no host synchroniser), D6 (logical addresses).
* **Q1** lost jump: fixed for harmonics (5 Nov) and frequencies (6 Nov), as the spec says.
* **Q2** wrong-way slope wraps through the range (a loud blat): kept (spec silent); not reached by the
  engine or amyconv's tunes now (section 3).
* Kept: Q5, Q7, Q8, Q10, Q11 (spec 7.5.4: Read HA modifies Reg B), Q13. Q9 and Q12 gone with the pins.
* None of Q1–Q13 is in the designers' own issue list (`ISSUES.RNO`, the version-2 chip notes); that
  list's items (host sync, ROM address polarity, reset phase, ZEROB reset, voice-counter cell) are
  already fixed in the Dec 85 netlist.

## 7. Ideas discussed, not requested

* **White-noise voice (voice type 3, "illegal" in the spec).** Amplitude is the phase displacement
  between a harmonic's two lookups: sin(θ+δ) − sin θ. Randomise θ per sample (an LFSR, same θ for both
  lookups of the pair) and each harmonic becomes white noise with its own envelope: a real snare/hi-hat
  (body = a tone voice). About 30 LUTs (estimate). Variants: re-randomise every N samples, or jitter the
  phase step instead (noise around the harmonic's frequency).
* **Per-voice level** (8 x 8-bit attenuation added in the log domain before exp_rom): velocity, volume,
  tremolo in one write. 30–40 LUTs; storage in the VOICE M9K's spare words.
* **Per-harmonic detune** (inharmonic partials): θ_k = k·φ + (e_k·φ)/2^s, so partial k is at
  (k + e_k/2^s)·f0, tracking pitch. Needs s extra high phase bits per voice (8 x s FFs: φ wraps at 2^20,
  and the fractional product must not jump there), one 18x18 multiplier (one product per harmonic per
  sample, every 2 chip clocks), 64 x 6–8 bits of table (free: 6 spare bits per word in the harmonic
  M9K, which stores 30 of 36 bits, or its unused words 64–255 with a second read per clock), 50–80 LUTs.
  The slow flash can't be read per lookup (2 M/s); it could hold preset ratio sets that the engine
  copies in. A fixed-Hz variant θ_k = k·φ + d_k·T (T a free-running 20-bit counter) gives chorus/beating
  with no extra phase bits.
* Q2 fix if ever needed: take the slope's direction from the destination (always arrives) or
  saturate at the range ends; ~20–30 LUTs. Auto-increment breakpoint writes (low priority: the engine
  already cuts the write load).
* Opt-in hooks that keep spec software unaffected: voice type 3, SOR bit 0 (ALE, unused), slope −32
  ("not allowed").

## 8. Gotchas from this work

* GHDL `.cf` libraries record source paths relative to the library directory: rebuild a library in
  place rather than copying `.cf` files elsewhere.
* `pkill -f <text>` / `pgrep -f <text>` match the shell running them; wait loops on `pgrep -f run_x.sh`
  never end.
* Senscheck-style sensitivity-list checks matter: two real bugs were missing signals.
* Phase-A logs (`tb_amy1_log`) must come from the phase-A core and the **netlist-order** image
  (`test/phaseA_ref/amy1_mem.hex`); phase B uses `vhdl/amy1_mem.hex`. Mixing them up gives false
  differences in the voice power-up values.
* The deviation report used to drop phase A's first busy as "the D3 power-up write"; it was the SOR
  command phase B was losing. That hack is gone: command counts now match exactly.
* tb_amy1b logs RAM addresses in the netlist's **inverted** order (`not harm_addr`, `not voice_addr`):
  a voice's breakpoint (logical word 1) is an even log address, its current value the log address + 1.
* tb_top command-file times are in 1/8 clk (2.18 ns at 57.344 MHz), not 5 ns: a 20 ms frame is
  9,175,040 units. A stimulus built with 5 ns units plays the music 2.3 times too fast.
* `| head` after `grep --line-buffered` in a Monitor never flushes; `grep ... > file` buffers GHDL
  report lines until the run ends.
* The netlist powers some enables up to '1' (`enwrvi_reg`): a new flag derived from them fires once
  out of reset unless gated with the command (`fjump` is gated with `wr_freq`).
* Before 4 Nov the first command after a reset was lost. amyconv's `chip_init` resets the chip and
  then sends `$24` (64 harmonics, INDIVIDUAL) as its first command, so check that command executes
  when testing start-up behaviour.
* Timing report for the failing paths (Timing Analyzer Tcl console, or Report Top Failing Paths):
  `set_operating_conditions 1200mv_85c; update_timing_netlist;
  report_timing -setup -less_than_slack 0 -npaths 50 -detail summary -file failing_setup.rpt`
* MAX 10 compact parts can't initialise block RAM at configuration: everything comes from the flash
  image through the load port, with the chip held in reset.
* Quartus infers a block RAM only from **one** write statement and **one** registered read, each with a
  single address expression: multiplex the addresses and data first. Two reads in `if ... elsif` with
  different addresses gave "uninferred due to asynchronous read logic" and put both RAMs in LEs (224%)
  on 5 Nov. Yosys (`memory -nomap`, then `select -list t:$mem_v2`) shows the same thing: check it
  lists harm and voice.

## 9. Reference material

* `gen/synchro.net`, `gen/adjusted.mac` (the netlist and macros), `gen/quickclr.pat`.
* `docs/amy_docs_ocr.txt`: OCR text of the 1983 spec binder (ver 2), the general description, the
  development notes, the chip-2 notes and the formulas (Atari Museum PDFs; the OCR has errors, check the
  PDFs for numbers). The netlist's `ISSUES.RNO` is in the Atari Museum `AMY_Chip.zip`
  (`amy-Dec85/DEC85AMY.BCK/AMY/SILOS/CURRENT/`).
* The drum test stimulus (`test/cmds/cmds_drums.txt`), from `tools/mkcmd.py` with these helpers
  (formerly `drums/chip.py`):

```python
import mkcmd
GAP = 2 * 118                                    # after a Noise RAM write
def init(s, noise_types=None, lhp=(7, 15, 23, 31)):
    s.system_options()
    for v in range(8): s.voice_type((noise_types or {}).get(v, 0), v)
    for h in range(64): s.amplitude(0, 0, h)
    for f in range(32): s.lhp(f, f in lhp)
def noise_ram(s, gen, prb, ud=0, b=0, sh=0):     # rows 0-14 PRB A,B,C bit 14-row; rows 20-31 UD,B,S
    pa, pb, pc = prb
    for i in range(15):
        s.write(mkcmd.AREG, ((pa >> i) & 1) << 2 | ((pb >> i) & 1) << 1 | ((pc >> i) & 1)); s.advance(mkcmd.CPU)
        s.write(mkcmd.CMD, 0x80 + (14 - i) * 2 + gen); s.advance(GAP)
    for i in range(12):
        s.write(mkcmd.AREG, ((ud >> i) & 1) << 2 | ((b >> i) & 1) << 1 | ((sh >> i) & 1)); s.advance(mkcmd.CPU)
        s.write(mkcmd.CMD, 0x80 + (20 + i) * 2 + gen); s.advance(GAP)
s = mkcmd.Stim(); init(s, {0: 1, 1: 2})
s.frequency(0x1200, 0, 0); s.frequency(0x1500, 0, 1)
s.system_control(seq=1, noise=2)
noise_ram(s, 0, prb=(0x1234, 0x4D2B, 0x7A11), ud=0x003, b=0x010, sh=0xFFF)
noise_ram(s, 1, prb=(0x6E5F, 0x0F0F, 0x3333), ud=0xFFE, b=0x7F0, sh=0x00F)
s.system_control()
for h in list(range(1, 8)) + list(range(9, 16)): s.amplitude(0xD0, 0, h)
s.wait_samples(400)
open('cmds.txt', 'w').write(''.join('%d %d %d\n' % e for e in s.ev))
```

  `cmds_drums40.txt` and `cmds_quickclr40.txt` are the same files with the first command `$20` → `$28`
  (SOR bit 3: 40 harmonics).
