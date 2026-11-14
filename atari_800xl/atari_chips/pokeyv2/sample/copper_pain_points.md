# Copper pain points: porting the three AMY players

What got in the way while moving the drum machine, the AMY Music Box and amyconv (all four
sets) from the AMY note engine to copper++ (spec v0.6), roughly in order of how much it hurt.
Each has the workaround the players use now and a suggested fix.

How it went overall: one generic copper program (`amycop.py`, 1.2 KB of code, the same for
every player; only its tables come from the instruments) replaces the engine. In the models,
every player except Draconus produces audio bit-identical to its engine version (item 6 below
explains Draconus). The 6502 sends one copper start per old engine event, and its worst frame
costs about 7–8 % more cycles than with the engine, before any waits on the start latch.

## 1. A start to a busy thread makes the 6502 wait

There's one start latch, and a start is only taken when its thread is at rest. So when the
6502 sends two events to the same voice in one frame, it waits at the second until the copper
has finished the first. That happens with:

- a closed hat's off straight after its on;
- a snare's wires choke;
- amyconv's legato second note;
- a vibrato jump just before a note.

It also blocks every other start queued behind it.

| Player | Back-to-back starts | 6502 wait per frame, worst (core-clock RAM / 2×PHI2 RAM) |
|---|---|---|
| Drum machine | 325 of 1,140 | 0.2 / 1.0 ms |
| AMY Music Box | 12 of 864 | 0.7 / 2.6 ms (set-up: four Rev C selects) |
| amyconv Draconus | 638 | 0.45 / 2.7 ms |
| amyconv Axel F (MOD) | 1,930 | 0.4 / 2.0 ms |

The waits are estimates: the earlier start's RAM accesses and AMY commands at about 2.44 µs
each, less the 6502's own time between the two starts. The old engine had a 16-event queue,
so the 6502 never waited.

**Fix:** when the latch's thread is busy, copy the start (address, base, parameters) into a
mailbox in that thread's context area and free the latch at once. The thread takes its
mailbox when it next rests, instead of a new start being written into it. That's a few more
RAM writes and one flag per thread. Alternatively, keep a pending start per thread, but the
parameters make that about 64 flip-flops per thread.

## 2. A start always replaces the program

amyconv's vibrato is a frequency jump, now a copper start on the voice, so it ends whatever
that thread was waiting in: a retrigger loop or the release ceiling's decay loop. amyconv's
instruments have no retriggers, and vibrato only goes to sounding voices, so nothing is lost
today. Any instrument with a retrigger would break, though: a pitch effect would cancel its
retriggers.

**Fix:** a start flag, for example in a CSTART bit, meaning "call this entry from where the
thread is". The thread pushes its PC and remaining wait, runs the entry to RET, then carries on
waiting. That gives message handling without losing state. A cheaper partial fix is a host
write to one thread register (`CPOKE t, r, v`), for parameters that only change a running loop.

## 3. The 6502 can't safely write the chip while the copper runs

For the Rev C unlock, EXT_RESET, voice types, a chip reset or amyconv's tune cut, the players
stop every thread with STOPALL first. That loses their loops, though the players re-select
every voice straight afterwards anyway.

Freezing instead (CCTRL run = 0) isn't safe. A frozen thread can stop inside a locked command:
the 6502's A/B/C writes then land between the copper's A and its command write, and when the
thread resumes it sends a command with the 6502's operands.

**Fix:** let run = 0 take effect only outside a LOCK, and add a CCTRL status bit saying every
thread is frozen at a clean point. The 6502 sets run = 0, waits for the bit, writes the chip,
and sets run = 1 again, without losing any thread.

## 4. No flow control from AMY

AMY's write FIFO is 4 deep and silently drops a write when it's full. A WAITBIT inside a LOCK
ends the lock. So before each command the copper waits for AMY to be fully idle
(`WAITBIT $C0, $80`), then writes the whole command locked. That costs a stalled slice, and a
context save and load, for nearly every command, and commands never queue up in the FIFO.

**Fix:** backpressure on the register bus. The handshake already allows it: the arbiter or
the device holds `bus_ack` while AMY's FIFO is full, so a MOVE just stalls. The copper program
then needs no WAITBITs at all, and a 6502-style poll can't drop writes either. Allowing WAITBIT
to stall inside a lock without ending it would also do, but it holds the other threads off.

