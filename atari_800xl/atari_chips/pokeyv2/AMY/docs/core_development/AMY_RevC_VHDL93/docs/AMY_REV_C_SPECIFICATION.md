# AMY-1 FPGA Revision C — PokeyMAX Hardware and Programmer's Specification

**Draft C.3 — 9 November 2026**  
**Status:** Extension ABI implemented (unlock, `$34` attenuation, `$35` detune, `$36` diffusion, `$39` reset). White noise and diffusion revised in C.3 (RTL patch `revc_c3_rtl.patch`, verified in GHDL, pending hardware). Proportional envelope mode (§7.6) and the engine's use of the extension page (§6.8) implemented and verified in GHDL.  
**Base design:** Atari AMY-1, Rev. B specification (22 February 1984).  
**Host:** Atari 6502 through PokeyMAX; no 8051 support microcontroller.

**Changes since C.2:**
- §7–§8 now describe the implemented extension ABI instead of proposals.
- F1 white noise is now random phase. The first candidate added noise to the log level and left a tone at each harmonic's frequency.
- F4 diffusion is now exponential, from sub-hertz up to white noise. The linear first candidate reached only ±32 Hz.
- New §7.6: proportional envelope mode, selected by bit 7 of B on `WR_FFBP` and `WR_HABP`. Now implemented.
- `$D2C7` now documents locking and clearing.
- New §6.8: note-engine support for the extensions. It adds an extension instrument page (`CONFIG` bit 2), voice type, trim, detune, diffusion and proportional flags per instrument, a pitch envelope, and retrigger. Now implemented.

> **Reading convention.** **[ATARI]** means behaviour from the original Rev. B specification; **[EXISTING]** means current PokeyMAX programmer-visible behaviour; **[REV. C]** means a required Rev. C characteristic; **[CORRECTION]** means a documented compatibility correction; **[IMPLEMENTED]** means an extension present in the Rev. C RTL; **[SPECIFIED]** means a frozen encoding not yet in the RTL; **[PROPOSED]** means a future software-visible extension; **[TBD]** means an unresolved design choice that software must not depend on. Internal VHDL and build details belong in `CORE_INTEGRATION.md`.

## Contents

