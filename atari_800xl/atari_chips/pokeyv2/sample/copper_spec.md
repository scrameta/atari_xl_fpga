# PokeyMAX copper — draft spec v0.4

A small list processor in PokeyMAX's sample engine. It plays register-write programs from
sample memory on a timer, so music, sound effects and simple I/O sequences cost the 6502
nothing per frame. In the spirit of the Amiga copper: it moves values into registers and
waits; it does no arithmetic.

Changes from v0.3:

- **Per-thread base** in place of the 2-bit bank: a `MOVE r` writes register `base + r`,
  so one instrument program plays on any channel (section 3). `BASE n` sets it, `CSTART`
  takes it from the new `CBASE` register, and `FORK` passes the caller's base on.
- Feature flags in a 32-byte configuration window: `CAPABILITY2` at `$D220`, `RESTRICT2`
  at `$D221` (section 6).
- New section 1a: the two ways to use it (a whole song, or notes started from the VBI).

Items marked **[open]** still need a decision.

## 1. Overview

- Programs live in the **64 KiB sample RAM**, shared with sample playback, and are
  uploaded with RAMADDR/RAMDATAINC as now.
- **8 threads**, each with its own program counter, wait counter, register base and an
  8-entry return stack. Typically one thread per sound channel: each channel repeats its
  own patterns, so separate threads compress much better than one thread for the whole chip.
- **Thread state is kept in sample RAM**, in a 256-byte context page at `$FF00-$FFFF`
  (section 7), because the build has no free M9K. While the copper runs, that page belongs to
  it.
- Threads run on a common **tick**, by default one per video frame, counted from the
  Atari's own clock (section 5).
- On each tick, every running thread whose wait has run out executes instructions until its
  next `WAIT`. The writes for one tick all land within about a hundred microseconds.
- Writes go through the same internal register path as CPU writes, so the copper can drive
  every chip: the four POKEYs, both SIDs, both PSGs, COVOX and the sample player itself, and
  AMY including its note engine.
- **[open]** Builds: the copper needs the 64 KiB sample RAM and roughly 400-575 LEs, so it
  would be in 10M16 builds only. 42 KiB builds don't have it.

## 1a. Two ways to use it

**A whole song.** The tune is converted offline into a copper program, one thread per
channel. The CPU starts thread 0 once; thread 0 sets each channel's base and `FORK`s the
channel threads, and from then on the VBI does nothing at all.

**Notes from a player or a game.** The CPU decides when notes start and stop; the copper
runs each note's envelope (the frame-by-frame volume and distortion steps). With 8 threads,
up to 8 notes or effects run at once, one thread per channel being driven.

- Note on: the CPU writes the pitch itself (e.g. AUDF), then starts the channel's thread on
  the instrument's envelope program: `CBASE` (the channel), `CADDRL`, `CADDRH`, `CSTART`.
  The bytes that don't change since the last start needn't be written again.
- Note off: start the same thread at the instrument's release program. Starting a running
  thread restarts it at the new address.
- The program ends with `STOP`, or the CPU stops it with `CKILL`.

Because `MOVE` is relative to the base, one program serves every channel: an envelope
written with offset 1 (AUDC) plays on POKEY 1 channel 1 with base `$00`, channel 2 with
`$02`, POKEY 2 channel 1 with `$10`; SID voices step by 7 from `$40`, PSG registers sit at
`$A0`. There is no arithmetic, so the copper can't transpose: in this mode the CPU sets the
pitch, and pitch effects inside a program (vibrato, arpeggio) use fixed values, which suits
sound effects.

## 2. Register space

The copper addresses the `$D2xx` page by its low byte, the same addresses the 6502 uses,
with the full v1.40 map (`$D200` POKEY 1 ... `$D2C0` AMY). A `MOVE r` (r = 0-63) writes
register `base + r`, wrapping within the page, where `base` is the thread's 8-bit register
base. The protection below applies to the resulting address.

The copper's decode doesn't depend on the CPU's view:

- **Configuration is out of reach.** `$D210-$D22F` is always POKEY 2 and POKEY 3 for the
  copper, even while the CPU has the configuration mapped there, and copper writes to CONFIG
  (`$D20C` and `$D21C`) are ignored, so a program can't switch configuration in.
- **Its own registers are out of reach.** Writes to `$D295-$D29C` are ignored. Programs
  use `FORK`, `KILL`, `STOP` and `SIGNAL` instead.
