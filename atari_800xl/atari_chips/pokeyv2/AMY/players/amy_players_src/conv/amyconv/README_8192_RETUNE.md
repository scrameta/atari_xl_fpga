# AMY Rev. C — `amyconv` conversion for 8.192 MHz

The original `amyconv_src.zip` is configured for an effective AMY clock of
7.168 MHz. Its instrument RAM word 40 (the engine's note-0 pitch), assembly
`ftab_lo/ftab_hi` (direct vibrato writes), and software audio preview all
assume that clock. The original prebuilt executable is retained as
`amyconv_OLD_7168.xex` and is **not** tuned for 8.192 MHz.

## What changed

- Default converter clock `clk8192`: effective AMY 8,192,000 Hz.
- Pitch correction relative to the Atari 8 MHz A440 code: **-26** units,
  replacing the old +122 correction. This moves codes by -148 units compared
  with existing `amyconv` data. Each unit is 1/64 of a semitone.
- The 13-bit A440 word is `$1372` (the old 7.168 MHz word was `$1406`).
- Engine RAM word 40 is now `$0132` (the old word was `$01C6`).
- Sample rate with 64 harmonics is 32,000 Hz (previously 28,000 Hz).
- Engine timing unit, assuming `ENGINE_UNIT_LOG2=15`, is exactly 8.000 ms.
- Regenerated clock-dependent envelope slope bytes, instrument release/drop
  bytes, note harmonic-limit table, engine RAM, and software preview settings.
- Retained `mkinst.CLOCKS['clk8']` as a historical option.

## Build new player

The supplied `convdata.inc` **already has the 8.192 MHz values**. Its compressed
song event streams are unchanged byte-for-byte; this is a pitch/envelope and
clock-related table update, not a new musical arrangement.

To reapply just the clock-dependent tables to an existing `convdata.inc`, run:

```bash
python3 retune_convdata.py
python3 verify_clock8192.py
```

Then assemble and link using the **same cc65 project/configuration you used
for the old player**:

```bash
ca65 -g -t atari amyconv.s -o amyconv.o
ld65 -C atari-asm.cfg -o amyconv.xex amyconv.o atari.lib -Ln amyconv.lbl
```

The source archive does *not* include `atari-asm.cfg` or `atari.lib`, and those
plus the cc65 tools are not installed in the test environment here. Therefore
**no new `.xex` has been built**. The historical binary has been renamed `amyconv_OLD_7168.xex`
to prevent accidental testing of the old clock version.

For a full tune regeneration (including new event streams) use the original
SAP/ASMA directory tree and `py65`:

```bash
python3 mkconv.py convdata.inc
```

That step was **not** run here because the referenced ASMA input tree and py65
are not supplied in `amyconv_src.zip`. The existing song streams are deliberately
kept unchanged, while the runtime harmonic-limit table is regenerated.

## Verification status

`verify_clock8192.py` checks the effective clock and 32 kHz sample rate, engine
8 ms unit, A440, note-0 frequency, all 128 pitch table entries, and consistency
between `convdata.inc` and the source instrument definitions. It does not
replace a 6502 runtime test or audio-frequency measurement.

**Confirmed:** the `convdata.inc` portion beginning with `NTUNES = 3` is
identical to the original source archive (330,463 bytes, SHA-256
`f3db9f5ac5607759f3d89baec06d88eb8e0e2c6fa9081e8bc7b223d72da79100`).

Recommended after reassembling: measure an A440 test tone (~440 Hz), check
Warhawk/Draconus/Zybex timing and drum timbre, and re-run the `bench.py` tests
in your full local development environment.
