# AMY versions of Atari classics

Atari classics rearranged for AMY from their ASMA SAP files and played from a VBI through the
PokeyMAX AMY note engine (Rev C, 8.192 MHz). There are three XEX files, one per tune set, because
each set's event streams fill the 6502's memory:

| XEX | Tunes |
|---|---|
| `amyconv.xex` | Draconus, Zybex (Adam Gilmore, 1988), Warhawk (Rob Hubbard, 1986) |
| `amyconv2.xex` | Happy Train to Kingdom of Pleasures (Adam Bienias, 1994), Axel F (Torsten Karwoth, 1990), Bitter Reality (Adam Bienias) |
| `amyconv3.xex` | International Karate, Jet Set Willy (Rob Hubbard), the first 3 minutes of each |
| `amyconv4.xex` | Axel F, DJ Metune's 2015 Amiga ProTracker module (after Ron Klaren's 1988 arrangement), the whole song: a MOD conversion, see below |

**Keys:** START next tune, SELECT previous, OPTION Rev C features on/off (shown on screen; on at
start). The screen goes white while the player runs, so its share of each frame shows as a white
band. A new tune starts from silence (every harmonic jumps to 0, then two quiet frames); at its
end a tune loops with the voices carrying on.

Needs the engine (`ENGINE => true`) with the Rev C engine extensions (`revc_engine.patch`), the
AMY Rev C at 8.192 MHz (`STEP_NUM / STEP_DEN = 3 / 7`, `ENGINE_UNIT_LOG2 = 15`) and AMY at `$D2C0`.
It uses the engine's 8 voices × 8 harmonics and INDIVIDUAL output (voices 0 1 3 6 7 left, 0 2 4 5 6
right).

## Rev C features

With them on, the extensions are unlocked, and the engine's extension page (uploaded at start, all
128 words) gives each instrument select some extra data:

| Instrument | Rev C on |
|---|---|
| HAT, SNARE | white noise (voice type 3) instead of the original noise generators, trimmed 4 dB to the same loudness |
| KICK (set 1) | an exponential pitch drop (proportional mode, τ 16 ms) from 130 Hz to 46 Hz, instead of AMY's fastest linear glide; detuned, diffused beater partials and a noise click |
| PAD, PAD2 | a slow shimmer: diffusion rising from 0 on the fundamental to 18 |
| SWELL | the same shimmer, and the attack is an exponential rise (proportional mode, τ 16 ms) instead of the linear 1000 dB/s |
| BUZZ | a little grit: diffusion 2–12 on the upper harmonics |
| LEAD, TOM | unchanged |

With them off (OPTION), the player locks the extensions, puts the original noise voice types back
and selects every voice's instrument again: exactly the previous sound. Both modes have the same
loudness in the model.

## How a tune is made

1. `sapcap.py` runs the SAP's 6502 player (py65) and captures POKEY every frame.
2. `pokey.py` / `sap2notes.py` turn each channel into notes: the joined 16-bit bass in
   distortion C (pitch from the poly-4 period: f = PHI2 / (15 (N + 7)) for most N), pure
   tones, noise hits; split notes where the pitch moves or the volume jumps back up.
   Set 1 uses `notes2()` (see "Set 1 note extraction" below); sets 2 and 3 use `notes()`.