## 5. No clock a program can read

Threads can't tell the time. That means:

- they can't share a vibrato phase;
- they can't timestamp an event;
- they can't reproduce the engine's global 8 ms grid (item 6).

**Fix:** `LDA TICK`, giving the low byte of a free-running tick counter (8 flip-flops plus a
mux input).

## 6. The one difference from the engine: release decay timing

The engine decays a released note's ceiling in steps of its global 8 ms grid. It counts grid
lines between the release and the next note: `t/8 − t_off/8`. The copper decays it every 8 ms
from the release, so `(t − t_off)/8`. The two counts differ by one when the release's phase
on the grid is later than the note's.

Only once in all the tests does that change a "rising attack" decision: Draconus at 80.04 s,
voice 3, seven harmonics with an attack slope instead of a jump. The audio difference there is
37 RMS against a signal of about 2,660 RMS, roughly −37 dB. Arguably the copper is the more
accurate of the two. Matching the engine exactly needs item 5.

## 6a. The tick isn't 1 ms

The players use CTICK = 16 scanlines for a "1 ms" tick. In PAL that's 1.0285 ms, and in NTSC
1.0191 ms (PHI2/114 is 15,556 or 15,700 lines/s). So retriggers and the release ceiling's 8 ms
steps run 2.9 % (PAL) or 1.9 % (NTSC) slow. The engine counted them on the AMY's own clock,
which is also the clock its envelope slopes run on. The models treat a tick as exactly 1 ms,
so the bit-identical results above assume an exact tick.

**Fix:** a second tick source, a 1 kHz enable from AMY's chip clock, selected by a CCTRL bit,
with CTICK then counting in ms. amy1_top's ce is 4.096 MHz at an 8.192 MHz AMY, so it's
ce / 4096: a 12-bit counter, about 15 LEs with the mux. That gives exactly 1 ms in PAL and NTSC,
locked to the envelopes the ceiling model shadows. Frame-locked music keeps using scanlines.

## 7. Arithmetic gaps

Each of these cost code or registers in the generic program:

- **No add-with-carry or subtract-with-borrow:** the 16-bit pitch-offset sum and clamp take
  14 instructions of branches.
- **No shifts:** the voice's harmonic base (8v or 16v) has to come in as a start parameter.
- **`LDT` indexes only 256 bytes:** tables per instrument and harmonic must fit in 256 entries
  (12 × 16 = 192 just fits), and the 13 per-instrument fields are packed into the unused slots
  of those blocks.
- **WAIT takes only constants:** a retrigger period from a table is a DJNZ loop of `WAIT 8`.
- **A thread can't know its own number:** each voice's constants come in through a one-off
  start at set-up (vinit).

**Fixes, roughly by value:**
- ADC/SBC.
- ASL/LSR.
- `WAIT Rn`.
- `LDT addr, Rn` (address + ACC + 256 × Rn).
- R15 set to the thread number at every start.

## 8. Smaller things

- **Detection:** the loader segment detects a PokeyMAX through the config window ($D21C reads
  $01), and the players detect the copper by reading CCTRL's run bit back.
  `CAPABILITY2`/`RESTRICT2` (spec §6) would make both clean, and should come with the core.
- **Writes per event:** a note on is 5 writes plus a latch poll, against the engine's 4.
- **6502 cycles:** about the same. Draconus's worst frame is 2,373 cycles (2,213 with the
  engine) and the MOD's is 2,785 (2,571), not counting the waits in item 1.
- **Copper time:** a note costs 550–940 copper instructions and 1,900–3,200 RAM accesses,
  most of them register operands. How fast that is depends on the RAM arbiter: give the
  copper every free cycle at the core clock.
- **The image needs a home:** the players put it at $E000-$EFFF of sample RAM, so they can't
  use that part for samples. A player that also plays samples has to share the RAM by
  convention.

## What worked well

- **One copper program for three players:** they only supply tables.
- **No instrument data or engine code left in the 6502's memory:** the image is uploaded by an
  XEX load segment that the player then overwrites. amyconv's set 1 shrinks by about 1 KB.
- **LOCK made multi-write commands safe:** the RTL check found every AMY command whole.
- **The model and RTL agree:** the drum machine's first 1.5 s on the testbench gives every
  voice's commands in the model's order.