1. [Purpose and compatibility](#1-purpose-and-compatibility)
2. [Host hardware, clock and audio](#2-host-hardware-clock-and-audio)
3. [6502 memory map](#3-6502-memory-map)
4. [Original AMY command interface](#4-original-amy-command-interface)
5. [Host protocol, readback and reset](#5-host-protocol-readback-and-reset)
6. [6502 note engine](#6-6502-note-engine)
7. [Synthesis extensions](#7-synthesis-extensions)
8. [Extended command interface](#8-extended-command-interface)
9. [Pitch and slope tables](#9-pitch-and-slope-tables)
10. [Compatibility, reset and test requirements](#10-compatibility-reset-and-test-requirements)
11. [Remaining engineering decisions](#11-remaining-engineering-decisions)

## 1. Purpose and compatibility

AMY Rev. C is a time-multiplexed eight-voice additive synthesizer implemented in the PokeyMAX MAX 10 FPGA. It reproduces the programming model of Atari's AMY-1 Rev. B, with the host CPU writing AMY commands directly. The original specification envisioned an optional separate processor such as an Intel 8051 to translate musical events into AMY commands. **The PokeyMAX design has no such 8051.** An optional FPGA **note engine** performs that high-level work with almost no per-harmonic 6502 intervention.

**Compatibility requirements:**

- **[ATARI/EXISTING]** All *legal* original Rev. B AMY commands, A/B/C operand formats, harmonic allocation, amplitude/frequency envelopes, two existing noise modes, system control/options, and current-value reads retain their meanings. Diagnostic chip pins, ALE/address-pin electrical cycles and the original bus timing are **not** emulated as physical pins: the CPU sees memory-mapped registers instead.
- **[EXISTING]** The 6502 can address AMY command and operand registers directly; a FIFO bridges asynchronous CPU writes into the synthesizer clock domain.
- **[CORRECTION]** Zero-slope (immediate) amplitude and frequency breakpoints are corrected to update the current values; the LFSR noise feedback and 40-harmonic mode are corrected against the reconstructed netlist.
- **[IMPLEMENTED]** Extensions are locked after reset and their coefficients are zero. While they are locked, original Rev. B synthesis behaviour is preserved, subject to the Rev. C clock and the documented corrections. Unlocked with all coefficients zero, legacy output is bit-exact.
- **[EXISTING limitation]** Original command values `$00`–`$07` are intercepted by the PokeyMAX wrapper as reset; host writing while the engine is active is subject to the concurrency rules below. “Compatible” does **not** mean cycle-identical pin-level emulation.

For the full historical mathematics and waveform figures, see `historical/ATARI_AMY1_SPEC_REV_B.md`. The older Technical Manual is separately preserved, not merged with Rev. B.

## 2. Host hardware, clock and audio

### 2.1 Clock specification

The AMY synthesizer shall operate with an effective main clock of **8.192 MHz**. This is the Rev. C clock rate and is not software-configurable. It is 2.4% faster than the 8.000 MHz nominal rate used for the original Rev. B frequency tables.

| Property | Rev. C value |
|---|---:|
| Effective main AMY clock | **8.192 MHz** |
| 64-harmonic output sampling rate | **32,000 samples/s** |
| 40-harmonic output sampling rate | **51,200 samples/s** |
| Note-engine time quantum | **8.000 ms** |

At a fixed original 13-bit pitch code, the output frequency is 1.024 times its 8 MHz nominal value (approximately **40.7 cents sharp**). Original frequency commands and pitch encoding are supported unchanged; programmers should use the revised tables in §9 when exact concert pitch is desired. The change also affects envelope timing and slopes as described in §9.

This section intentionally specifies observable behaviour only. Oscillator, PLL, clock-enable and synthesis-parameter details are documented separately for core integrators.

### 2.2 Audio arrangement

**[EXISTING]** An AMY output can be used in SUM mode (one 16-bit sample distributed to both channels) or INDIVIDUAL mode (per-voice samples mixed into channels under programmable masks). The additional host `VOLUME` register scales the output by `VOLUME / 32`, with signed 16-bit saturation. This global scaling is independent of the per-voice attenuation (§7.2).

The `SAMPLE_STROBE` output marks sample updates; FPGA routing/mixer decisions outside AMY are defined in PokeyMAX, not by the original 40-pin AMY bus.

## 3. 6502 memory map

### 3.1 Memory-mapped address

PokeyMAX maps AMY registers to **`$D2C0–$D2CF`**. All addresses in this specification use this base, with no alternate address implied.

### 3.2 Complete implemented 16-byte map

| Offset | Address | CPU read | CPU write | Reset / notes |
|---:|---|---|---|---|
| `$0` | `$D2C0` | Status: bit 7 busy, bit 6 FIFO full | **AMY command** byte | Command `$00–$07` triggers wrapper/core reset |
| `$1` | `$D2C1` | Same status | **AMY register A** (8 bits) | Operand/slope/type |
| `$2` | `$D2C2` | B shadow from last completed read command | **AMY register B** (bits 4:0 to chip; bit 7 too, as the §7.6 flag) | Frequency destination bits 12:8; bit 7 = proportional mode when unlocked (§7.6) |
| `$3` | `$D2C3` | C shadow from last completed read command | **AMY register C** (8 bits) | Destination bits 7:0 |
| `$4` | `$D2C4` | `VOICE_LEFT` | `VOICE_LEFT` mask | One bit per voice; initial `$FF` |
| `$5` | `$D2C5` | `VOICE_RIGHT` | `VOICE_RIGHT` mask | One bit per voice; initial `$FF` |
| `$6` | `$D2C6` | `VOLUME` | `VOLUME` | Gain = byte/32; initial `$FF` |
| `$7` | `$D2C7` | Status | **Extension control**: `$A5`,`$5A` unlock; `$00` lock and clear | [IMPLEMENTED] §8.2; reset locks |
| `$8` | `$D2C8` | Engine status | `W0` builder | Engine optional |
| `$9` | `$D2C9` | Engine status | `W1` builder | Engine optional |
| `$A` | `$D2CA` | Engine status | `W2` builder | Engine optional |
| `$B` | `$D2CB` | Engine status | `EVENT` (`byte3`) | Enqueue logical 32-bit event |
| `$C` | `$D2CC` | Engine status | Engine RAM `ADDR` | Valid write targets 32…255 |
| `$D` | `$D2CD` | Engine status | Engine RAM `WRITE` (`byte3`) | Writes logical word `{byte3,W2,W1,W0}` |
| `$E` | `$D2CE` | Engine status | Ignored | bit 7 engine busy, bit 6 event queue full |
| `$F` | `$D2CF` | Engine configuration | Engine configuration | bit 0 engine enable, bit 1 layout |

**Status conventions:** on `$D2C0/$D2C1/$D2C7`, bit 7=busy and bit 6=full (other bits reserved). Read `$D2C2/$D2C3` only after busy clears following read commands. Engine registers `$8–$E` read engine busy/full, not the write-builder values. `$F` reads current engine configuration. The engine is controlled through its documented configuration register; unused/reserved bits must not be relied upon. 6502 writes to A/B/C/command are buffered; consult §5 for ordering and flow control.

## 4. Original AMY command interface

### 4.1 Programmer-visible contract

The original AMY has four programmer-selected logical registers: **CMND, A, B, C**. PokeyMAX maps them to offsets 0–3. An ordinary write command is issued by writing operands first, then the command byte last. A read command is issued first; the resulting B/C values become visible in shadow registers after busy clears. A/B/C remain compatible with Atari Rev. B in meaning and field widths. `B` has five significant destination bits (readback top bits from the actual wrapper are implementation-dependent; mask to `$1F`).

### 4.2 Complete original Rev. B command set

| Command byte(s) | Name | Prior register writes | Effect | Status |
|---|---|---|---|---|
| `$08+v` (`00001vvv`) | `WR_FFBP` | A=slope; B=dest[12:8]; C=dest[7:0] | Frequency envelope breakpoint for voice `v=0…7` | [ATARI/EXISTING] |
| `$10+v` (`00010vvv`) | `WR_VTYP` | A bits 1:0 = voice type | Set harmonic/noise voice type | [ATARI/EXISTING] |
| `$18+v` (`00011vvv`) | `RD_FFCV` | None | Read current voice frequency into B/C | [ATARI/EXISTING] |
| `$20–$2F` (`0010ssss`) | `WR_SOR` | None | Set four System Options bits | [ATARI/EXISTING] |
| `$30–$3F` (`0011xxss`) | `WR_SCR` | None | Set two System Control bits (legacy aliases) | [ATARI/EXISTING] |
| `$40+h` (`01hhhhhh`) | `WR_HABP` | A=slope; C=amplitude destination | Harmonic breakpoint `h=0…63` | [ATARI/EXISTING] |
| `$80–$BF` (`10xxxxxx`) when SCR.SC1=0 | `WR_LHP` | None | Last harmonic-pair end-of-voice flag (`x[5:1]`, bit 0) | [ATARI/EXISTING] |
| `$80–$BF` (`10xxxxxx`) when SCR.SC1=1 | `WR_NRAM` | A[2:0]=data | Initialise Noise RAM at low six-bit address | [ATARI/EXISTING] |
| `$C0+h` (`11hhhhhh`) | `RD_HACV` | None | Read current harmonic amplitude into C | [ATARI/EXISTING] |

`v` = voice index (3 bits); `h` = global harmonic slot (6 bits). The two meanings of `$80–$BF` are intentional and controlled by `SCR.SC1`.

**Reserved/reset caveat:** `$00–$07` are not ordinary Atari musical commands. This PokeyMAX wrapper treats any such write to offset 0 as a core reset and drops queued writes. The decoder accepts all `$30–$3F` as `WR_SCR` ignoring `xx`, so these are **not free extension opcodes** in a compatible implementation.

### 4.3 Register formats and control commands

**Frequency**: 13-bit unsigned Atari tone (one unit = 1/64 semitone), with `B = (tone >> 8) & $1F` and `C = tone & $FF`; A contains the original sign/exponent/mantissa slope. `A=0` requests an immediate jump, not a ramp. When extensions are unlocked, B bit 7 selects proportional (exponential-approach) stepping (§7.6). The frequency envelope's nominal pitch is defined by Table A/B at the specified clock; see §9 for Rev. C changes.

**Amplitude**: `A` is the Atari 8-bit amplitude slope (sign/exponent/mantissa); `C` is the logarithmic amplitude destination. `A=0` performs an immediate jump. A/C formats and slope encoding are unchanged; consult the historical Rev. B §7.5. B is unused in Rev. B; when extensions are unlocked, B bit 7 selects proportional stepping (§7.6).

**System Options (`$20|bits`)**:

| Bit | 0 | 1 |
|---:|---|---|
| 0 | Address-pin bus mode (historical) | ALE bus mode (historical) |
| 1 | READY | INT pulse |
| 2 | SUM | INDIVIDUAL voice samples |
| 3 | 64 harmonics | 40 harmonics |

**[EXISTING]** Bit 0 has no practical effect on this memory-mapped 6502 interface; the original address pins/ALE aren't exposed. Bit 2 is also observed by PokeyMAX's stereo wrapper.

**System Control (`$30|bits`)**: bit 0=sequencer run (1) / halt (0); bit 1=noise initialise (1) / noise run (0). The remaining command bits must continue to be treated as legacy aliases; an extension must not silently hijack them.

**Voice type (`$10+v`)**: A[1:0] = 0 harmonic, 1 noise type 0, 2 noise type 1, **3 reserved/illegal in Rev. B; [IMPLEMENTED] white noise in Rev. C while extensions are unlocked (§7.1)**. While locked, type 3 keeps its legacy behaviour.

**Last harmonic pairs**: `$80 | (pair_index << 1) | end_flag` with SC1=0; harmonic allocation is global and remains pair-based. Keep original harmonic count/last-pair rules and readback semantics.

## 5. Host protocol, readback and reset

### 5.1 FIFO and ordering

**[EXISTING]** The command FIFO has four entries, each representing one byte write to registers 0–3. If bit 6=1 on a status read, the FIFO is full; the CPU must not submit another byte. The *busy* bit includes pending writes, active command, readback, reset and ROM initialisation. To ensure a complete readback and a predictable direct-write transaction, wait until busy=0 before reading B/C or beginning a mutually exclusive operation.

**[EXISTING]** Writes to A/B/C are ordered ahead of the subsequently issued command. The command is not necessarily processed in the very next 6502 cycle. The host interface manages synchronisation. The hardware manages the underlying ready/interrupt handshake; normal software shall use the documented status bits.

**[EXISTING]** Host writes to offsets 0–3 must not race with engine-generated command sequences. Prefer sending high-level note events when engine active, or explicitly wait for engine STATUS idle before using the original raw AMY port.

### 5.2 6502 programming examples

The following assembly is *illustrative*, in ca65 syntax. Polling `$D2C0` bit 7 waits for complete inactivity; a real-time event player can instead use the less restrictive FIFO-full bit and the engine queue.

```asm
AMY      = $D2C0
AMYCMD   = AMY+0
AMYA     = AMY+1
AMYB     = AMY+2
AMYC     = AMY+3

amy_wait_idle:
    lda AMYCMD
    bmi amy_wait_idle       ; bit 7 busy
    rts

; Example: immediate fundamental frequency for voice 0,
; 13-bit tone stored in FREQ_HI / FREQ_LO.
set_voice0_freq:
    jsr amy_wait_idle
    lda #$00               ; zero slope = immediate
    sta AMYA
    lda FREQ_HI             ; must be in 0..31
    sta AMYB
    lda FREQ_LO
    sta AMYC
    lda #$08               ; WR FFBP voice 0
    sta AMYCMD
    rts

; Example: immediately set harmonic slot 0 to the value in LEVEL.
set_harm0:
    jsr amy_wait_idle
    lda #$00
    sta AMYA
    lda LEVEL
    sta AMYC
    lda #$40               ; WR HABP harmonic 0
    sta AMYCMD
    rts
```

The examples rely on the FIFO accepting four back-to-back writes when empty. More elaborate writers should check bit 6 before each store when writes may be queued already.

### 5.3 Reset and initialization

**[EXISTING]** A write of `$00`–`$07` to `$D2C0` resets the AMY core and clears queued writes. Programs should initialize SOR/SCR, harmonic-pair boundaries, voice types, envelopes and required noise RAM before RUN, following Rev. B §8. The initial global volume is `$FF` (roughly ×7.97), not unity; set `$20` for unity wrapper gain.

## 6. 6502 note engine — programming interface

### 6.1 Purpose and relationship to Atari commands

**[IMPLEMENTED]** The optional note engine allows the 6502 to submit *musical events* rather than issuing many low-level harmonic and frequency commands for every note. The engine reads programmer-uploaded instrument definitions and generates ordinary AMY A/B/C/CMND writes internally. It is **not** the 8051 described in historical system proposals and does not require a support CPU.

A note-on event normally requires four 6502 writes, and a note-off requires one write after the engine has been prepared. These counts exclude checking the event queue and the one-time instrument upload. No particular CPU-cycle saving is guaranteed; savings depend on harmonic count and playback workload. The original command interface remains available, but a host must not mix raw writes with engine-generated writes while the engine is busy.

### 6.2 Engine register definitions

The registers below are **new in Rev. C**. They are **not Atari AMY registers A, B or C**.

| Address | Name | Write meaning | Read meaning |
|---|---|---|---|
| `$D2C8` | `W0` | Latch byte 0 of the next event or instrument-memory word | Engine status |
| `$D2C9` | `W1` | Latch byte 1 | Engine status |
| `$D2CA` | `W2` | Latch byte 2 | Engine status |
| `$D2CB` | `EVENT` | Submit an event: this write supplies byte 3 | Engine status |
| `$D2CC` | `ADDR` | Select the instrument-memory word address for the next `WRITE` | Engine status |
| `$D2CD` | `WRITE` | Store an instrument-memory word: this write supplies byte 3 | Engine status |
| `$D2CE` | `STATUS` | No operation | Bit 7 busy; bit 6 event queue full |
| `$D2CF` | `CONFIG` | Bit 0 enable, bit 1 harmonic layout, bit 2 `XPAGE` (§6.8) | Current configuration in bits 2:0 |

`W0`, `W1` and `W2` are **persistent staging latches**. Writing `EVENT` or `WRITE` uses their most recently written bytes. The logical 32-bit value is formed as follows (the CPU writes the *least-significant* byte first):

```text
  bit 31                   24 23          16 15           8 7            0
  +-------------------------+--------------+--------------+--------------+
  | EVENT or WRITE data     | W2           | W1           | W0           |
  +-------------------------+--------------+--------------+--------------+
    byte 3                   byte 2         byte 1         byte 0
```

`EVENT` **queues** the word as a note-engine event. `WRITE` instead **stores** the word at the selected `ADDR`; it does not queue a note. These two actions use the same W0/W1/W2 staging registers but have different meanings.

**Write-acceptance rule:** Don't change the staging bytes immediately after submitting an `EVENT` or `WRITE` until the corresponding write has been accepted. In particular, the event queue's *full* bit does not by itself indicate that the staging latches may safely be overwritten. For the simplest reliable programmer sequence, upload instruments while the engine is idle, and submit events using the acceptance/ready procedure appropriate to the host; precise back-to-back submission timing requires additional host-interface validation.

### 6.3 Engine configuration and status

| `CONFIG` bit | Name | `0` | `1` |
|---|---|---|---|
| 0 | Enable | Engine does not process events | Engine processes queued events |
| 1 | Harmonic layout | 4 voices × 16 harmonic slots | 8 voices × 8 harmonic slots |
| 2 | `XPAGE` [IMPLEMENTED, §6.8] | `ADDR`/`WRITE` reach the base instrument page | They reach the extension page |
| 7:3 | Reserved | Write zero | — |

In the 4×16 layout, only voices 0–3 can be addressed by the engine. In the 8×8 layout, voices 0–7 are available. Each instrument definition has up to 16 harmonic entries; the selected layout determines how many the engine uses per voice.

`STATUS` read bits:

| Bit | Meaning |
|---|---|
| 7 | Engine busy: it has queued events and/or is processing an event |
| 6 | Event queue full (capacity 16): a further `EVENT` write is dropped |
| 5:0 | Reserved; ignore |

Reads at `$D2C8–$D2CE` return this status; reads at `$D2CF` return configuration. Engine **busy** and event queue **full** are different conditions. Allow engine processing to finish before changing instrument definitions or using raw AMY A/B/C/CMND commands.

### 6.4 Events: exact W0/W1/W2 meanings

The high nibble of byte 3 determines the event type; the low three bits identify voice `v`.

| Write to `EVENT` | `W0` | `W1` | `W2` | Effect |
|---|---|---|---|---|
| `$90 + v` | Unsigned note index, **0–127** | Target level in AMY quarter-dB units (`$D8` is the conventional normal level) | Number of harmonic slots/band limit, **1–16**, capped by current layout | Start/update the note on voice `v` using its selected instrument |
| `$80 + v` | Ignored | Ignored | Ignored | Release the active note on voice `v` |
| `$A0 + v` | Instrument number **0–11** | Ignored | Ignored | Select an instrument for voice `v`; the voice is made silent |

Other byte-3 event classes are not defined in this revision. `W0` for note-on is relative to the global note-0 pitch word described in §6.6, not necessarily a MIDI pitch number. The engine adds 64 pitch units per note index, so a program may choose an arbitrary note-0 reference.

The event sequence can be written in normal 6502 assembly:

```asm
AMY       = $D2C0
ENG_W0    = AMY+$08
ENG_W1    = AMY+$09
ENG_W2    = AMY+$0A
ENG_EVENT = AMY+$0B
ENG_ADDR  = AMY+$0C
ENG_WRITE = AMY+$0D
ENG_STAT  = AMY+$0E
ENG_CFG   = AMY+$0F

; Example: select instrument 0 for silent voice 0.
    lda #0
    sta ENG_W0
    lda #$A0
    sta ENG_EVENT

; Example: note on, voice 0, with eight harmonics.
; Wait for event submission to be accepted before changing W0–W2.
    lda #60
    sta ENG_W0
    lda #$D8
    sta ENG_W1
    lda #8
    sta ENG_W2
    lda #$90
    sta ENG_EVENT

; Later: release voice 0 (W0/W1/W2 are ignored).
    lda #$80
    sta ENG_EVENT
```

These examples show **event format**, not a complete queue-management routine; see §6.3 and the write-acceptance requirement in §6.2.

### 6.5 Uploading instrument definitions

The engine provides a programmer-visible word-addressed instrument store. The CPU writes one logical **32-bit word** by setting `ADDR`, then `W0`, `W1`, `W2`, and finally `WRITE` (the high byte). The physical memory width and FPGA storage arrangement are not part of this programming interface.

```asm
; Write the logical word $00000000 to engine word address 40.
; Perform uploads while the engine is idle; await completion/acceptance.
    lda #40
    sta ENG_ADDR
    lda #0
    sta ENG_W0
    sta ENG_W1
    sta ENG_W2
    sta ENG_WRITE
```

Logical memory map:

| Word address | Programmer-visible purpose |
|---|---|
| `40` | Global **13-bit** pitch word for note index 0, stored in bits 12:0 |
| `48–59` | Instrument headers, instruments 0–11 |
| `64–255` | Instrument harmonic entries: `64 + 16 × instrument + harmonic (0–15)` |

The extension page selected by `CONFIG` bit 2 is described in §6.8. The other addresses contain engine/system state or are reserved and shall **not** be used by applications for instrument definitions. `WRITE` accepts addresses 32–255; this is not permission to overwrite the engine's state words at 32–39. Instrument-data writes are not queued as note events; do not upload/modify a definition while it may be in use by pending or active engine work.

**Instrument header**, at word `48 + instrument`:

| Bits | Field | Meaning |
|---|---|---|
| 7:0 | Release slope | AMY envelope slope encoding |
| 15:8 | Upward glide slope | Frequency glide slope on rising note changes |
| 20:16 | Release drop | Drop in quarter-dB units per 8 ms time quantum, 0–31 |
| 23 | Decay mode | `1` = plucked/decaying instrument (send decay breakpoints after attack) |
| 31:24 | Downward glide slope | Frequency glide slope on falling note changes |
| 22:21 | Reserved | Write 0 |

**Harmonic entry**, at word `64 + 16 × instrument + harmonic`:

| Bits | Field | Meaning |
|---|---|---|
| 7:0 | Level offset | Quarter-dB below the note's level; `$FF` disables this harmonic |
| 15:8 | Attack slope | AMY amplitude slope; `0` requests an immediate jump |
| 23:16 | Decay slope | AMY amplitude slope used by decaying instruments |
| 31:24 | Sustain offset | Quarter-dB below peak; `$FF` means decay to silence |

For example, an entry with level offset 0, attack slope 0, decay slope 0 and sustain offset 0 has logical value `$00000000`. That is a format example, not a musically useful complete instrument by itself.

### 6.6 Typical programming sequence

1. **Reset/initialise AMY:** Apply the standard AMY reset and configure the required voice types, harmonic allocation, output routing and other Rev. B controls.
2. **Choose an engine layout:** Write `$01` to `CONFIG` for four voices with 16 harmonics each, or `$03` for eight voices with eight harmonics each. These values also enable engine processing.
3. **Upload the pitch reference:** Write the 13-bit note-0 word to instrument-memory address `40`. The 8.192 MHz pitch tables in §9 provide suitable values; do not interpret engine note numbers as MIDI numbers without choosing the matching reference.
4. **Upload instrument definitions:** For each used instrument, write its header to `48 + i` and its 16 harmonic entries to `64 + 16i + h`, including `$FF` level offsets for unused slots. Upload while the engine is idle.
5. **Select the instrument:** For a silent voice `v`, set `W0=i` and write `$A0+v` to `EVENT`; allow the event to complete.
6. **Play a note:** Write note number to `W0`, target level to `W1`, harmonic count to `W2`, then `$90+v` to `EVENT`. Respect status and staging-latch acceptance.
7. **Release a note:** Write `$80+v` to `EVENT`. This event uses no new W0/W1/W2 data.
8. **Rev. C extensions (optional, §6.8):** unlock extended mode, then upload the extension headers and harmonic coefficients with `XPAGE`=1 before selecting instruments.
9. **Wait for engine idle** before modifying live instrument definitions or sending host raw commands that would contend with engine-generated A/B/C/CMND writes.

The engine computes the per-harmonic attack, decay and release commands from the uploaded instrument data. A plucked instrument can generate two harmonic passes (attack then decay). The host does not need to schedule these individual breakpoints.

### 6.7 Timing

**[REV. C]** Instrument release-drop values and retrigger periods (§6.8) are interpreted per **8 ms** engine time quantum. This is a programmer-visible unit. Exact internal clock division and scheduling circuitry belong in `CORE_INTEGRATION.md`.

### 6.8 Rev. C extensions in the engine [IMPLEMENTED, C.3]

The engine applies the §7 extensions from per-instrument data, so a player running at 50 Hz still sends one event per note, even for drums with exponential pitch drops, white-noise layers and inharmonic partials. Extension data is used **only while extended mode is unlocked** (§8.2). While locked, the engine behaves exactly as in §6.1–§6.7 and never sends `$34–$3F` (they would be SCR aliases). It also never sets B bit 7.

**Extension page.** Extension data lives in a second instrument-store page of 128 words. Setting `CONFIG` bit 2 (`XPAGE`) directs `ADDR`/`WRITE` to it, with `ADDR` 0–127; writes to 128–255 are ignored. With `XPAGE`=0 they reach the base page as before. Uploads to either page follow §6.5 and must be done while the engine is idle. The page is not cleared by reset: software that unlocks extensions must upload extension words for every instrument it uses, with zeros meaning "no extensions".

| Extension-page address | Contents |
|---|---|
| `0–11` | Extension header, instrument 0–11 |
| `12–15` | Reserved |
| `16–23` | Engine state: voice 0–7's pending retriggers. Don't write these while the engine is busy |
| `24–31` | Reserved |
| `32–127` | Harmonic coefficients: word `32 + 8 × instrument + (harmonic >> 1)`, two harmonics per word |

**Extension header**, at extension word `instrument`:

| Bits | Field | Meaning |
|---|---|---|
| 1:0 | Voice type | Sent with `$10+v` on instrument select: 0 harmonic, 1/2 original noise, 3 white noise (§7.1) |
| 3:2 | Retrigger period | (value + 1) × 8 ms between attacks |
| 7:4 | Retrigger count | 0–15 extra attacks after the first (claps, flams, rolls) |
| 15:8 | Trim | Voice attenuation in ¼ dB, sent with `EXT_VATT` on instrument select |
| 23:16 | Pitch start offset | Signed, in ¼ semitones (±32 semitones); 0 = no pitch envelope |
| 31:24 | Pitch rate | A byte of a proportional frequency breakpoint (§7.6); used when the offset is not 0 |

**Harmonic coefficient half-word** (bits 15:0 for the even harmonic, 31:16 for the odd one):

| Bits | Field | Meaning |
|---|---|---|
| 5:0 | Detune | Signed, `EXT_HDET` (§7.3) |
| 7:6 | Reserved | Write 0 |
| 13:8 | Diffusion | `EXT_HSTOCH` (§7.4) |
| 14 | Proportional attack | The attack breakpoint is sent with B bit 7 set; the attack slope byte is read as E,k (§7.6) |
| 15 | Proportional decay | The decay breakpoint is sent with B bit 7 set; the decay slope byte is read as E,k |

**What the engine does with it (unlocked):**

- **Instrument select (`$A0+v`).** The engine sends the voice type and `EXT_VATT` with the trim. Then, for each harmonic slot of the voice in the current layout, it sends a jump to 0 (so the voice is silent), `EXT_HDET` and `EXT_HSTOCH`, and it remembers the slot's two proportional flags. Coefficients therefore change only while the voice is silent, so they never glitch a sounding note. This costs 2 + 3 × 16 commands per select in the 4×16 layout, and 2 + 3 × 8 in 8×8.
- **Note-on (`$90+v`).**
  - If the pitch start offset is not 0, the engine jumps the voice frequency to `note + 16 × offset` (in 1/64 semitone units), then sends a proportional frequency breakpoint to the note pitch with A = pitch rate. The header glide slopes are not used for that note.
  - The attack and decay passes are as in §6.5. Every harmonic breakpoint is sent with B (A, B, C, command), with bit 7 set when the slot's flag applies, so a B value left by the host never leaks into it. The attack flag applies when the attack rises; when the engine jumps instead (the voice was not quiet enough, §6.5), it is a jump. As before, a decay breakpoint follows only a jump, so a proportional (rising) attack gets no decay pass.
  - Velocity stays the `W1` target level, which the engine already applies to every harmonic.
- **Retrigger.** With count n > 0, the engine repeats the attack and decay passes n more times, at the given period, at the same levels and band limit. The pitch envelope runs only once. Since the voice was not released, the repeated attacks jump, as for any legato attack at the same level. A later event on the same voice cancels any retriggers still pending.
  - Timing has a resolution of 1/8 of the time quantum (1 ms). The first repeat comes 7/8 to 1 period after the note; later ones are exactly one period apart. Event processing goes first, so a busy queue can delay a repeat, but not the ones after it.
  - `STATUS` bit 7 (busy) stays set while repeats are pending and the engine is enabled, because their breakpoints will still reach the chip.
  - Lock extended mode only while the engine is idle. Repeats still pending when it is locked are dropped.
- **Note-off (`$80+v`).** As before. Retriggers still pending are cancelled.

**CONFIG** (amends §6.3): bit 2 is `XPAGE` (instrument-store page for `ADDR`/`WRITE`), and bits 7:3 are reserved. `XPAGE` has no effect on event processing.

**Example kit (8×8 layout), one event per voice per hit:**

| Instrument | Voice type | Pitch envelope | Retrigger | Harmonic coefficients |
|---|---|---|---|---|
| Kick | 0 | offset +96 (24 semitones), rate `$67` (E=3, k=7: τ ≈ 8 ms) | — | detune and diffusion 48 on click harmonics 4–8 |
| Snare head | 0 | +12, rate `$66` | — | membrane-mode detune, diffusion 8–26 |
| Snare wires | 3 | — | — | none; three harmonics used as crack, body and tail |
| Clap | 1 (original noise) | — | count 3, period 0 (8 ms) | none |
| Toms | 0 | +20, rate `$69` (τ ≈ 32 ms) | — | membrane-mode detune |
| Hats | 0 + a white voice | — | — | detune cluster, diffusion 40–48 |

A two-voice instrument (snare head plus wires) takes two note-on events, one per voice. Drums use decaying instruments (header bit 23) with sustain offset `$FF`, so they need no note-off.

```asm
; Kick extension header: type 0, no retrigger, trim 0,
; pitch offset +96 (+24 semitones), rate $67.  Logical value $67600000.
    lda ENG_CFG
    ora #$04            ; XPAGE = 1
    sta ENG_CFG
    lda #0              ; extension word 0 = instrument 0
    sta ENG_ADDR
    sta ENG_W0          ; type, retrigger
    sta ENG_W1          ; trim
    lda #$60
    sta ENG_W2          ; pitch offset
    lda #$67
    sta ENG_WRITE       ; pitch rate, stores the word
    lda ENG_CFG
    and #$FB            ; back to the base page
    sta ENG_CFG
```

**Implementation notes (non-normative):**
- **[IMPLEMENTED]** The extension page is the upper half (words 128–255) of the harmonic block RAM (M9K 3), which the 128 × 36 layout left unused. No new M9K is needed.
- It has its own engine port, granted in any clock in which the core neither reads that RAM nor uses its read data in the next clock. At 14 clocks per chip clock (3/7 of 57.344 MHz) that is eight clocks per chip clock.
- The only clocking requirement is the existing Rev. C minimum of 9 clocks per chip clock, which `amy1_top` asserts.
- **[IMPLEMENTED]** The engine's use of the page: it reads the header on instrument select and note-on, and the coefficient words on instrument select. The two proportional flags per harmonic slot are 128 flip-flops in the engine.
- Retrigger state (level, band limit, count, period, due time) lives in extension words 16–23, plus one pending flag per voice in flip-flops. The engine checks pending voices once per 1/8 time quantum, when its event queue is empty.

## 7. Synthesis extensions

All extensions act only while extended mode is unlocked (§8.2). Their coefficients reset to zero, and at zero they leave the legacy datapath bit-exact. They are general-purpose: drums are one application.

**Shared mechanism.** Each harmonic slot `h` has a persistent 18-bit phase offset `P[h]` (2¹⁸ = one cycle, modulo arithmetic). It is updated once per sample, and its upper 14 bits are added to both sine arguments of the harmonic. Detune, diffusion and white noise all act through `P[h]`, so they never cause phase discontinuities. A shared 16-bit maximal LFSR (taps 16, 14, 13, 11; seed `$ACE1`), advanced once per harmonic slot, supplies a signed byte `r` to each harmonic in turn.

### 7.1 F1 — White-noise voice [IMPLEMENTED, revised in C.3]

- Voice type `A[1:0]=3` on `$10+v`, while unlocked.
- Each harmonic of the voice, **including the first**, has its phase re-randomised every sample: `P[h] += r·2¹⁰`, a uniform full-circle step. The harmonic outputs `y_h[n] = A_h[n]·cos(2π·u[n])` with `u` uniform: flat white noise to Nyquist, with the same power as a sine at the same level and no residual tone.
- Each harmonic is an **independent noise layer with its own envelope**: one white voice gives up to its allocated number of separately enveloped noise sources (crack, body, tail, ...). Frequency, detune and diffusion have no audible effect on a white voice.
- Amplitude envelopes, F2 attenuation, harmonic allocation and channel routing apply as usual. The original noise-word path is bypassed: a type-3 voice is a harmonic voice for amplitude purposes.
- *History:* the C.2 candidate fed the LFSR into the original log-amplitude noise word. That chopped each harmonic and left a strong tone at its frequency (measured on hardware, 20–23 dB above the noise floor), so it was replaced.

### 7.2 F2 — Per-voice attenuation [IMPLEMENTED]

- Eight unsigned 8-bit controls `att[v]`, one unit = ¼ dB. `0` = unity; `255` = 63.75 dB.
- Implemented as a subtraction of `32·att[v]` from the harmonic's 13-bit log amplitude before the exponential ROM, with underflow forced to silence. It applies to every harmonic of the voice; the frequency subcycle bypasses it.
- Typical uses: velocity (one command per note instead of one per harmonic), mix trims, tremolo.

### 7.3 F3 — Fractional harmonics [IMPLEMENTED]

- Signed six-bit `d[h]` in `−32…+31` (two's complement in C[5:0]).
- `f_h = f_v·(k_h + d[h]/64)`, where `k_h` is the slot's 1-based position within its voice, as allocated by the last-harmonic-pair flags.
- Implemented as `P[h] += (d[h]·freq_increment) >> 8`, which uses the voice frequency increment rather than its wrapped phase. The partial's phase stays continuous when `d` or the voice frequency changes.
- The offset is a fraction of the fundamental, not constant cents. With a voice at half the wanted pitch, harmonics 2..8 plus detune can place most circular-membrane modes (1, 1.594, 2.136, 2.296, 2.918, 3.501, 4.06).

### 7.4 F4 — Per-harmonic diffusion [IMPLEMENTED, revised in C.3]

- Unsigned six-bit `s[h] = eee mmm`, default 0.
- `P[h] += r·step(s)`, where `step(s) = (8 + mmm) << eee`, and `s = 0` gives step 0 exactly.
- The result is a random walk of the partial's phase. The line broadens to an approximately Lorentzian shape around its nominal frequency. Its half width does **not** depend on the partial's frequency and grows about ×4 for every +8 in `s`:

| `s` | 1 | 8 | 16 | 24 | 32 | 40 | 48 | ≥ 56 |
|---|---|---|---|---|---|---|---|---|
| half width (32 kHz) | 0.6 Hz | 2 Hz | 8 Hz | 33 Hz | 130 Hz | 520 Hz | 2.1 kHz | ~ white |

- Typical values: 2–20 for ensemble roughness or breath; 20–32 for a rattling drum head; 40–48 for cymbal shimmer. From about 56 a partial becomes noise-like (but F1 is the white-noise function).
- *History:* the C.2 candidate used `r·s` (linear), which reached only about ±32 Hz at `s=63`.

### 7.5 Combining extensions

A voice may use amplitude envelopes and the independent controls together:
- an inharmonic but stable bell (`d≠0`, `s=0`)
- a shimmering cymbal cluster (`d≠0`, `s≈44`)
- a white-noise voice whose harmonics are separately enveloped snare-wire layers
- velocity-controlled balance (`att>0`)
- an exponential pitch drop (§7.6)

At zero values all of these preserve old harmonic sounds.

### 7.6 Proportional envelope mode [IMPLEMENTED, C.3]

Selected per breakpoint by **B bit 7** on `WR_FFBP` (`$08+v`) and `WR_HABP` (`$40+h`), while unlocked. While locked, B[7:5] are ignored as before.

| Field | Meaning in proportional mode |
|---|---|
| A[6:5] (E) | Update interval, as for linear slopes: every 128 / 32 / 8 / 2 sample periods |
| A[3:0] (k) | Shift: each update moves the current value by `(dest − current) >> k` (arithmetic), at least one unit in the right direction, until it reaches the destination (as for a linear slope: the same 13 bits for frequency, the top 8 for amplitude, i.e. within 1/4 dB from above) |
| A[7], A[4] | Reserved, write 0 |
| B[4:0], C | Frequency destination as before (FFBP); B[4:0] reserved 0 for HABP, C = amplitude destination |
| `A = 0` | Still an immediate jump, whatever B bit 7 says |

- The current value approaches the destination exponentially, with a time constant `τ ≈ interval·2^k / f_s` for k ≥ 2. At E=3 (every 2 samples) and 32 kHz:

| k | 2 | 4 | 7 | 9 | 12 | 15 |
|---|---|---|---|---|---|---|
| τ | 0.25 ms | 1 ms | 8 ms | 32 ms | 0.26 s | 2 s |

- Direction comes from the sign of `dest − current`, so a proportional breakpoint can never run the wrong way and wrap (Rev. B quirk Q2).
- **Frequency** (current value in 1/2048 semitone): a jump to the start pitch followed by one proportional breakpoint gives an analogue-style drum pitch envelope. A kick dropping 24 semitones with τ ≈ 8 ms is two commands, against one write per millisecond with linear slopes, whose maximum is about 0.24 semitone/ms. It also gives exponential portamento.
- **Amplitude** (current value in 1/128 dB, logarithmic): an approach that eases into its destination. Examples are an RC-like attack, settling onto a sustain level, or a decay that slows as it nears silence. Plain exponential decays remain linear slopes in the log domain.
- The mode is stored per breakpoint: one flag per voice for frequency and one per harmonic for amplitude. A later breakpoint with B bit 7 clear returns to linear stepping. Reset, lock (`$00` to `$D2C7`) and coefficient reset (`$39`) clear the flags; a running proportional envelope then continues linearly with its A byte read as a slope.
- **B is a register.** Bit 7 is sampled when `WR_FFBP` or `WR_HABP` executes, from whatever B last held. Rev. B software never writes B before `WR_HABP`, so after a proportional `WR_FFBP` the next `WR_HABP` would also be proportional: software that uses the mode writes B before every breakpoint command, or writes B with bit 7 clear when it is done. B bit 7 does not read back, and read commands do not change it.
- Arithmetic: a frequency is stepped on all 18 bits of its current value (destination at 1/64 semitone, fraction 0), an amplitude on its 13 bits (destination `C × 32`). The step never overshoots, so the linear arrival test stops it.
- The update rate is the linear slopes' rate counter, unchanged.

## 8. Extended command interface

### 8.1 Why “unused command” requires care

The original eight-bit command space is **not** a simple sparse opcode list:

| Range | Use |
|---|---|
| `$00–$07` | reset commands in the current wrapper |
| `$08–$1F` | voice commands |
| `$20–$2F` | options |
| `$30–$3F` | controls |
| `$40–$7F` | harmonic writes |
| `$80–$BF` | dual-use LHP/NRAM |
| `$C0–$FF` | harmonic reads |

In particular, **`$34–$3F` are valid aliases of `WR_SCR` while locked**, so they are only reinterpreted after an explicit unlock.

### 8.2 Implemented ABI [IMPLEMENTED]

**Unlock:** when status reports busy=0 (FIFO and engine idle), write `$A5` and then `$5A` to `$D2C7`. Any other byte cancels a partial unlock. **Lock:** write `$00` to `$D2C7`, which also clears every extension coefficient. An AMY reset (command `$00–$07`) also locks and clears. Reading `$D2C7` still returns status.

| Command (unlocked only) | Name | A (`$D2C1`) | B | C (`$D2C3`) | Effect |
|---|---|---|---|---|---|
| `$34` | `EXT_VATT` | voice 0–7 | 0 | attenuation 0–255 (¼ dB) | §7.2 |
| `$35` | `EXT_HDET` | harmonic slot 0–63 | 0 | signed detune in C[5:0] | §7.3 |
| `$36` | `EXT_HSTOCH` | harmonic slot 0–63 | 0 | diffusion in C[5:0] | §7.4 |
| `$37` | reserved | — | — | — | Do not use; planned `EXT_READ` |
| `$38` | reserved | — | — | — | Do not use; planned `EXT_CAPS` |
| `$39` | `EXT_RESET` | 0 | 0 | 0 | Clear detune, diffusion, attenuation, proportional flags |
| `$3A–$3F` | reserved | — | — | — | Future |

- Write A, B and C, then the command, exactly as for original commands. Extension commands go through the same FIFO and keep their order relative to original commands.
- While locked, `$34–$3F` act as legacy SCR aliases (and `$36` halts the sequencer). Software must therefore never send them without first unlocking.
- The voice type and proportional mode reuse original commands (`$10+v` with A=3; B bit 7 on `$08+v` and `$40+h`).

```asm
; unlock, then detune harmonic slot 3 by -4/64
wait:  bit AMY          ; $D2C0 status, bit 7 = busy
       bmi wait
       lda #$A5
       sta AMY+7
       lda #$5A
       sta AMY+7
       lda #3
       sta AMY+1        ; A = slot
       lda #0
       sta AMY+2        ; B = 0
       lda #$3C         ; -4 in six-bit two's complement
       sta AMY+3        ; C
       lda #$35         ; EXT_HDET
       sta AMY          ; command
```

### 8.3 Open items

- `EXT_READ` / `EXT_CAPS`: readback of coefficients and a capability/version word for feature detection.
- **Note-engine support:** §6.8 (extension page, instrument select and note-on behaviour, retrigger). Implemented.
- Parameter writes take effect at the harmonic's next sample, regardless of 40/64-harmonic scheduling.

## 9. Pitch and slope tables

### 9.1 Preserve Atari’s 13-bit pitch format

Atari specifies 1/64 semitone units and Table A/B at **8.000 MHz external / 4.000 MHz internal**. Rev. C keeps those *numeric encodings*, but operates at **8.192 MHz external / 4.096 MHz internal**, raising all frequencies by a factor of 1.024 at unchanged tone words.

For a desired frequency `f` formerly obtained with Atari tone `T_8MHz`:

`T_8.192 = round(T_8MHz - 64*12*log2(8.192/8.000)) = round(T_8MHz - 26.28)`.

A practical integer conversion is `max(0,min(8191,T_8MHz-26))`, with a residual frequency error of approximately +0.44 cents (nearest integer tone step). **Tone-code limits apply**: subtracting 26 near the bottom of the range saturates and cannot preserve the lowest frequencies.

**Example:** Atari's `A440` Table A tone `$138C` = 5004; Rev. C's nearest tone is `4978` = `$1372` (`B=$13`, `C=$72`). This provides approximately the original 440 Hz instead of ~450.6 Hz from unchanged `$138C` at the faster clock. Exact old-table printed frequency figures are *not* recomputed in the historical documents.

### 9.2 New Rev. C tables alongside the originals

- `tables/revc_table_a_8192.csv`: all original Table A semitone entries and new 8.192 MHz codes, with new B/C bytes; original printed frequencies retained for comparison.
- `tables/revc_table_b_8192.csv`: all original Table B fine-step entries with new tone codes and bytes.
- `tables/revc_table_c_slopes_8192.csv`: original slope codes and original slope table, with **time-base scaled estimates** at 1.024× (subject to verification against the device’s actual time base).

**The historical Rev. B Markdown and its CSV tables are unchanged.** These are new derived Rev. C programming aids, not an alteration of Atari's printed numbers. Programs may alternatively compute the offset themselves; the note engine’s reference note values must use Rev. C pitch codes; instrument and score data should be converted accordingly.

### 9.3 Why not add a new pitch opcode?

No new pitch command is required: preserve `WR_FFBP` `$08+v` and the 13-bit B/C representation. A separate table makes compatibility and old music conversion predictable. If future instruments need microtonal pitch finer than 1/64 semitone, that should be a **separate** explicit extension proposal, not mixed into this clock correction.

## 10. Compatibility, reset and test requirements

| Area | Conformance criterion |
|---|---|
| Legacy commands | All nine Rev. B command families decode and respond as before; test original AMY command streams. |
| Clock | Verify 8.192 MHz effective clock and 32 kHz / 51.2 kHz output sample modes. |
| Pitch | Compare Table A/B-derived pitches under 8.192 MHz; 440 Hz example and edge cases; use Rev. C pitch tables in software and instrument data. |
| Host map | Confirm all addresses `$D2C0–$D2CF` and their read/write semantics. |
| FIFO/readback | Back-to-back A/B/C/command, FIFO full condition, immediate reads, reset, timeout. |
| Engine | Four stores/note-on, one store/note-off, queue handling; instrument timing at 8 ms; 4x16/8x8 modes. |
| Zero extensions | Equal-command replay with extension parameters reset must preserve documented legacy synthesis behaviour. |
| F1 | Flat spectrum with no residual tone at harmonic frequencies; first harmonic included; repeatable from reset; old noise types unchanged. |
| F2 | Unity at 0, monotonic quarter-dB steps, saturation, stereo and voice isolation. |
| F3 | Signed coefficient extrema; continuous phase; 40/64 modes and zero-detune bit-exact. |
| F4 | Bit-exact at zero; half width against `s` per the §7.4 table, independent of partial frequency. |
| §7.6 | Proportional: time constant against k and E; arrives exactly; never wraps; A=0 still jumps; flags cleared by `$39`/lock. |
| §6.8 | Engine: select sends the voice type, trim and coefficients; pitch envelope reaches the chip; retrigger period and cancellation; locked engine output unchanged. |
| Resources | Implementation resource and timing requirements are recorded in the core-integration specification. |

## 11. Remaining engineering decisions

1. **Hardware validation of C.3**: F1/F4 and the slot alignment, proportional mode (§7.6) and the engine extensions (§6.8). All are verified in GHDL.
2. **`EXT_READ` / `EXT_CAPS`** encodings.
3. **Measure CPU-cycle savings** with representative instruments, rather than printing an unsupported percentage.

---

### Reference documents

- **Historical AMY specification:** `historical/ATARI_AMY1_SPEC_REV_B.md`; the original Technical Manual is also preserved unchanged.
- **Core integration and implementation history:** `CORE_INTEGRATION.md` and the separate `implementation/` folder; these are not part of the programmer-visible device specification.
- **Revision C pitch tables:** `tables/`, derived from Atari's historical tables.

This is a specification draft. Items marked **[IMPLEMENTED]** are in the Rev. C RTL. **[SPECIFIED]** encodings are frozen but not yet in the RTL. **[PROPOSED]** and **[TBD]** items must not be relied on.
