# atari_xl_fpga

An FPGA implementation of the Atari 800XL (and, with a swapped memory map, the
Atari 5200). The core is written mostly in VHDL, with a ZPU soft-core handling
drive emulation, on-screen menus and housekeeping. It has been ported to a wide
range of FPGA boards over the years, and grew a companion set of individual
chip replacements (POKEY, GTIA, ANTIC, Sally/6502) — one of which, **PokeyMAX**,
went on to become a product in its own right.

> This repository was migrated from a long-lived SVN history, so some of the
> commit history and layout reflects that heritage.

## Contents

- [What this is](#what-this-is)
- [Repository layout](#repository-layout)
- [The core](#the-core)
- [Supported boards](#supported-boards)
- [Individual chip replacements](#individual-chip-replacements)
- [Firmware](#firmware)
- [Toolchain](#toolchain)
- [Building](#building)
- [Licensing](#licensing)
- [Credits and references](#credits-and-references)

## What this is

The project started as an Atari 800XL built on a Terasic **DE1** (Cyclone II).
Because the Atari 5200 shares most of the 800XL hardware and differs mainly in
its memory map and I/O, a 5200 variant fell out fairly naturally and is
maintained alongside the 800XL builds.

Beyond raw machine emulation, a **ZPU** soft-core was added to provide the
"glue" a real setup needs: SIO disk-drive emulation, menu/UI, timers and
similar. That firmware lives in the `firmware_*` folders.

Over time the core was ported to many different FPGA boards, and separately the
individual custom Atari ICs were reimplemented as standalone RTL so they could
be dropped into real machines.

## Repository layout

Everything lives under `atari_800xl/`.

| Path | Description |
| --- | --- |
| `common/a8core` | The main Atari 800XL/5200 core RTL. |
| `common/components` | Shared, largely Atari-agnostic building blocks used by the core. |
| `common/zpu` | ZPU soft-core plus the extra functionality (drive emulator, timers, menus, etc.). |
| `common/tb`, `common/tb_*` | Testbenches and simulation scripts for the core. |
| `atari_chips/` | Standalone RTL for individual Atari ICs — see [below](#individual-chip-replacements). |
| `atari_chips/hardware/` | Board designs and Gerbers for the chip-replacement hardware. |
| *(one folder per board)* | Per-board top level, pin constraints, PLLs and build scripts — see [below](#supported-boards). |
| `firmware_*` | ZPU firmware (see [Firmware](#firmware)). |
| `COPYRIGHT_NOTICE` | Aggregated copyright notices for the various RTL/firmware pieces. |
| `VERSION` | Core version string. |
| `buildall.sh`, `package.pl`, `makemifall` | Top-level build / packaging helpers. |

## The core

The main core is in `common/a8core`, with reusable pieces factored out into
`common/components`. The design targets cycle-accurate 800XL behaviour and
reuses the same core across every board port — each board folder is essentially
a thin top level (clocking, pin mapping, memory controller, board-specific I/O)
wrapped around the common core.

The 5200 variants (`*_5200`) reuse the same core with the 5200 memory map and
I/O differences.

## Supported boards

Each board has its own top-level folder containing its constraints, PLL/clocking
and build script.

### Actively supported / working

| Board | Folder | Notes |
| --- | --- | --- |
| Terasic DE1 | `de1`, `de1_5200` | The original target (Cyclone II). |
| MCC216 | `mcc216`, `mcc216_5200` | Arcade / retro-gaming board. |
| MCCTV | `mcctv`, `mcctv_5200` | Arcade / retro-gaming board. |
| MIST | `mist`, `mist_5200` | |
| Turbo Chameleon (v1) | `chameleon` | |
| Turbo Chameleon 2 | `chameleon2` | |
| Vampire V4 | `vampire_v4sa_atari800xl` | Pinout worked out independently. |

(`mcc_common` holds shared MCC support code.)

### Experimental / community / incomplete

| Board | Folder | Status |
| --- | --- | --- |
| FPGA Arcade Replay | `replay` | Unfinished — fought the framework and the lack of SignalTap. |
| Terasic SoCKit | `sockit` | Unfinished — DDR3 IP proved troublesome. |
| Aeon Lite | `aeon_lite` | Community-contributed board; experimental. |
| Papilio DUO | `papilioduo` | Experimental. |
| eclaireXL ITX | `eclaireXL_ITX` | |

> **Vampire V4:** the pin assignments here were reverse-engineered / worked out
> independently rather than supplied by the vendor.

## Individual chip replacements

Separately from the full-machine core, `atari_chips/` contains standalone RTL
reimplementations of the individual Atari custom ICs, intended for dropping into
real hardware. `atari_chips/hardware/` holds the associated board designs and
Gerbers, and each chip has simulation scripts and testbenches
(`simulate_*max.sh`, `tb_*max/`).

| Chip | Folder(s) | Status |
| --- | --- | --- |
| **POKEY** (PokeyMAX) | `pokey`, `pokeyv2`, `pokey_digi` | **Works — matured into a full product.** Won the ABBUC hardware competition and is actively developed as PokeyMAX. |
| **GTIA** | `gtia` | Works well; used as the author's main GTIA. Developed and working prior to Sophia. |
| **Sally (6502)** | `sally` | Works, but sees little use; HALT timing is not fully verified. |
| **ANTIC** | `antic` | Incomplete — the DMA timing was never fully nailed down. |

There is also a `digimax` (DigiMAX-style DAC) in the same area.

If you're specifically after PokeyMAX rather than the FPGA computer, that work
has taken on a life of its own — see [64kib.com](https://www.64kib.com/) and the
[ABBUC](https://www.abbuc.de/) community.

## Downstream forks

- **[Atari800_MiSTer](https://github.com/MiSTer-devel/Atari800_MiSTer)** — the
  MiSTer port. It forked this project by copying the SVN repository and has
  broadly kept the core the same, while adding newer features of its own — for
  example VBXE and PokeyMAX support integrated into the full 800XL FPGA core.
  It's actively maintained by the MiSTer community and is a good place to look
  if you want a well-supported, feature-rich build on MiSTer hardware.

## Related work

- **[tonnere](https://github.com/scrameta/tonnere)** — Project Thunder
  (*tonnere* is French for thunder), the successor board to the EclaireXL
  (itself named for lightning), now being renamed **MegaXE**. An Atari XL/XE
  FPGA board carrying this lineage forward.
- **`ultimate_cart`** — Veronica, a separate 65816 upgrade project for the
  800XL (not a board port of this core).

## Firmware

The ZPU firmware provides the drive emulator, menu system and supporting
services:

| Folder | Description |
| --- | --- |
| `firmware_eclairexl` | Firmware for the eclaireXL / newer targets. |
| `firmware_legacy` | Firmware for the older targets. |

The build flow compiles the firmware to a ZPU ROM that is embedded into the
core (`makemif*` / `zpu_rom.*` artefacts you'll see in the board folders).

## Toolchain

Which tool you need depends on the target FPGA:

- **Altera / Intel boards** — Quartus. In general the **latest** Quartus works,
  **except** for the older Cyclone parts, which were dropped from newer
  Quartus. For those use the newest version that still supports the device:
  - **Cyclone II** (e.g. DE1): last supported by **Quartus II 13.0sp1**.
  - **Cyclone III/IV**: last supported by **Quartus II 13.1**.
  - **MAX 10** and Cyclone 10 LP: use a modern Quartus (15.x or later).
- **Xilinx boards** (Papilio DUO, Aeon Lite, FPGA Arcade Replay) — **ISE**
  (project files: `*.prj`, `*.xst`, `*.ucf`, `*.ut`). Exact ISE version isn't
  recorded; a late ISE 14.x release is the usual choice for these Spartan-6-era
  parts.

Simulation uses the testbenches under `common/tb*` and `atari_chips/tb_*`, with
the `simulate_*.sh` scripts. A ZPU toolchain is required to (re)build the
firmware.

## Building

Each board folder contains a `build.sh` (and often a `build.pl`) that drives the
flow for that target. `buildall.sh` at the top level builds across boards, and
`makemifall` / `package.pl` handle ROM/MIF generation and packaging.

> This is a large, long-lived hobby codebase migrated from SVN. Build scripts
> assume the author's environment in places; expect to adjust paths and tool
> versions for your setup.

## Licensing

**Please read this carefully — the licensing here is genuinely mixed and, in
places, unsettled.**

This repository combines RTL and firmware from many sources. The author does
**not** own copyright in all of it, so a single blanket open-source licence
(GPL or otherwise) **cannot** be applied to the whole tree. See the
`COPYRIGHT_NOTICE` file, which aggregates the copyright notices for the various
components — note that it is acknowledged to be **incomplete**.

For the parts authored by the project author, the intent is:

> **Free to use.** If you want to use it commercially, or build significantly on
> it in a commercial product, please get in touch first.

Third-party components (e.g. the ZPU, Chameleon support code — note
`chameleon/lgpl.txt` — and other imported IP) remain under their own respective
licences, which take precedence for those files.

Because some included IP may carry redistribution or build restrictions, no
warranty is made that a complete build is free of such constraints. If you are a
rights-holder for any included component and something here is mislabelled or
shouldn't be present, please contact the author and it will be corrected.

*(This section is a description of intent, not formal legal advice, and is
expected to be tightened up over time.)*

## Credits and references

- **Author:** Mark ("nick foft" on the AtariAge forums) — <https://www.64kib.com/>
- **ABBUC** — <https://www.abbuc.de/> — where PokeyMAX won the hardware competition.
- **Phaeron (Avery Lee)** — for **Altirra** and the superb *Altirra Hardware
  Reference Manual*, an invaluable reference throughout this project:
  <https://virtualdub.org/downloads/Altirra%20Hardware%20Reference%20Manual.pdf>

### Threads and background

- Main announcement / discussion thread — *Potential new hardware*:
  <https://forums.atariage.com/topic/213827-potential-new-hardware/>
- Decap and original schematics (chip reverse-engineering reference):
  <https://forums.atariage.com/topic/223747-decap-and-original-schematics/>
- Atari 8-bit family background (Wikipedia):
  <https://en.wikipedia.org/wiki/Atari_8-bit_computers>
