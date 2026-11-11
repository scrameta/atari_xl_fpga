# AMY Rev C drum machine — note-engine version

The same 13-piece kit and demo song as before, now played through the note
engine with the Rev C engine extensions (spec §6.8). Each hit is one engine
event, sent from a 50 Hz frame loop. The 1 ms POKEY timer and the 6502
envelope, sweep and burst scheduling are gone.

`amy_drums.xex` needs the C.3 RTL with `revc_prop.patch` and
`revc_engine.patch` (the timing patches don't change behaviour). The screen
goes white while the player code runs.

**Keys:** R switches the Rev C features on or off (it's on at start); the
change takes effect at the next bar, when the kit is set up again, unlocked
or locked. Any other key stops.

**Volume:** the kick is the loudest voice. With Rev C on, every other
instrument is trimmed down 3 dB (`MIX_TRIM`, sent as `EXT_VATT` on select)
and the master volume is 160 (`VOLUME_EXT`). With Rev C off there are no
trims, the noise slots become tones and there are no pitch drops, so it
runs at 112 (`VOLUME_OFF`). Both peak just under 0 dBFS in the model.

## What the 6502 does now

Per frame, if a step is due: one `$90+v` note-on per instrument (W0 note,
W1 level from velocity, W2 = 8). There are also a few extra writes:

- The closed hat sends `$80+v` straight after its note-on, so the release
  slope is its decay. The open hat rings until the next hat hit.
- A snare hit also hits the wires voice. A rimshot releases the wires.
- Panned instruments (toms, cowbell) change the LEFT/RIGHT masks.
- An instrument select (`$A0+v`) is sent only when a voice changes
  instrument, e.g. kick/808 or crash/ride/cowbell at a section change.

Grooves run on whole frames, so the timing is exact:

| Groove | PAL | NTSC |
|---|---|---|
| Electro, ride | 7 frames a sixteenth (107 bpm) | 8 (112 bpm); ride 9 (100 bpm) |
| Funk, swung | 9 + 7 (94 bpm, 56%) | 10 + 8 (100 bpm, 56%) |

On the full RTL, a busy step (kick, snare, wires, closed hat with its
note-off, clap) has all its attacks on the chip within 0.5 ms of the
first. The old player needed about 2 ms. The clap's three retriggers follow
at 8, 16 and 24 ms.

## How the kit maps onto the engine

An engine event sets all eight slots of its voice, so each voice belongs to
one group of instruments that may cut each other:

| Voice | Instruments | Engine features |
|---|---|---|
| 0 | kick, 808 | kick: 49 Hz with its 2nd–4th harmonics nearly as loud as the fundamental (a driven, square-ish body), pitch drop +24 st with τ 16 ms; detuned, diffused beater partials; noise click. 808: +10 st, τ 16 ms |
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

## Checks

| Check | Result |
|---|---|
| `make test`: the cc65 build run in `sim65` against the gcc host build | Identical register logs for the whole song, Rev C on (7,276 writes) and off |
| `test/rtl_engine.py`: the engine writes through the RTL engine (`tb_engine`), against `tools/engine.py` | Identical push for push: the first 15 s (set-up, tour) with Rev C on and off; the whole song in the version before the toggle (65,706 pushes) |
| `test/latency.py`: set-up plus one busy step on the full RTL (`amy1_top`, 8.192 MHz) | Within 0.5 ms (above) |
| `test/check_log.py` on the expanded chip log | No extension command while locked, no stuck harmonic, frequencies in range, LHP layout as intended |
| Tour against the old player in the model | Each instrument's peak, RMS, brightness and decay length within a few dB / similar |

`tools/render.py` runs the log through the engine model and then the chip
model (`tools/amy_model.py`, which now also has proportional mode) to give
`preview/amy_drums_preview.mp3`. That's a guide to intent, not what the FPGA
will sound like exactly.

## Things to listen for on hardware

1. **Diffusion-63 noise:** the kick click, hat and cymbal sizzle, stick
   clicks and clap snap. If it sounds tonal or too grainy, the type-3
   white path is the alternative for whole voices.
2. **Closed hat length:** the hat header's release slope, `DEC(45)`.
3. **Cowbell:** proportional decay τ 256/128 ms. `PROP(2, k)` in its slots.
4. **Levels:** the slot levels, `MIX_TRIM` and the volumes were set in the model.
   With Rev C off it runs at a lower volume, because its noise slots become tones.

## Files

- `amy_drums.c`: kit, engine upload and player. `amy_io.h` / `amy_host.c`: register access, and the logging stand-in for host and sim65 builds.
- `tools/engine.py`: engine model. `tools/amy_model.py`: chip model. `tools/render.py`: both, to WAV. `tools/tour_stats.py`: per-instrument comparison.
- `test/`: `check_log.py`, `rtl_engine.py`, `latency.py` (the last two need the RTL tree and GHDL).