- **Absent or restricted chips.** A write to an area whose chip is missing from the build
  or turned off in RESTRICT is dropped. The CPU sees POKEY 1's shadows there, but passing
  copper writes on to POKEY 1 would let a SID tune scribble over POKEY 1 on a machine
  without SID.
- `$D2D0-$D2FF` (reserved) is dropped.

Everything else is writable, including all of POKEY 1: its audio, and its I/O (SEROUT,
SKCTL, IRQEN, STIMER, SKRES, POTGO), so the copper can also run serial output (section 9).

**Ownership.** A multi-register sequence, for example an AMY engine event (ENGW0-2,
ENGEVENT) or a sample channel set-up (CHANSEL, then SAMADDR...), must not be interleaved
with CPU writes to the same registers. Each chip, or each function of POKEY 1, is driven
either by the CPU or by the copper at any one time. This is a software rule; the hardware
doesn't enforce it.

## 3. Instructions

The first byte gives the opcode. The top two bits select the group.

| Encoding | Bytes | Instruction | Meaning |
|---|---|---|---|
| `00rrrrrr vv` | 2 | `MOVE r, v` | Write `v` to register `base + r` |
| `01nnnnnn` | 1 | `WAIT n` | Wait `n` ticks (1–64; the field holds `n−1`) |
| `10nnnnnn lo hi` | 3 | `REF addr, n` | Execute the `n` instructions (1–64; field `n−1`) at `addr`, then continue after the `REF` |
| `11000000 nn` | 2 | `BASE n` | Set this thread's register base to `n` |
| `11000100 nn` | 2 | `WAITL n` | Wait `n` ticks (1–256; field `n−1`) |
| `11000101 lo hi nn` | 4 | `REFL addr, n` | Like `REF`, `n` instructions (1–256; field `n−1`) |
| `11000110 lo hi` | 3 | `JUMP addr` | Continue at `addr` |
| `11000111 lo hi` | 3 | `CALL addr` | Push the return address; continue at `addr` until `RET` |
| `11001000` | 1 | `RET` | Return from `CALL` |
| `1100101p rr mm` | 3 | `WAITBIT r, m` (p=0) / `WAITCLR r, m` (p=1) | Stall while `(reg & m) != 0` (p=0) or `== 0` (p=1) |
| `11010sss` | 1 | `SIGNAL s` | Set signal flag `s` (0–7); IRQ if enabled (section 6) |
| `11100ttt lo hi` | 3 | `FORK t, addr` | Start thread `t` at `addr` with this thread's base (restarts it if running) |
| `11101ttt` | 1 | `KILL t` | Stop thread `t` |
| `11111111` | 1 | `STOP` | Stop this thread |
| other `11xxxxxx` | — | reserved | The thread stops and sets its error flag |

### Entries and `REF`

`REF addr, n` is a subroutine call where the caller gives the length: the thread executes
the `n` instructions it finds at `addr`, exactly as if they were written in place of the
`REF`, and then carries on with the instruction after the `REF`. The instructions at `addr`
don't need a `RET`, and they are usually just an earlier stretch of the same program. So
when a passage repeats, the second time is a 3-byte `REF` back to the first:

```
$1000  MOVE 0, $51      ; AUDF1 - the first time the bar is played
$1002  MOVE 1, $A8      ; AUDC1
$1004  WAIT 2
$1005  MOVE 1, $A4
$1007  WAIT 3
       ...
$2000  REF  $1000, 5    ; the same bar again: executes $1000-$1007, then goes on at $2003
$2003  MOVE 0, $60
```

The count is in instructions, not bytes (a 2-byte `MOVE` and a 1-byte `WAIT` are one each).
An instruction executed inside a `REF` can itself be a `REF` (or `CALL`); it counts as one
instruction of the outer `REF`, however many it runs in turn. Nesting is limited by the
8-entry return stack.

This is an LZ-style back-reference: any earlier passage can be reused without having been
written as a subroutine, which is what makes converted music small. The converter produces
`REF`s; `CALL`/`RET` are for hand-written programs.

A `JUMP` inside a `REF` or `CALL` leaves the stack alone: the level still returns to where
it was called from when its count runs out (or at `RET`). Programs can use this to take a
different route through shared material and still come back to the original place.

Stack entry: return address (16 bits) and the outer level's remaining count (8 bits;
`CALL` stores "unlimited"). Each instruction executed inside a `REF` decrements that
`REF`'s count. When the count reaches zero the level pops, and the pop repeats while the outer
level's count is also zero.

### Errors

Stack overflow (a 9th level), `RET` with an empty stack and reserved opcodes stop the thread
and set its error flag. There are no timeouts: a `WAITBIT` on a bit that never changes
stalls its thread until it is stopped.

