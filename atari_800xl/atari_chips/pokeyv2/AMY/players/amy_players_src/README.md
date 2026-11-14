# AMY copper players: source

The latest source of the three PokeyMAX AMY players that run on the copper (copper v0.7.1, copper++),
with the generator and checking tools they build with. Each player's XEX is included, built from
exactly this source.

| Directory | What | Build |
|---|---|---|
| `players/amy_drums` | the drum machine | `make` (`make check`: copper vs engine version; `make test`: sim65 vs host) |
| `players/amybox` | AMY Music Box | `make` (`make check`) |
| `conv/amyconv` | the POKEY/MOD conversions, four sets | `./build.sh`; `python3 copbench.py N [secs]` checks set N |
| `players/common/cop.h` | the C copper driver (held event, combined entries) | |
| `copper` | `amycop.py` (the copper note engine), `copgen.py` (image, XEX loader segment, `.h`/`.inc`), `copper.py` (the copper model and assembler), `copsim.py` (replays a player log through the copper and AMY models, against the engine version), `tools/` (the engine and AMY models) | |
| `conv/asma` | the eight SAP files the conversion sets need, from ASMA | |

Needs cc65 on PATH (`CC65_HOME` for amyconv's ld65 config), Python 3 with py65 and numpy, and a C
compiler for the drums' and amybox's host builds. The paths are relative, so build in place.

amyconv here is the 10 November converter (Warhawk's note extraction, SWELL, the MOD improvements,
instrument selects after the loop) with the copper player: event merging, the variables cleared at
start, copper detection. Every tune of all four sets is bit-identical to the engine version in the
models, Rev C on and off. The preview MP3s are left out; they are unchanged.
