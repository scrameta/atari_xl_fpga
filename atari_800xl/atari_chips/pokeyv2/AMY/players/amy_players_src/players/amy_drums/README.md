# AMY Rev C drum machine — copper version

The same 13-piece kit and demo song as the note-engine version, now played through the
**copper note engine**: a copper++ program in the PokeyMAX sample RAM that does exactly what
the AMY note engine did (the Rev C engine extensions included). The note engine itself is gone
from the core.

`amy_drums.xex` needs the copper with copper++ (spec v0.6) in the sample engine, 64 KiB
sample RAM and AMY Rev C at 8.192 MHz. Its first load segment puts the copper program in the
sample RAM at $E000 (nothing is left of it in the 6502's memory), then the player loads. Any
key stops it; R switches the Rev C features. The screen goes white while the player code runs.

## What the 6502 does now

Each note-engine event of the old player is one copper start on the voice's thread (thread v
plays voice v), from the same 50 Hz frame loop:

| Event | 6502 writes |
|---|---|
| note on (note, level, 8 harmonics) | 3 × CPARAM, CADDRL, CSTART |
| note off, instrument select | CADDRL, CSTART |

CADDRL picks the entry for the voice's current instrument (the player keeps track of it, as the
engine did); CADDRH picks the Rev C mode's entries and changes only with R. Before each start
the 6502 waits for CCTRL bit 6 (the start latch is free). The closed hat's note-off straight
after its note-on, and the wires' choke, wait there until the copper has finished the note-on:
see `copper_pain_points.md` in the copper package.

## The copper note engine

`make` builds it from the kit itself: the `KITDUMP` host build of `amy_drums.c` writes the
kit's note-engine words (`kit.json`, the words the old player uploaded), `copgen.py` turns them
into the copper image (`copper_kit.bin`: entry stubs, the instrument tables, the generic engine
code; 3 KB), its load segment (`copper_kit.xex`) and the entry constants (`copper_kit.h`).
The program is the same for every kit; only the tables change.

## How the kit maps onto the note engine

An engine event sets all eight slots of its voice, so each voice belongs to
one group of instruments that may cut each other:

| Voice | Instruments | Engine features |
|---|---|---|
| 0 | kick, 808 | pitch drop +24 st, τ 8 ms (808: +10 st, τ 16 ms); detuned, diffused beater partials; noise click |
| 1 | snare head | membrane modes by detune, diffusion rattle, +3 st drop |
| 2 | snare wires | white-noise voice (type 3): crack, body, tail |
| 3 | hats | 5 diffused partials + 3 noise slots; closed = note-off at once |
| 4 | crash / ride / cowbell | partials + noise slots; cowbell uses **proportional decay** (fast, then slower: the 808 two-stage shape) |
| 5 | clap | original type-1 noise band, **retrigger** 3 × 8 ms, noise snap |
| 6 | toms | membrane modes, +5 st drop (τ 32 ms), stick click, panned per hit |
| 7 | rimshot | inharmonic ring and stick click |

**Noise inside a tonal voice.** A slot with diffusion 63 gets a random
phase step of up to ±0.94 cycle every sample, so it is white noise with its
own envelope. That replaces the two shared white-noise voices of the old
player. Those voices couldn't stay: an engine note-on on them would have
released every other instrument's noise layers.

What changed against the old scripts, all small:

- Hats and the crash have 5 partials instead of 8; the noise slots cover
  the top.
- The cowbell's two stages are one proportional decay.
- The clap's room tail comes from its outer bands' long decays.
- The kick and tom sweeps are exponential to the end, with no final glide.

Pitches are quantised to semitones above the note-0 word (2418, chosen so
the snare and toms are exact). The others are within ½ semitone.

## Start-up

`configure()` stops every copper thread first (they keep running through an Atari reset), then
resets the chip, sets it up as before and starts the copper (`cop_init`: a 1 ms tick, each
voice's constants). Every wait on the chip or the copper is bounded, so a wedged chip can't hang
the program.

## Checks

| Check | Result |
|---|---|
| `make check`: the player's log through the copper model and the chip model, against the engine version's log through the engine model | AMY writes identical in every ms but one (the old player reset the chip twice at start); audio bit-identical (87.5 s) |
| `make test`: the cc65 build in `sim65` against the gcc host build | Identical logs |
| The copper program on the RTL (`tb_copper`), the first 1.5 s of starts | Every AMY command whole, each voice's commands as in the model |
| The load segment in py65 | Writes the image to $E000 through RAMADDR/RAMDATAINC on a PokeyMAX, nothing otherwise |

## Things to listen for on hardware

1. **Diffusion-63 noise:** the kick click, hat and cymbal sizzle, stick
   clicks and clap snap. If it sounds tonal or too grainy, the type-3
   white path is the alternative for whole voices.
2. **Closed hat length:** the hat header's release slope, `DEC(45)`.
3. **Cowbell:** proportional decay τ 256/128 ms. `PROP(2, k)` in its slots.
4. **Levels:** the slot levels and `MASTER_VOLUME` were set in the model.
   The extensions-off pass is the loudest part (about 0 dBFS in the model),
   because its noise slots become tones.

## Files

- `amy_drums.c`: kit and player. `amy_io.h` / `amy_host.c`: register access, and the logging stand-in for host and sim65 builds.
- `../common/cop.h`: the copper note engine driver (shared with the AMY Music Box).
- `tools/engine.py`, `tools/amy_model.py`: the engine and chip models (the reference for `make check`).
- `test/engine_log.txt`: the engine version's log.