3. `arrange.py` gives them AMY voices:
   * v0 BUZZ: the distortion-C bass, with the harmonic spectrum of the real poly-4 waveform
     (nearly flat), softened a little;
   * v1, v2 LEAD: POKEY channels 3 and 4, a square with a touch of even harmonics, plucked
     like the POKEY volume ramps;
   * v3 (and v4 without the kick): notes that swell (POKEY volume rising), with the original's
     vibrato. PAD2 for a slow swell (Draconus: 14 frames to the peak), SWELL for a quick one
     (Warhawk's lead: 5 frames); `arrange()` picks by the tune's median. A swelling note
     straight after another gets a dip first, as on POKEY: note-off at its frame, note-on one
     frame later (SWELL) or two (PAD2);
   * v5 HAT, v6 SNARE: POKEY noise hits by noise rate, on AMY noise voices (below);
   * v7 TOM: Gilmore/Hubbard's falling-pitch hits (tone frames whose pitch falls every frame,
     noise frames between them allowed), as a note plus a legato note gliding down: 3 semitones
     past the end for a fall of 0.9 semitones or more, 1 semitone for less, no glide under 0.3
     (Draconus's low plucks: the same POKEY instrument as its high ones, so the same voice).
   The drums come from the drum-kit experiment, refitted to 8 harmonics. HAT (v5, noise
   generator 0): harmonics 3-8 of ~1.4 kHz (4.2-11 kHz), ~40 ms. SNARE (v6, generator 1): a
   hiss, harmonics 3-8 of ~1.3 kHz (3.9-10.6 kHz), ~150 ms; Warhawk's snare (a 1-frame click
   then a burst 2 frames later) is one hit. Both generators S = $80F.
   * v4 KICK: added (the originals have none): 130 Hz gliding to ~46 Hz at AMY's fastest glide
     (a legato second note), a long low tail and a short click. Warhawk: halfway between the
     backbeat snares (beats 1 and 3); Draconus: bar positions 0 and 30 of 80 frames where the
     bass plays; Zybex: beats 1 and 3 where the bass plays, while there are drums. The pads
     then share v3. `KICKS = False` in arrange.py gives the version without.
   `chip_init` sets the voice types and loads the Noise RAM once (NZINIT, 64 writes from
   `noiseram`). Needs the PokeyMAX core's `NOISE_FIX`; without it the drums buzz.
4. `instruments.py`: the engine instrument tables. `encode.py`: the event stream, with
   back-references (Draconus 13.1 KB of events -> 6.4 KB, Warhawk 35.5 KB -> 15.8 KB).