## 4. Execution

- The scheduler takes the threads in turn. A thread runs until it executes a `WAIT`, stalls
  on `WAITBIT`/`WAITCLR`, stops, or uses up a budget of **16 instructions**; then the next
  thread gets its turn. The budget stops a thread that never waits from starving the others;
  running until a wait keeps context switches (a few bytes of RAM traffic each) rare.
- On a tick, the wait counter of every running thread is decremented (a read-modify-write
  of one context byte per thread).
- RAM access: the copper uses the sample RAM port when sample DMA and the CPU's RAMDATA
  accesses don't need it. Even at the sample engine's 2×PHI2 rate (about 3.6 M accesses/s)
  a busy tick of a few hundred bytes takes around 0.1 ms.
- A register write takes one free cycle of the internal register bus. CPU writes have
  priority, and CPU bus cycles are about 560 ns apart.
- AMY writes go into AMY's command FIFO like CPU writes. A program feeding AMY in bulk
  should `WAITBIT` on STATUS FULL (`$D2C0` bit 6) or ENGSTATUS FULL (`$D2CE` bit 6) first.

## 5. Tick

PokeyMAX sits in the POKEY socket and sees no video signals, so it can't detect the VBI
itself. But it doesn't need to: the tick counts periods of POKEY's own 15 kHz base clock
(PHI2/114), and an ANTIC scanline is exactly 114 PHI2 cycles. A period of **312** (PAL)
or **262** (NTSC) is therefore exactly one frame, from the same crystal, and once aligned it
stays aligned.

- `CTICK` sets the period in scanlines (1–65535). Other rates, such as 156 for a tune that
  runs twice a frame, are just another value. The default follows MODE's PAL bit (312 or 262).
- The phase starts arbitrary. The `SYNC` strobe (`CCTRL` bit 2) restarts the count and gives
  a tick at once; writing it once from the VBI locks ticks to the frame.

## 6. Control registers, IRQ and feature flags

Eight registers at the free end of the SAMPLE block (`$D295-$D29F` are unused in v1.40):

| Address | Name | Write | Read |
|---|---|---|---|
| `$D295` | `CCTRL` | bit 0 run (0 = all threads frozen); bit 1 `STOPALL` strobe (stop all threads, clear errors and signals); bit 2 `SYNC` strobe | bit 0 as written; bit 7 set if any thread has an error |
| `$D296` | `CADDRL` | start address, low byte | — |
| `$D297` | `CADDRH` | start address, high byte | — |
| `$D298` | `CSTART` | thread number: start it at `CADDR` with base `CBASE` (stack cleared, wait 0) | mask of running threads |
| `$D299` | `CKILL` | mask: stop those threads | mask of threads stopped by an error |
| `$D29A` | `CSIG` | mask: clear those signal flags | signal flags |
| `$D29B` | `CTICKL` | tick period in scanlines, low byte | as written |
| `$D29C` | `CTICKH` | high byte; the period takes effect on this write | as written |
| `$D29D` | `CBASE` | register base for `CSTART` | as written |

`$D29E-$D29F` stay free. `CADDR` and `CBASE` keep their values, so starting the same
program again only needs `CSTART`.

**IRQ.** The copper uses the sample engine's IRQ registers, whose bits 4-7 are free: bit 4
of SAMIRQEN (`$D291`) enables the copper IRQ, and bit 4 of SAMIRQACT (`$D292`) reads 1 while
any signal flag is set; writing 0 to that bit clears all the flags (`CSIG` says which
`SIGNAL`s fired). So copper IRQs are handled exactly like end-of-sample IRQs: the IRQ
handler checks SAMIRQACT. **[open]** Should the eight flags have individual enables instead
(SAMIRQEN bits 4-7 could cover four of them)?

**Feature flags.** CAPABILITY and RESTRICT get second bytes. The configuration window grows
from 16 to 32 bytes: writing `$3F` to CONFIG maps it into `$D210-$D22F`, so while it is
mapped it covers POKEY 3 as well as POKEY 2. `$D210-$D21F` are unchanged.

