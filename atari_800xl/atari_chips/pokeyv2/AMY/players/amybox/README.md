# AMY Music Box for PokeyMAX

A re-creation of the **AMY Music Box** that John Howard Palevich wrote at Atari in August 1983, playing
the songs from the 1983 AMY demo disks on the PokeyMAX AMY.

## What the original was

The demo disks hold `MBOX.C`, `PARSE.C` and `JCODE.ASM` for an **IBM PC**. The PC parsed Atari Music
Composer `.MUS` files and, from a 72.8 Hz timer interrupt, sent Chroma-style key events (`$D0+v` note
velocity pressure for key down, `$D8+v` for key up) through the printer port to an **8051** that
drove AMY. The 8051 firmware and its instruments (`.SND` files) are not on the disks, so the sounds
here are new. Everything else follows the original:

* `mus.py` is a port of `PARSE.C`: phrase and arrange records, Go/Count/Transpose/Volume, ties and slurs,
  and the accent on the first note of each measure (+16 velocity).
* The player runs JCODE's state machine: one score unit every `tempo` ticks of a 72.8 Hz clock (driven
  from the VBI counter, with PAL/NTSC rates), with attack, count down, release and gap.
* There are 26 songs: all the `.MUS` files from disk 3 (except the SCALE test) plus `UP.MC` from disk 1.

## The sound

* There are 4 voices of 16 harmonics. Each harmonic has its own envelope, so an instrument is a spectrum plus
  per-harmonic attack, decay and release rates (`mkinst.py`). Instruments: PIANO, MUSICBOX, ORGAN,
  BRASS (upper harmonics swell in later), CLARINET (odd harmonics), STRINGS and SYNTH.
* Harmonics too close to the chip's Nyquist frequency are skipped per note (the band limit sent with each note).
* It uses INDIVIDUAL mode for stereo: voice 0 left, voice 1 right, voices 2 and 3 centre (registers 4/5).

## The note engine

The instruments live in the PokeyMAX AMY note engine (Rev C spec §6), in the 4 × 16 layout. The 6502 runs
only JCODE's score state machine, once per frame, and sends events. A note on is four stores: note, level,
band limit and `$90+v`. A note off is one store, `$80+v`. A voice changing instrument is `$A0+v`. The engine
writes every harmonic breakpoint: the jump or rising attack (from the harmonic's remaining level), the
decay after a jump and the release. This is the same logic the old `harm.s` loops did. The screen background
goes white while the player code runs, which is now a thin band.

**Rev C features (key R, on at start).** With them on, the extensions are unlocked and each instrument select
also sends the instrument's per-harmonic detune and diffusion from the engine's extension page (§6.8):

| Instrument | Detune (F3) | Diffusion (F4) |
|---|---|---|
| PIANO | stretched partials, stiff string: f_k = k·f·√(1+Bk²), B = 0.00018 (+23/64 at k=16) | – |
| MUSICBOX | stiffer, B = 0.0012: metallic tine | – |
| STRINGS | – | 0 on the fundamental, rising to 20 (2–16 Hz line width): bowed, ensemble roughness |
| BRASS | – | 0–10, rising (up to ~3 Hz): breath |
| CLARINET | – | 3 throughout (~1 Hz): breath |
| ORGAN, SYNTH | – | – (pure) |

With them off, the extensions are locked (which clears the coefficients) and the same instruments play
with exact harmonics.

## Keys

| key | |
|---|---|
| A–Z | play that song (it moves on to the next one when a song ends) |
| SPACE | next song |
| 1–4 | step that voice to the next instrument |
| 0 | next ensemble (PIANO, BAND, MUSIC BOX, ORGAN, STRINGS, SYNTH) |
| + / - | volume (PokeyMAX register 6) |
| * | stereo / mono |
| R | Rev C features on / off |
| ESC | stop |

## Build

```
python3 mksongs.py songs.h <.MUS files>      # songs.h (included)
python3 mkinst.py                            # inst.h  (included): engine store and extension page
cl65 -t atari -Oirs -o amybox.xex amybox.c
```

It needs AMY Rev C at 8.192 MHz with the note engine and its extensions (`revc_engine.patch`). The older clock
builds (2×PHI2, 4×PHI2, CLK/8) are gone, since they predate the engine extensions. AMY is expected at `$D2C0`.

## How it was checked

* `amybox.c` builds natively too (`cc -O2 -o amybox_host amybox.c`) and logs every AMY register write. The sim65
  build of the 6502 code logs the same writes: byte-identical for CANTINA (4,800 writes).
* Against the previous direct-drive amybox: the logs run through the engine model (`engine.py`, checked push for push
  against the RTL engine) and the Rev C chip model. Its loudness, measured every 50 ms, matches the old player's
  within 0.2 dB (correlation 1.000) for CANTINA and ENTERTA in the PIANO and BAND ensembles. Peaks are the same
  to 0.2 dB.
* With R off, the expanded log has no extension command at all. With it on, it has `EXT_RESET` and each select's
  `EXT_VATT`, 16 `EXT_HDET` and 16 `EXT_HSTOCH`.

`amybox_preview.mp3` has 25 s each of CANTINA (piano), ENTERTA (band) and CANTINA (strings), with Rev C on, through
`tools/preview.py` (engine model, then the chip model). It's the model, not the chip.