5. `mkconv.py` writes a set's `convset.inc` (`AMYCONV_SET=1..3`); `amyconv.s` is the player.
6. The newer tunes don't follow the Gilmore/Hubbard layout (bass on channel 2, leads on 3 and 4):
   any channel plays bass, tones and noise. `arrange_generic` gives voices by what a note is:
   v0 BUZZ for every distortion-C note (they never overlap in these tunes), v1–v4 the tones of POKEY
   channels 1–4 (LEAD, or PAD for a channel whose notes mostly swell slowly),
   v5 HAT, v6 SNARE and v7 TOM as before. Each of these tunes gets a level offset so that all
   eight play at about −22 dBFS RMS (Axel F's melody 2.5 dB further forward, its bass 1 dB back).
   Two kinds of tone fragment are dropped as not being notes: a 1–2 frame tone just before a noise
   hit on the same channel (the drum's attack: Jet Set Willy's 3 kHz tick before every drum,
   which otherwise whistled all through), and a 1-frame lead-in at the pitch of the note that
   follows straight on (Axel F's quiet blip before each melody note). PAD is only for a slow swell
   (the peak 4 or more frames in); Axel F's melody has a quick 2-frame attack and is a LEAD.
7. Note-offs (all eight tunes). A note gets an off at its end unless the voice has a new note or
   an off by then. Before this fix only each voice's last note got one: every other note sustained
   until the next note on its voice, and that next note played legato (no new attack). The
   engine holds a note at the instrument's sustain level, but a POKEY note can fade on well
   past that (Axel F's long notes from 28 s and 63 s: 15 down to 5 in 8 frames, then 1.6 s
   fading to nothing).
   * Sets 2 and 3 (`arrange_generic`) follow the fade: each time the POKEY volume has fallen
     another sustain step below the peak (LEAD 6 dB, BUZZ 8 dB), the note is played again legato
     one step lower (`fades()`). The engine jumps to the level it was sustaining at and decays
     one step more, so the note steps down in smooth decays: −6 dB, −12 dB from frame 8,
     −18 dB from 55 and −24 dB from 79, then the off at 91. In the preview this follows the
     POKEY tone level within about 1 dB through those notes.
   * Set 1 lets a LEAD or BUZZ note go once its POKEY volume is 11 dB (LEAD) or 13 dB (BUZZ)
     below its peak, and the release does the fade (`TAIL_DB`, `sounding()`). That costs no
     memory. Warhawk now has all its offs too (`LEGATO_GAP` is empty): with the new note
     extraction set 1 is 3.8 KB smaller and they fit.
   * The offs make set 1 0.2–1.1 dB quieter (Warhawk the most); sets 2 and 3 are within ±0.5 dB
     of before (Axel F's offset is now −8).

8. The end of the stream (all eight tunes). The stream starts again with the voices carrying
   on, so a voice still holding a note there held it until its next note came round: 34 s for
   a lead in Happy Train, 6 s in Jet Set Willy, 4 s for the bass and a lead in Bitter Reality
   (and it would be 5 s for Warhawk's lead voice now). `close_at_end()` lets every sustaining
   voice go in the last frame.

## Set 1 note extraction (`sap2notes.notes2`, `arrange.arrange`)

What was wrong, and what replaced it:

* **Vibrato split notes.** A new note started whenever the pitch was 0.6 semitones from the
  note's first frame. Warhawk's lead swings AUDF $28..$2B (1.2 semitones peak to peak, more
  higher up), so each held note became 5 to 10 short ones, the first few on the pad voice and
  the rest plucked on the lead voice. Now a note changes on a step between two frames (over
  0.75 semitones), or where the pitch averaged over the 8-frame vibrato cycle moves 0.5
  semitones (a change hidden under the vibrato: Draconus at 5530, 5580, 5920). A note's pitch
  is where it sits, or the middle of its swing; the vibrato depth is half the swing (it was
  the distance from the first frame, so twice too deep whenever a note started at the end of
  its swing: Zybex's vibrato is now the original's depth).
* **A swell split in two.** Volume 2 3 4 7 8 9 was cut at the 7. A step up is now a new attack
  only after the volume has fallen; a drop that swells again (6 6 6 | 2 3 4 7) starts a note.
* **The pad was too slow for Warhawk.** PAD rises 120 dB/s from silence: 0.4 s, for a POKEY
  swell of 0.1 s. Its lead now uses SWELL.
* **Swelling notes ran together.** A legato note-on on a pad only moves the pitch, so a line of
  swelling notes (Draconus 80-97 s, all of Warhawk's lead) played as one unbroken note. Now
  each dips and swells (step 3 above).
* **Arpeggios as toms.** `sweeps()` took any two tone fragments, the second lower, for a
  falling-pitch hit, so the falling half of every arpeggio step in Warhawk was a tom gliding
  down 3 semitones and never let go (885 of its 927 toms). Falling-pitch hits are now found on
  the raw frames.
* **One channel stopping the other's note.** A tom on channel 4 let go of the pad voice even
  when channel 3's note had it: Draconus's melody note at 96.8 s was cut after one frame, and
  twelve more after it. A channel now only lets go of a voice that has its own note.
* **Plucks on two voices.** Draconus's channel 4 from 96.8 s is one POKEY instrument (AUDF + 2
  a frame); its high notes were toms on v7 (left) and its low ones leads on v2 (right). All
  are on v7 now.
* **Odd frames.** The frame of distortion C inside Warhawk's bass-channel snare was a 1-frame
  bass note at 196 Hz ringing on for 7; it is part of the drum. The last frame of each Hubbard
  bass note (volume 8 9 7 5 4 3 2 5) was a second note; it is the tail. A frame or two at
  volume 1 after a pluck is not a note.

The engine's clock is 8 bits of 8 ms. 2.048 s after a note-off, and every 2.048 s from then on,
it takes the voice for just released, and a pad's attack is a jump: Draconus's pad at frame
4000, 2,560 frames after the previous one ended, came in at full level. The arrangement now
selects the instrument again before a swelling note that follows a rest of 1.8 s or more, which
clears the engine's ceiling for the voice. The player posts instrument events after the
stream's first frame on every pass for this (it skipped them all when looping).

```
./build.sh            # all four sets: convset.inc, ca65/ld65, bench.py (needs cc65, py65, the ASMA tree)
python3 test_mode.py amyconv.xex build/set1/amyconv.lbl     # the OPTION handler in py65
python3 preview.py 2 0 on happy_train.wav 60                 # model preview: set, tune, Rev C on/off
```

The screen turns white while the player runs: the VBI only marks the frame, and the main loop
runs it at VCOUNT 16 (on screen; in the vertical blank the colour would never show).

## Set 4: a ProTracker module (`mod2amy.py`, `mod_instruments.py`, `mod/`)

DJ Metune's Axel F (`mod/axelf.mod`, 4 channels, 31 samples, 116 BPM) plays from the same player
and stream format. The conversion works from the module's own data: no hand transcription.

* `mod/modplay.py` plays the module tick by tick (the ProTracker effects it uses: volume slides
  and sets, fine slides, sample offset, portamento, tone portamento, vibrato, pattern break,
  tempo) and gives each channel's sample, period, volume and playback position every tick.
  `mod/modmix.py` mixes those states; it matches libopenmpt's render in level (−23.7 dBFS both)
  and timing (within 0.05 %).
* `mod/samples.py` says what each sample is, from analysing it (`mod/yin.py` pitch,
  `mod/harm.py` harmonics over time, `mod/track.py` a spectral note tracker):
  * one note: the bass (9 samples, one patch), the lead (24), bell/chip (11 28, the tick 4),
    pluck (25), organ (27);
  * the pad (26) is a sampled sus4 chord (Eb4 F4 Bb4 and their octaves at its long note's
    pitch): two voices, PAD on the Eb and PADF on the F;
  * chord stabs (21 22 23 2): each is three hits of a major triad. Harmonics 4 5 6 8 of one
    AMY voice are a major triad in close position with its octave (just intonation). A stab
    is up to three such voices, two octaves and one octave under the root and at the root, at
    the levels the sample has them (`STAB_VOICES`); the upper two give way when the pool is full;
  * sampled riffs (29 30): the tracker's notes, up to 3 at a time;
  * drums: kick (18), snare (19), clap (12); the snare and clap samples carry a low body
    (133 Hz, 69 Hz), which plays as a kick-voice hit under the noise. Each is a note-on, a
    note-off after 2 to 4 frames and the release, fitted to the sample's shape;
  * sampled rhythms: the hat loops (6 10 20 31) are cut into their hits (onsets in the
    sample); each hit is held to the end of its plateau (about 50 ms) and released;
  * sampled noise: the riser (1) and the gated noise (17) are one held noise note whose level
    follows the samples' (a step for every 1.5 dB, the channels playing it added up), on the
    snare's voice, carrying on after each snare hit.
  A hit plays when the channel's playback position passes it, loops and sample offsets included,
  so a loop restarted mid-bar plays the right part. A sample offset that lands inside a hit
  plays what is left of that hit (see "What changed in set 4").
* `mod2amy.py` turns them into events. Voices: v0 bass, v1-v3 and v7 a pool for the other tonal
  notes (an instrument select when a pool voice changes instrument: 110 in the song),
  v4 snare, clap and the noise swells (noise), v5 hats, v6 kick (v0 and v6, bass and kick, are
  the voices in both output channels). A retriggered note is an off then an on (a new attack). Channel
  volume changes are legato re-plays: for the decaying instruments in steps of their sustain
  depth (as the SAP fades), for the held ones every 1.5 dB. Vibrato effects use the player's
  vibrato; a pitch slide is a legato re-play when it crosses a semitone.
* Timing: ticks are 21.55 ms, so a row is 6.47 frames. Each tick goes to the nearest frame
  counted from its pattern's start: a repeated pattern gives the same frames, and the stream
  compresses to 19 KB (the song is 3:04). Rows land within ±10 ms of the module's timing.
* 12 instruments (the most the engine RAM holds), fitted to the samples: `mod_instruments.py`.
  The levels (`BASEL`) were set by `mod/calib.py`: each instrument group alone in the model
  against the module's own samples for it (modmix), all within ±0.5 dB of the same offset,
  then the whole tune set to the other sets' loudness. (The kick was in fact 5 dB over the
  others by that measure, the snare 2 and the clap 3; all twelve groups are now within 1 dB.)
  With the kick down the tune is 1.6 dB quieter than it was: RMS −23.5 dBFS a channel in the
  model, peak −2.4 dBFS Rev C on, −0.5 dBFS off, which leaves no room to bring it back up.
* What AMY can't do here: 8 harmonics per voice. The bass and lead lose the module's partials
  above the 8th (the lead sample has some up to ~5 kHz); the overall spectrum is within ~2 dB of
  the module's in each band from 30 Hz to 6 kHz. Rev C on gives the lead and pad a chorus
  (detune and light diffusion) and the kick its pitch drop.

### What changed in set 4

Each instrument group alone in the model, against the module's own samples for it (modmix):

* **Hits lost to sample offsets.** A hit played only when the playback passed its first byte.
  A 9xx offset often starts inside one: 97 of the hat loops' 362 triggers, 34 of the 162
  stabs (26 of those played nothing), 56 of the 70 riffs. Those hat hits came 120 ms late
  (the next hit in the loop) or not at all. The hit under way now plays from the trigger.
* **Hats the module doesn't play.** A hat loop cut a few ms into its next hit played that hit
  in full. A hit with under 30 ms to go before the channel stops is left out.
* **Hats too short.** They decayed from the start and were 30 dB down after 80 ms; the
  samples' hits are level for 50 ms and 30 dB down after 125 ms.
* **Kick twice too long**, and its harmonics 2-4 8 dB too strong. The sample is level for
  60 ms and gone by 100 ms; the kick was 30 dB down after 220 ms.
* **Snare and clap**: the noise now has each sample's shape; the snare's body no longer
  rings on under it.
* **The riser was four blips.** The note tracker found four short notes in 1.5 s of rising
  noise. The riffs lost the notes the tracker reports from partials and tails.
* **Lead, pad and organ came in late.** Attacks of 300, 90 and 120 dB/s are 0.15 to 0.5 s from
  silence; the samples are at full level in 20 ms.
* **The stab had no third in its octave**, and nothing above 4 x the root; **the pad** was a
  Bb power chord where the sample is Eb F Bb.
* **Voice stealing** took the first voice of the pool whatever it played; it takes a stab's
  upper voice first, then the quietest note.
* **The second time round.** The player skipped every instrument event once the stream had
  looped, so from the second pass no pool voice changed instrument (py65: 20 selects in the
  first 60 s of pass 1, none in pass 2). It now skips only those of the stream's first frame.

```
AMYCONV_SET=4 python3 mod2amy.py                 # event summary
python3 preview.py 4 0 on axel_f_mod.wav         # model preview
python3 mod/calib.py OUTDIR 184 "SNARE;KICK"     # per-instrument levels against the module
```

The screen turns white while the player runs: the VBI only marks the frame, and the main loop
runs it at VCOUNT 16 (on screen; in the vertical blank the colour would never show).

## Checks

* `build.sh` runs `bench.py` on each set: the player in py65 posts exactly the arrangement's
  events for every frame of all eight tunes, its vibrato writes match, its engine and extension
  page uploads match `instruments.py`, and `chip_init` is unchanged. The worst frame is 2,258
  cycles (20 scanlines), Draconus's first; set 4's is 3,074 (27 scanlines).
* `test_mode.py` passes for set 4 too (its voice types: v4 and v5 noise, v6 the kick).
* `test_mode.py`: OPTION off writes the lock, the 8 original voice types and 8 selects with each
  voice's instrument; on writes the unlock, `EXT_RESET` and the same 8 selects.
* `preview.py` (Rev C off, through `engine.py` and `render8.py`) matches `build.py`'s render of
  Warhawk in level (RMS 2,517 against 2,515).

Earlier checks, still valid for set 1:

* `bench.py`: the 6502 player in py65 posts exactly the arrangement's engine events for
  every frame of all three tunes, and its vibrato frequency writes match too.
* `bench.py` also checks `chip_init`'s writes from the voice types on (244, including the
  Noise RAM load) against `build.init_writes()`.
* Player cost: 280-440 cycles a frame on average, at most 2,173 (19 scanlines), the worst
  being the first frame (8 instrument events) and frames with vibrato on several voices.
* The noise drums render at the old drums' RMS level (within 0.5 dB), with lower peaks; the
  renderer's noise (`noisegen.py`: the bit-exact generators and the gain measured on the RTL
  chip model) matches the chip model within ~1-4 dB on single hits.
* The previews are the arrangement through the engine model and a Python AMY model, not
  the chip; the model flags no slope that points away from its destination.