| Address | Name | Bits |
|---|---|---|
| `$D220` | `CAPABILITY2` (R) | bit 0 AMY; bit 1 COPPER; bit 2 64 KiB sample RAM (0 = 42 KiB); bits 3-7 reserved |
| `$D221` | `RESTRICT2` (R/W) | bit 0 COPPER on; bits 1-7 reserved (AMY's own enable stays in RESTRICT bit 5) |
| `$D222-$D22F` | reserved | room for later settings (AMY, copper defaults, curves) |

`$D22C` is left reserved rather than used, so it isn't confused with CONFIG at
`$D20C`/`$D21C`.

Detect: a core without the wider window shows POKEY 3 (or a POKEY 1 shadow) at `$D220`
even with the configuration mapped, so software checks the version string first (1.41 or
later), then reads `CAPABILITY2`.

With RESTRICT2 COPPER = 0 (or RESTRICT SAMPLE = 0) the copper is frozen and its registers
read as shadows like the rest of the SAMPLE area. **[open]** Default on or off? The copper
does nothing until a program starts it either way.

**Reset.** Power-on, `STOPALL` and the AMY chip-reset command stop every thread. Nothing in
PokeyMAX sees an Atari reset, so software writes `STOPALL` before uploading or starting
programs, which is the lesson from the drum machine's start-up hang.

**Typical start.** Upload the program, write `STOPALL`, set the tick period, write `CADDR`,
`CBASE = 0` and `CSTART = 0`, and set `CCTRL` run. Thread 0 sets each channel's `BASE`,
`FORK`s the channel threads and `STOP`s.
Optionally write `SYNC` from the VBI once.

## 7. Context page

The last 256 bytes of sample RAM, `$FF00-$FFFF`, hold 32 bytes per thread (thread *t* at
`$FF00 + 32t`):

| Offset | Content |
|---|---|
| 0-1 | PC |
| 2 | wait counter |
| 3 | register base |
| 4 | stack depth (bits 0-3), running (bit 6), error (bit 7) |
| 5 | current level's remaining count |
| 6-29 | stack: 8 × (return address 2 bytes, outer count 1 byte) |
| 30-31 | spare |

Samples and programs must leave this page alone while the copper runs. The CPU can read it
through RAMADDR/RAMDATA for debugging; writing it while the copper runs is undefined.

## 8. Program sizes

POKEY tunes converted from their register logs (sapcap), one thread per channel plus
AUDCTL, this encoding, greedy nested `REF` compression:

| Tune | Length | Flat MOVE/WAIT | Copper program |
|---|---|---|---|
| Draconus | 3:00 | 56 KB | 4.1 KB |
| Zybex | 2:11 | 34 KB | 2.5 KB |
| Warhawk | 3:37 | 102 KB | 8.3 KB |

The 6502 players for these tunes cost 5–6 scanlines a frame on average and 11–14 at worst;
the copper takes that to zero. SID and PSG haven't been measured; they write more registers
per frame, so their programs will be larger.

## 9. Serial I/O

POKEY 1's IRQST bits are active low (0 = pending), so `WAITBIT IRQST, $10` waits for
"serial output needed" and `WAITBIT IRQST, $08` for "serial output complete". Sending a
prepared SIO frame is then a run of `MOVE SEROUT` / `WAITBIT` pairs, with `MOVE IRQEN` to
re-arm the bits. The CPU's IRQ handler must leave those bits alone while the copper owns
them.

Receiving can't be done with this instruction set, because nothing stores a register into
memory. **[open]** A `STORE r` instruction (read register `base + r`, write it to a
per-thread RAM pointer, increment the pointer) would allow it, at roughly 25–40 LEs.

## 10. Estimated logic

| Block | LEs (estimate) |
|---|---|
| Fetch/decode state machine, PC, operand registers | 120–160 |
| Current thread's context in registers; load/save to the context page | 90–130 |
| `REF` level count, push/pop and cascade pop | 40–60 |
| Wait counter update on tick | 20–30 |
| Tick divider (16-bit) and sync | 25–35 |
| Control registers (with `CBASE`), decode, status read-back, SAMIRQ bit 4 | 50–70 |
| Register-bus write mux, base adder, copper-side decode (protection, restricted areas), `WAITBIT` compare | 45–70 |
| Sample RAM arbitration | 20–40 |
| **Total** | **≈ 410–590 LEs, no M9K** |

A minimal version without `CALL`/`RET`, `WAITBIT`, `SIGNAL`, `FORK`/`KILL` and `WAITL`/`REFL`
would be about 300–350 LEs.

## 11. Tools (to do)

- `copper.py`: a Python model of the instruction set, scheduler and context page; then the
  reference for a GHDL testbench, compared write for write as with the AMY engine.
- `mkcopper.py`: register log (SAP via sapcap, SID dump, YM, amyconv's AMY event streams) →
  threads → nested-`REF` compression → binary plus a 6502 loader.
- An assembler for hand-written programs (sound effects, SIO sequences).
