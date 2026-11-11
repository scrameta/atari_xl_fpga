# AMY Rev. C — timed test sequence

Relative to the **first audio onset**. The player has an initial approximately one-second silent lead-in. Every case runs for 0.5 s followed by 0.1 s of silence.

| # | Start (s) | Group | Sound |
|---:|---:|---|---|
| 1 | 0.0 | CORE | Pure sine / reference A440 |
| 2 | 0.6 | CORE | Two harmonics |
| 3 | 1.2 | CORE | Eight harmonics |
| 4 | 1.8 | CORE | Harmonic amplitude attack |
| 5 | 2.4 | CORE | Harmonic amplitude decay |
| 6 | 3.0 | CORE | Frequency glide up |
| 7 | 3.6 | CORE | Frequency glide down |
| 8 | 4.2 | CORE | Original noise generator 0 |
| 9 | 4.8 | CORE | Original noise generator 1 |
| 10 | 5.4 | CORE | 40-harmonic mode |
| 11 | 6.0 | CORE | 64-harmonic mode control |
| 12 | 6.6 | CORE | Global output volume half |
| 13 | 7.2 | CORE | Stereo independent voices |
| 14 | 7.8 | CORE | Tonal plus original noise |
| 15 | 8.4 | CORE | 6502 note engine note-on |
| 16 | 9.0 | EXT | Unlocked, all coefficients zero |
| 17 | 9.6 | EXT | Type 3 locked (legacy control) |
| 18 | 10.2 | EXT | White excitation (type 3) |
| 19 | 10.8 | EXT | Voice attenuation 6 dB |
| 20 | 11.4 | EXT | Voice attenuation 12 dB |
| 21 | 12.0 | EXT | Harmonic detune +24/64 |
| 22 | 12.6 | EXT | Harmonic detune -24/64 |
| 23 | 13.2 | EXT | Phase diffusion 24/63 |
| 24 | 13.8 | EXT | Phase diffusion 63/63 |
| 25 | 14.4 | COMBO | Attenuation + detune |
| 26 | 15.0 | COMBO | Attenuation + diffusion |
| 27 | 15.6 | COMBO | Detune + diffusion |
| 28 | 16.2 | COMBO | White + attenuation |
| 29 | 16.8 | COMBO | White + detune |
| 30 | 17.4 | COMBO | White + diffusion |
| 31 | 18.0 | COMBO | Original noise + attenuation |
| 32 | 18.6 | COMBO | Stereo + detune |
| 33 | 19.2 | COMBO | 40-mode + diffusion |
| 34 | 19.8 | COMBO | 40-mode + detune |
| 35 | 20.4 | COMBO | Attenuation + detune + diffusion |
| 36 | 21.0 | COMBO | White + attenuation + diffusion |
| 37 | 21.6 | COMBO | All four extensions |

**Total:** 37 cases, 22.2 seconds including the final silence, plus approximately one second of pre-roll.

**Verification:** Section order and host 6502 control flow were instruction-emulated against the generated executable, with AMY status reads modelled as immediately ready. Hardware synthesis and audio output have not been exercised by this build.
