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

## The copper note engine

The instruments live in the **copper note engine**, a copper++ program in the PokeyMAX sample RAM
that does exactly what the AMY note engine did, in the 4 × 16 layout (the note engine itself is gone
from the core). The XEX's first load segment puts it in the sample RAM at $E000, so it costs the
player no memory. The 6502 runs only JCODE's score state machine, once per frame, and sends events,
each a copper start on the voice's thread: a note on is note, level and band limit (CPARAM) then
CADDRL and CSTART; a note off or an instrument select is CADDRL and CSTART. The copper writes every
harmonic breakpoint: the jump or rising attack (from the harmonic's remaining level), the decay after a
jump and the release, as the engine did. The screen background goes white while the player code runs.

`mkinst.py` writes the instruments' note-engine words (`inst_words.json`); `copgen.py` (in the copper
package) turns them into the image, its load segment and `copper_box.h`. The copper program is the same
for every player; only its tables come from the instruments.

**Rev C features (key R, on at start).** With them on, the extensions are unlocked and the copper uses its
Rev C entries: each instrument select also sends the instrument's per-harmonic detune and diffusion:

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
make                                         # mkinst.py, copgen.py, cl65: amybox.xex
make check                                   # CANTINA through the copper and chip models, against the engine version
```

It needs AMY Rev C at 8.192 MHz and the copper with copper++ (spec v0.6), 64 KiB sample RAM. AMY is expected
at `$D2C0`. `COPPER=` points the Makefile at the copper package (default `../../copper`).

## How it was checked

* `make check`: CANTINA (PIANO, Rev C on) from the host build's log, through the copper model and the Rev C
  chip model, against the engine version's log through the engine model: the AMY writes are the same in every
  ms and the audio is bit-identical. The same for the BAND and SYNTH ensembles (generic test in the copper
  package).
* The host build (`make host`) logs every AMY and copper register write; the 6502 build makes the same calls.

`amybox_preview.mp3` has 25 s each of CANTINA (piano), ENTERTA (band) and CANTINA (strings), with Rev C on, made with the engine version (the copper version sounds the same: bit-identical in the model).
