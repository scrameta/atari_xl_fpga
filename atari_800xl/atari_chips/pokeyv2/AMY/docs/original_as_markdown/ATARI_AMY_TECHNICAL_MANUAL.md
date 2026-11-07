# ATARI AMY — Technical Manual (earlier edition)

> **Working Markdown transcription of Atari’s 55-page Technical Manual**, based on the supplied scanned PDF. This is an **earlier document than the AMY 1 Rev. B specification**, not a corrected or merged copy. It retains its different pin assignments, clock and reset limits, and noise descriptions. The text has been editorially reconstructed against matched sections of the later document and the original scans, so it is not yet a page-perfect critical transcription.
>
> Source: [`AMY_tech_manual.pdf`](AMY_tech_manual.pdf). All page headings below refer to **physical PDF pages** (the source does not use the same later Rev. B binder pagination). Original figure crops are supplied alongside Mermaid redrawings. Appendix I Tables A/B/C now include complete numerical transcriptions using the Technical Manual’s original decimal encoding; source scans remain alongside for comparison.

## Contents

| Section | Subject |
|---|---|
| 1–5 | General description, features, block diagram, pins |
| 6.1 | Musical specifications |
| 6.2–6.4.2 | Internal architecture, system and envelopes |
| 7.1–7.5.9 | Registers and command set |
| 8.1–8.3 | Operating procedure, initialization, timing |
| 9–12 | Maximum ratings and electrical/timing specifications |
| Appendix I | Tables A (semitones), B (tone increments) and C (slopes) |

**Editorial note on page order:** physical PDF page 19 contains §8.1 (reset) before §7.4 resumes on PDF page 20. The following transcription preserves the original *scanned page order* and notes where the subject sequence jumps.

---

<!-- Technical Manual original PDF page 01/55 -->

<sub>Original PDF page 1 · [View source](AMY_tech_manual.pdf#page=1)</sub>

## Table of contents

1. General description
2. Features
3. Block diagram
4. Pin assignment
5. Pin description
6. Functional description
   - 6.1 Musical specifications
   - 6.2 Internal architecture
   - 6.3 Complete AMY system
   - 6.4 Envelope generation (6.4.1 Slope format; 6.4.2 Destination format)
7. Register organization
   - 7.1 Command set; 7.2 RAM/register areas; 7.3 Data registers; 7.4 Other registers
   - 7.5 Command descriptions (7.5.1 to 7.5.9)
8. Operating procedure (8.1 Initialization, 8.2 Flowchart, 8.3 Summary)
9. Maximum ratings
10. Capacitances
11. DC characteristics
12. AC characteristics (clock and reset, output section, system bus interface)

Appendix I: tables A, B and C.


---


<!-- Technical Manual original PDF page 02/55 -->

<sub>Original PDF page 2 · [View source](AMY_tech_manual.pdf#page=2)</sub>

## Table of illustrations

| Figure | Title | PDF page |
|---:|---|---:|
| 1 | Simplified block diagram | 7 |
| 2 | HRAM and VRAM data word format | 8 |
| 3 | Complete AMY system | 10 |
| 4 | Piecewise linear envelope | 11 |
| 5 | Linear function of harmonic amplitude destination | 14 |
| 6 | Fundamental frequency vs. destination | 15 |
| 7 | AMY RAM and register areas | 17 |
| 8 | RESET with standard µP system reset circuit | 19 |
| 9 | RESET with RC | 19 |
| 10 | INT/RDY pin timing | 36 |


---


<!-- Technical Manual original PDF page 03/55 -->

<sub>Original PDF page 3 · [View source](AMY_tech_manual.pdf#page=3)</sub>

## 1. General description

AMY 1 is a digital, pipeline-architectured additive music synthesizer chip. Eight voices may share a total of 64 harmonic oscillators, assignable in groups of two. There are 72 piecewise-linear envelope generators: eight for fundamental frequency and 64 for harmonic amplitude. A complete sound system adds a D/A converter (up to 16 bits) and generally a controlling microprocessor such as the Intel 8051.

## 2. Features

| Design | Interface and audio |
|---|---|
| Single 40-pin DIP | Interrupt/Ready pin |
| 3 µm NMOS technology | Multiplexed and nonmultiplexed bus interfaces |
| Pipeline architecture | Full 16-bit digital output width |
| **3–5 MHz external clock** (this earlier manual) | Independent voice mode |
| Integrated exponential ROM | Adjustable sample rate |
| 1/128 dB amplitude and 1/64 semitone frequency resolution | Programmable noise statistics |
| 72 on-chip envelope generators | Approximately 37,000 transistors |

## 3. Block diagram

```mermaid
flowchart LR
  CPU[Processor interface / interrupt logic] <--> FG[Frequency and amplitude generation]
  NG[Noise generator] --> FG
  FG --> PH[Phase generation]
  PH --> SIN[Sine argument formation]
  SIN --> ACC[Sample formation / accumulator]
  ACC --> OUT[16-bit digital output]
```

## 4. Pin assignment — **original Technical Manual pinout**

| Pin | Signal | Pin | Signal |
|---:|---|---:|---|
| 1 | RESET | 40 | VCC |
| 2 | RD | 39 | V0 |
| 3 | WR | 38 | OUTSTB |
| 4 | CS | 37 | OE |
| 5 | DB7 | 36 | SAMP15 |
| 6 | DB6 | 35 | SAMP14 |
| 7 | DB5 | 34 | SAMP13 |
| 8 | DB4 | 33 | SAMP12 |
| 9 | DB3 | 32 | SAMP11 |
| 10 | DB2 | 31 | SAMP10 |
| 11 | DB1 | 30 | SAMP9 |
| 12 | DB0 | 29 | SAMP8 |
| 13 | ALE | 28 | SAMP7 |
| 14 | CLK | 27 | SAMP6 |
| 15 | INT/RDY | 26 | SAMP5 |
| 16 | A1 | 25 | SAMP4 |
| 17 | A0 | 24 | SAMP3 |
| 18 | RESERVED | 23 | SAMP2 |
| 19 | RESERVED | 22 | SAMP1 |
| 20 | GND | 21 | SAMP0 |

*Do not substitute the Rev. B pinout here: for example, RESET moved to pin 18 in the later specification.*


<details><summary>Original Atari diagram / timing scan — PDF page 3</summary>

![Source scan detail, Technical Manual page 3](assets/tech_p03.png)

</details>

---


<!-- Technical Manual original PDF page 04/55 -->

<sub>Original PDF page 4 · [View source](AMY_tech_manual.pdf#page=4)</sub>

## 5. Pin description (part 1)

| Signal | Type | Pin(s) | Function |
|---|---|---|---|
| VCC | I | 40 | +5 V supply, ±5% |
| GND | I | 20 | Ground |
| RESET | I | 1 | Active-low asynchronous reset: clears system options, control, sequencer, phase RAM and digital output word |
| A1–A0 | I | 16–17 | Address pins to select AMY registers when ALE is not used; tie to GND for ALE mode |
| RD | I | 2 | Active-low read strobe; requires CS low |
| WR | I | 3 | Active-low write strobe; requires CS low |
| CS | I | 4 | Active-low chip select; enables RD/WR; otherwise data bus is tri-stated |
| CLK | I | 14 | External 3–5 MHz clock (earlier manual) |
| DB7–DB0 | I/O | 5–12 | Eight-bit bidirectional, tri-state data/command bus |
| SAMP15–SAMP0 | O | 36–21 | 16-bit digital audio bus to external D/A converter |
| OUTSTB | O | 38 | Active-low output strobe indicating valid SAMP bus data |


---


<!-- Technical Manual original PDF page 05/55 -->

<sub>Original PDF page 5 · [View source](AMY_tech_manual.pdf#page=5)</sub>

## 5. Pin description (continued)

| Signal | Type | Pin(s) | Function |
|---|---|---|---|
| INT/RDY | I (as printed) | 15 | Interrupt/Ready: high when idle in READY mode; one-clock pulse on command completion in INTERRUPT mode |
| ALE | I | 13 | Address-latch enable; uses DB0 and DB1 for address, with A0/A1 grounded |
| V0 | O | 39 | Voice-zero marker for individual-voice output mode |
| OE | I | 37 | Active-low output enable for the SAMP data bus |
| RESERVED | — | 18, 19 | Undefined; not general-purpose pins |

*The earlier document labels INT/RDY input in its pin-description type column even though its function describes an output. This apparent inconsistency is preserved for source fidelity.*


---


<!-- Technical Manual original PDF page 06/55 -->

<sub>Original PDF page 6 · [View source](AMY_tech_manual.pdf#page=6)</sub>

## 6. Functional description

### 6.1 Musical specifications

Atari gives these values for a **4 MHz external CLK** with **64 harmonics enabled**.

| Characteristic | Published value |
|---|---|
| Amplitude dynamic range | 63.75 dB |
| Minimum harmonic amplitude slope | 1.91 dB/s |
| Maximum harmonic amplitude slope | 3784 dB/s |
| Fundamental frequency range | Approx. 4.8 Hz–7.8 kHz (10⅔ octaves) |
| Minimum fundamental frequency slope | 5.97 cents/s |
| Maximum fundamental frequency slope | 118 semitones/s (9.85 octaves/s) |
| Maximum amplitude increment | 31/128 = 0.242 dB |
| Maximum fundamental frequency increment | 31/2048 = 1.51 cents |
| Harmonics | Maximum 64 |
| Voices | Maximum 8 |
| Harmonics per voice | Any multiple of 2 |
| Harmonic distortion | Less than 1% |

*One cent is 1/100 semitone. This musical-specification section appears at §6.1 in the Technical Manual, but at Appendix II in Rev. B.*


---


<!-- Technical Manual original PDF page 07/55 -->

<sub>Original PDF page 7 · [View source](AMY_tech_manual.pdf#page=7)</sub>

## 6. FUNCTIONAL DESCRIPTION

### 6.2 Internal Architecture

AMY 1 consists of 8 major blocks as shown in Figure 1 below.

```mermaid
flowchart LR
    CPU[uP interface] <--> BUS[System bus interface]
    BUS <--> ENV[Envelope generators]
    NG[Noise generator] --> ENV
    ENV --> EXP[Exponential ROM]
    EXP -->|F, DISP| PH[Phase generation and argument formation]
    PH --> SIN[SIN ROM]
    SIN --> ACC[Output accumulator]
    ACC --> OUT[16-bit digital output]
    BUS --> SEQ[Sequencer]
    SEQ --> CTRL[Control bus]
```

**Figure 1. Simplified block diagram** — re-created from the PDF.

The System Bus Interface block provides the user with a standard microprocessor interface. The user sends all commands and passes frequency and amplitude breakpoint data and current values over the "µP Interface" lines (RESET, RD, WR, CS, DB0–DB7, ALE, INT/RDY, A1, A0).

The Noise Generator block contains a small RAM, a serial adder, and some associated logic. It generates two different channels of bandlimited white noise simultaneously. Bandwidths are programmable by initialization of the Noise RAM.

<details><summary>Original Atari diagram / timing scan — PDF page 7</summary>

![Source scan detail, Technical Manual page 7](assets/tech_p07.png)

</details>

---


<!-- Technical Manual original PDF page 08/55 -->

<sub>Original PDF page 8 · [View source](AMY_tech_manual.pdf#page=8)</sub>

*Internal Architecture (continued)*

The Envelope Generator block contains the Voice RAM (VRAM), Harmonic RAM (HRAM), and logic necessary to generate the 72 piecewise linear envelopes (8 fundamental frequency envelopes and 64 harmonic amplitude envelopes). The RAMs maintain a slope value, destination value and current value for each envelope. The Voice RAM additionally stores a 2-bit voice type selector. The total Envelope Generator RAM is (64 × 30) + (21 × 16) bits = 282 bytes.

**Figure 2. HRAM and VRAM data word formats**


```mermaid
flowchart TB
  subgraph HRAM[HRAM word fields]
    HC[13-bit harmonic amplitude current] --- HD[8-bit destination] --- HS[8-bit slope]
  end
  subgraph VRAM[VRAM word fields]
    VF[13-bit fundamental-frequency destination] --- VS[8-bit slope]
    VC[18-bit fundamental-frequency current] --- VT[2-bit voice type] --- SP[1-bit spare]
  end
```

*Conceptual field-level Mermaid diagram; the scanned Figure 2 preserves the original bit positions.*

| Memory | Field | Bits |
|---|---|---:|
| HRAM | Harmonic amplitude current value | 13 |
| HRAM | Harmonic amplitude destination | 8 |
| HRAM | Harmonic amplitude slope | 8 |
| VRAM (word 1) | Fundamental frequency destination | 13 |
| VRAM (word 1) | Fundamental frequency slope | 8 |
| VRAM (word 2) | Fundamental frequency current value | 18 |
| VRAM (word 2) | Voice type select | 2 |
| VRAM (word 2) | Spare | 1 |

*Field widths read from the original PDF. The diagram shows logical fields rather than an exact contiguous software bus layout.*

<details><summary>Original Atari diagram / timing scan — PDF page 8</summary>

![Source scan detail, Technical Manual page 8](assets/tech_p08.png)

</details>

---


<!-- Technical Manual original PDF page 09/55 -->

<sub>Original PDF page 9 · [View source](AMY_tech_manual.pdf#page=9)</sub>

*Internal architecture (continued)*

The envelope generator contains 32 Last Harmonic Pair Flags, adders and sequencer-controlled logic for updating the envelopes from breakpoints in HRAM and VRAM. Its noise adder is used for noise-based voices.

The exponential ROM converts outputs from the 72 envelope generators into piecewise exponential form for use internally. This allows the programmer to specify harmonic amplitude in decibels and fundamental frequency in semitones. It also makes master-amplitude scaling and transposition simple addition operations in the controlling processor.

The sequencer controls the other functional blocks. It contains a seven-bit clock-period counter and a seven-bit subsample counter.


---

<!-- Technical Manual original PDF page 10/55 -->

<sub>Original PDF page 10 · [View source](AMY_tech_manual.pdf#page=10)</sub>

### 6.3 Complete AMY System

A complete sound system requires the addition of a D/A converter chip (up to 16 bit). To provide higher-level commands, the system will generally include a controlling processor such as the Intel 8051 single-chip microcomputer.

```mermaid
flowchart LR
   IN[Keyboard or other controller] --> MC[8051 microcomputer]
   MC <--> AMY[AMY 1]
   AMY --> DAC[16-bit D/A converter]
   DAC --> AUDIO[Audio output — unfiltered]
```

**Figure 3. Complete AMY system** — re-created from the PDF.

<details><summary>Original Atari diagram / timing scan — PDF page 10</summary>

![Source scan detail, Technical Manual page 10](assets/tech_p10.png)

</details>

---


<!-- Technical Manual original PDF page 11/55 -->

<sub>Original PDF page 11 · [View source](AMY_tech_manual.pdf#page=11)</sub>

### 6.4 Envelope Generation

Envelopes are generated by the on-chip AMY 1 envelope generator block. The user may command the generators to make a piecewise linear envelope using a slope and destination scheme. Assume that a particular envelope has previously been loaded immediate to zero. By loading two breakpoints (slope–destination pairs), we obtain the following envelope:

```mermaid
---
config:
  themeVariables:
    xyChart:
      plotColorPalette: "#1658B9, #0C728A, #B34428"
      xAxisLineColor: "#334155"
      yAxisLineColor: "#334155"
      xAxisLabelColor: "#1E293B"
      yAxisLabelColor: "#1E293B"
---
xychart-beta
  title "Piecewise-linear envelope (schematic)"
  x-axis "Time" [0, 1, 2, 3, 4, 5]
  y-axis "Envelope value" 0 --> 10
  line [0, 0, 10, 10, 10, 0]
```

**Figure 4. Piecewise linear envelope**. Point A is the first breakpoint, B the first destination/free point, C the second breakpoint, and D the second free point. This Mermaid graph preserves the *shape*, not the source's exact annotated coordinates.

At point A, BP1 is loaded and the envelope starts rising at the constant slope defined by BP1. At B, the destination is reached and the slope effectively becomes zero (a "free point"). At C, a negative-slope breakpoint with zero destination is loaded. At D, zero is reached, becoming another free point.

<details><summary>Original Atari diagram / timing scan — PDF page 11</summary>

![Source scan detail, Technical Manual page 11](assets/tech_p11.png)

</details>

---


<!-- Technical Manual original PDF page 12/55 -->

<sub>Original PDF page 12 · [View source](AMY_tech_manual.pdf#page=12)</sub>

*Slope format (continued)*

For smooth pitch and amplitude modulation, AMY's individual integration steps are deliberately small: the effective pitch step is **1/2048 of a semitone** (0.0488 cents, around 0.0028% in frequency) and the amplitude step is **1/128 dB**. Both give perceptually continuous modulation at the specified envelope rates.

| Limit | Source specification |
|---|---|
| Maximum effective harmonic amplitude increment | 31/128 dB per update |
| Maximum effective frequency increment | 31/2048 semitone per update |
| Fundamental frequency destination increment | 1/64 semitone |

Atari gives a maximum-to-minimum nonzero slope ratio of approximately **1,984**. It combines this with the 64 dB amplitude range or the 10⅔-octave frequency range to illustrate very large overall amplitude and frequency slew-rate ranges:

\[
R_{amplitude} pprox 1984 	imes 10^{64/20} pprox 3.1 	imes 10^6:1
\]
\[
R_{frequency} pprox 1984 	imes 2^{10+2/3} pprox 3.2 	imes 10^6:1.
\]

*The original uses rounded constants and scientific notation. These equations express the stated calculation in readable form; refer to the scan if exact historical notation is important.*


---

<!-- Technical Manual original PDF page 13/55 -->

<sub>Original PDF page 13 · [View source](AMY_tech_manual.pdf#page=13)</sub>

#### 6.4.1 Slope Format

The eight-bit slope uses a sign bit, a two-bit exponent, and a signed five-bit mantissa (two's-complement form). It provides envelope rates from nearly instantaneous to very gradual.

| Bit 7 | Bits 6–5 | Bits 4–0 |
|---|---|---|
| Sign | Exponent / subsample rate | Five-bit signed mantissa |

| Exponent | Addition interval |
|---|---|
| `00` | Every 128 sample periods |
| `01` | Every 32 sample periods |
| `10` | Every 8 sample periods |
| `11` | Every 2 sample periods |

**Table 1. Slope examples**

| Sign | Exponent | Mantissa bits | Relative slope (steps/sample) |
|:--:|:--:|:--:|---|
| 0 | 00 | `00001` | +1/128 ≈ 0.0078 |
| 1 | 00 | `11111` | −1/128 ≈ −0.0078 |
| 0 | 01 | `00011` | +3/32 ≈ 0.094 |
| 0 | 11 | `11111` | +31/2 = 15.5 |
| 1 | 10 | `00100` | −28/8 = −3.5 |
| 1 | 11 | `00001` | −31/2 = −15.5 |

The ratio between maximum and minimum nonzero slope magnitudes is approximately 1984 (15.5 / 0.0078125). Values are from original page 13, with source sign conventions.

---


<!-- Technical Manual original PDF page 14/55 -->

<sub>Original PDF page 14 · [View source](AMY_tech_manual.pdf#page=14)</sub>

#### 6.4.2 Destination Format

Since all harmonic amplitudes have a 64 dB dynamic range, a single eight-bit destination byte is used per harmonic. The resolution is 64/256 = ¼ dB.

| Destination (8 bits) | Harmonic amplitude |
|---:|---|
| `0x00` | Zero amplitude |
| `0x01` | Minimum nonzero setting (0.25 dB) |
| `0xFF` | Full scale (63.75 dB) |

```mermaid
---
config:
  themeVariables:
    xyChart:
      plotColorPalette: "#1658B9, #0C728A, #B34428"
      xAxisLineColor: "#334155"
      yAxisLineColor: "#334155"
      xAxisLabelColor: "#1E293B"
      yAxisLabelColor: "#1E293B"
---
xychart-beta
  title "Harmonic amplitude vs destination"
  x-axis "Destination code" [0, 1, 64, 128, 192, 255]
  y-axis "Amplitude (dB)" 0 --> 64
  line [0, 0.25, 16, 32, 48, 63.75]
```

**Figure 5. Harmonic amplitude destination**. Note that Atari's text uses *dB* as a positive magnitude. Graph is representative.

<details><summary>Original Atari diagram / timing scan — PDF page 14</summary>

![Source scan detail, Technical Manual page 14](assets/tech_p14.png)

</details>

---


<!-- Technical Manual original PDF page 15/55 -->

<sub>Original PDF page 15 · [View source](AMY_tech_manual.pdf#page=15)</sub>

*Destination Format (continued)*

Each fundamental-frequency envelope has a 128-semitone range with destination resolution 1/64 semitone, represented in 13 bits.

| Fundamental-frequency destination field | Width |
|---|---:|
| Semitone field | 7 bits |
| Atari tone field | 6 bits |

```mermaid
---
config:
  themeVariables:
    xyChart:
      plotColorPalette: "#1658B9, #0C728A, #B34428"
      xAxisLineColor: "#334155"
      yAxisLineColor: "#334155"
      xAxisLabelColor: "#1E293B"
      yAxisLabelColor: "#1E293B"
---
xychart-beta
  title "Fundamental frequency (semitones) vs destination"
  x-axis "13-bit destination" [0, 2048, 4096, 6144, 8191]
  y-axis "Semitones" 0 --> 128
  line [0, 32, 64, 96, 127.984375]
```

**Figure 6. Fundamental frequency vs destination**. A linear semitone scale; actual Hz is exponential. The original figure uses a broken horizontal axis.

The destination 0 yields a nonzero frequency. The effective Hz resolution is approximately 0.002 Hz per Atari tone near 0 and approximately 7 Hz per tone near 8191. Complete slope tables for a 4 MHz internal clock with 64 harmonics appear in Appendix I.

1 Atari tone = 1/64 semitone.

<details><summary>Original Atari diagram / timing scan — PDF page 15</summary>

![Source scan detail, Technical Manual page 15](assets/tech_p15.png)

</details>

---


<!-- Technical Manual original PDF page 16/55 -->

<sub>Original PDF page 16 · [View source](AMY_tech_manual.pdf#page=16)</sub>

## 7. REGISTER ORGANIZATION

### 7.1 AMY 1 Command Set

Commands are sent by selecting the command register (CS = A1 = A0 = 0, RD = 1, WR active low). Each command contains an opcode and operands, as in Table 2.

**Table 2. AMY 1 commands** (bit patterns cross-checked with the source scan)

| DB7..DB0 pattern | Command |
|---|---|
| `00001 V2 V1 V0` | Write fundamental frequency breakpoint |
| `00010 V2 V1 V0` | Write voice type |
| `00011 V2 V1 V0` | Read current fundamental frequency |
| `0010 SO3 SO2 SO1 SO0` | Write system options register |
| `0011 xx SC1 SC0` | Write system control register |
| `01 H5 H4 H3 H2 H1 H0` | Write harmonic amplitude breakpoint |
| `10 HP4 HP3 HP2 HP1 HP0 D0` | Write last harmonic pair flag (SC1=0) |
| `10 N5 N4 N3 N2 N1 N0` | Write noise RAM (SC1=1) |
| `11 H5 H4 H3 H2 H1 H0` | Read current harmonic amplitude |

*The two `10` formats are selected by the System Control register. Symbols represent individual bits; spaces are for readability.*

---


<!-- Technical Manual original PDF page 17/55 -->

<sub>Original PDF page 17 · [View source](AMY_tech_manual.pdf#page=17)</sub>

### 7.2 RAM and Register Areas

The original AMY interface provides four addressable registers: A (8 bits), B (5 bits), C (8 bits), and the command register. For a write command, load A/B/C as appropriate and then issue a command. For a read, issue the command first, then read the data register. A read of the command register exposes internal bus data for diagnostics.

```mermaid
flowchart LR
    DB[DB0–7] <--> IN[Input buffer]
    DB <--> OUT[Output buffer]
    IN --> A[Reg A]
    IN --> B[Reg B]
    IN --> C[Reg C]
    IN --> CMD[Command register]
    C --> HRAM[Harmonic RAM]
    B --> VRAM[Voice RAM]
    C --> VRAM
    IN --> NRAM[Noise RAM]
    CMD --> SOR[System options register]
    CMD --> SCR[System control register]
    CMD --> LHPR[Last harmonic pair flags]
    B --> OUT
```

**Figure 7. AMY RAM and register areas** — functional recreation. Not a cycle-accurate wiring drawing.

<details><summary>Original Atari diagram / timing scan — PDF page 17</summary>

![Source scan detail, Technical Manual page 17](assets/tech_p17.png)

</details>

---


<!-- Technical Manual original PDF page 18/55 -->

<sub>Original PDF page 18 · [View source](AMY_tech_manual.pdf#page=18)</sub>

### 7.3 AMY 1 Data Registers

There are three data registers for transferring values between the processor and AMY internal RAM/register areas. A, B and C are accessible through the external register select signals. The user normally loads these before a write command and reads them after a read command.

**Table 3. Register selection**

| CS | A1 | A0 | Selected register |
|---:|---:|---:|---|
| 0 | 0 | 0 | Command (write only) |
| 0 | 0 | 1 | Register A (read/write) |
| 0 | 1 | 0 | Register B (read/write) |
| 0 | 1 | 1 | Register C (read/write) |
| 1 | X | X | None |

---


<!-- Technical Manual original PDF page 19/55 -->

<sub>Original PDF page 19 · [View source](AMY_tech_manual.pdf#page=19)</sub>

## 8. Operating procedure (bound out of sequence)

### 8.1 Initialization

#### 8.1.1 RESET pin and power-up sequence

The manual instructs that the RESET pin be held low during power-up and released only after power and clock have met their requirements, with the supply stable for at least 2 ms. The RESET pulse must meet the original (two-clock) minimum in §12.1. Figures 8 and 9 provide a standard microprocessor reset circuit and an RC reset option.

**Figure 8. RESET with standard microprocessor-system reset circuit**

```mermaid
flowchart LR
  RST[Reset source] --> AMY[AMY 1: RESET, pin 1]
  RST --> CPU[Controlling microprocessor]
  CLK[3–5 MHz external CLK] --> AMY
  POWER[+5 V supply] --> AMY
```

**Figure 9. RESET with RC**

```mermaid
flowchart TB
  VCC[VCC] --> R[Pull-up resistor R]
  R --> NODE[RESET node, AMY pin 1]
  NODE --> C[Capacitor C]
  C --> GND[GND]
  NODE --> AMY[AMY 1]
```

*Mermaid captures the functional connectivity only; for component values, reset timing and waveform limits consult the source figure.*


<details><summary>Original Atari diagram / timing scan — PDF page 19</summary>

![Source scan detail, Technical Manual page 19](assets/tech_p19.png)

</details>

---


<!-- Technical Manual original PDF page 20/55 -->

<sub>Original PDF page 20 · [View source](AMY_tech_manual.pdf#page=20)</sub>

### 7.4. Other User Accessible Registers and RAM Areas

AMY 1 also contains other internal registers which are loaded by sending various commands to the AMY 1 Command register. These registers are the System Options register, the System Control register, and the Last Harmonic Pair register (see Sections 7.5.5, 7.5.6, and 7.5.8, respectively).

Other AMY 1 commands pass data to or from AMY 1 RAM areas. These RAM areas include the Voice RAM, the Harmonic RAM, and the Noise RAM. The VRAM contains the current fundamental frequency, fundamental frequency breakpoint, and the voice type. The HRAM contains the current harmonic amplitude and the harmonic amplitude breakpoint. Initial conditions of the NRAM may be loaded to obtain specific bandlimited white noise statistics.

In general, all registers are loaded directly with a single one byte write operation (even the SOR, SCR, and LHPR are loaded from operand data in the command byte). Alternately, RAM areas are read/written indirectly by using Reg A, B, and C as data buffers.

---


<!-- Technical Manual original PDF page 21/55 -->

<sub>Original PDF page 21 · [View source](AMY_tech_manual.pdf#page=21)</sub>

### 7.5. Command descriptions

#### 7.5.1 Write Fundamental Frequency Breakpoint (WR FFBP)

**Command byte:** `00001 V2 V1 V0` — select one of eight voices. To write a frequency breakpoint, load A, B and C, then issue the command byte.

| Data register | Bit positions | Meaning |
|---|---|---|
| A | A7:A0 | Eight-bit signed/exponent envelope slope |
| B | B4:B0 | Five most-significant bits of 13-bit frequency destination; B7:B5 ignored |
| C | C7:C0 | Eight least-significant bits of frequency destination |

```mermaid
flowchart LR
  A[Reg A: 8-bit slope] --> CMD[WR FFBP: voice index V2..V0]
  B[Reg B: destination bits 12..8] --> CMD
  C[Reg C: destination bits 7..0] --> CMD
  CMD --> VRAM[Selected voice RAM: new frequency breakpoint]
```

If the slope byte is **zero** when the command is issued, the destination is loaded immediately into the voice's current fundamental-frequency value, rather than starting a ramp. It stays there until another FFBP is written. This is behavior described by Atari, regardless of differences in unfinished silicon/netlist versions.


---


<details><summary>Original Atari command/register-layout scan — PDF page 21</summary>

![Original command/register drawing, page 21](assets/tech_p21.png)

</details>

<!-- Technical Manual original PDF page 22/55 -->

<sub>Original PDF page 22 · [View source](AMY_tech_manual.pdf#page=22)</sub>

*Write fundamental frequency breakpoint (continued)*

Slope byte loaded in **register A**:

| A7 | A6–A5 | A4–A0 |
|---|---|---|
| Sign | Exponent | Mantissa |

At the finest subsample rate, the fundamental frequency step magnitude ranges from 1/2048 to 31/2048 semitone per update. The original document describes the signed-mantissa layout in detail.

| A6:A5 | Increment interval |
|:--:|---|
| `00` | Once per 128 sample periods |
| `01` | Once per 32 sample periods |
| `10` | Once per 8 sample periods |
| `11` | Once per 2 sample periods |

Destination uses 13 bits in registers B (five most-significant bits) and C (eight least-significant bits), covering a nominal 128-semitone range at 1/64-semitone resolution. The original text says 8196 values; note that 13 bits encode 8192 combinations, so this is likely a typographical error and is **not silently corrected here**.

---


<!-- Technical Manual original PDF page 23/55 -->

<sub>Original PDF page 23 · [View source](AMY_tech_manual.pdf#page=23)</sub>

#### 7.5.2 Write Harmonic Amplitude Breakpoint Command (WR HABP)

**Command byte:** `01 H5 H4 H3 H2 H1 H0`.

The six-bit harmonic index selects an HRAM entry. Load **register A = 8-bit slope**, **register C = 8-bit destination**; B is unused.

| Register | Bits | Meaning |
|---|---|---|
| A | 7–0 | Harmonic amplitude envelope slope |
| C | 7–0 | Harmonic amplitude destination |

If register A is zero, the destination is loaded immediately into the harmonic-amplitude current-value field. The original specification recommends using this to clear amplitudes before enabling SEQRUN.

---



<details><summary>Original Atari command/register-layout scan — PDF page 23</summary>

![Original command/register drawing, page 23](assets/tech_p23.png)

</details>

<!-- Technical Manual original PDF page 24/55 -->

<sub>Original PDF page 24 · [View source](AMY_tech_manual.pdf#page=24)</sub>

*Write harmonic amplitude breakpoint (continued)*

| Register A | Fields |
|---|---|
| A7 | Sign |
| A6:A5 | Two-bit rate exponent |
| A4:A0 | Five-bit signed mantissa |

In amplitude units, the step size is 1/128 to 31/128 dB in magnitude. The all-zero byte gives zero slope; the signed negative-zero encoding is not permitted.

| A6:A5 | Increment interval |
|:--:|---|
| `00` | Once per 128 sample periods |
| `01` | Once per 32 sample periods |
| `10` | Once per 8 sample periods |
| `11` | Once per 2 sample periods |

The eight-bit destination spans 256 codes across a 64 dB range in increments of ¼ dB.

---


<!-- Technical Manual original PDF page 25/55 -->

<sub>Original PDF page 25 · [View source](AMY_tech_manual.pdf#page=25)</sub>

#### 7.5.3 Read Fundamental Frequency Current Value (RD FFCV)

**Command byte:** `00011 V2 V1 V0`. The three low bits select one of the eight voices. The sequencer reads the fundamental-frequency current value from VRAM and loads its 13-bit representation into registers B and C for the host to read.

| Data register | Contents after command |
|---|---|
| B4:B0 | Five most-significant bits of the current frequency value |
| B7:B5 | Don't care |
| C7:C0 | Eight least-significant bits |
| A | Not used by this command |

```mermaid
flowchart LR
  CMD[RD FFCV: voice V2..V0] --> VRAM[Current fundamental frequency: voice RAM]
  VRAM --> B[Reg B bits 4..0: high five bits]
  VRAM --> C[Reg C: low eight bits]
  B --> CPU[Host reads B and C]
  C --> CPU
```


---


<details><summary>Original Atari command/register-layout scan — PDF page 25</summary>

![Original command/register drawing, page 25](assets/tech_p25.png)

</details>

<!-- Technical Manual original PDF page 26/55 -->

<sub>Original PDF page 26 · [View source](AMY_tech_manual.pdf#page=26)</sub>

#### 7.5.4 Read Harmonic Amplitude Current Value (RD HACV)

**Command byte:** `11 H5 H4 H3 H2 H1 H0`. The six-bit operand addresses one of the 64 harmonic envelopes. The sequencer reads the harmonic's current amplitude and makes it available in **register C**, bits 7–0. Register A is unused; the command also changes register B internally, even though the user does not need B for this read.

```mermaid
flowchart LR
  CMD[RD HACV: harmonic H5..H0] --> HRAM[Current harmonic amplitude]
  HRAM --> C[Reg C bits 7..0]
  C --> CPU[Host reads C]
```


---


<details><summary>Original Atari command/register-layout scan — PDF page 26</summary>

![Original command/register drawing, page 26](assets/tech_p26.png)

</details>

<!-- Technical Manual original PDF page 27/55 -->

<sub>Original PDF page 27 · [View source](AMY_tech_manual.pdf#page=27)</sub>

#### 7.5.5 Write System Options Register (WR SOR)

**Command byte:** `0010 SO3 SO2 SO1 SO0`. The four option bits are supplied directly in the command; A/B/C unused. All bits reset low.

**Table 4. System Options Register Selection**

| SO3 | SO2 | SO1 | SO0 | AMY mode |
|:--:|:--:|:--:|:--:|---|
| X | X | X | 0 | Address pin mode |
| X | X | X | 1 | ALE mode |
| X | X | 0 | X | READY mode |
| X | X | 1 | X | INTERRUPT mode |
| X | 0 | X | X | SUM mode |
| X | 1 | X | X | INDIVIDUAL mode |
| 0 | X | X | X | 64 harmonics |
| 1 | X | X | X | 40 harmonics |
| 0 | 0 | 0 | 0 | Reset default (address, ready, sum, 64 harmonics) |

ALE mode uses the DB0/DB1 address field during the ALE strobe. Address-pin mode uses A1 and A0.

---


<!-- Technical Manual original PDF page 28/55 -->

<sub>Original PDF page 28 · [View source](AMY_tech_manual.pdf#page=28)</sub>

#### 7.5.6 Write System Control Register (WR SCR)

**Command byte:** `0011 XX SC1 SC0`. Low two bits update the System Control register; A/B/C unused. Reset state is `SC1=SC0=0`.

**Table 5. System Control Register Selection**

| SC1 | SC0 | AMY mode |
|:--:|:--:|---|
| X | 0 | HALT mode (sequencer stopped) |
| X | 1 | SEQUENCER RUN mode |
| 1 | X | Initialize Noise RAM (NZINIT set) |
| 0 | X | NOISE RUN mode |

The sequencer must run to produce sound. In HALT, the output is zero-coded and selected oscillator phases are reset. The Noise RAM can be initialized with the sequencer halted or running.

---


<!-- Technical Manual original PDF page 29/55 -->

<sub>Original PDF page 29 · [View source](AMY_tech_manual.pdf#page=29)</sub>

### 7.5.7 Write Noise RAM command (earlier Technical Manual)

Command: `10 N5 N4 N3 N2 N1 N0` (six-bit noise RAM address). **NZINIT in the System Control Register must be set** before issuing it. Register A supplies the three low bits of the programmed noise value; its other five bits are ignored.

The manual describes **two noise generators**, with odd addresses for generator 1 and even addresses for generator 0. It describes 54 noise RAM addresses, with overlapping ranges and phase-dependent loading. For safe initialization, use the original page scan and the initialization flowchart; **do not substitute the different Rev. B Noise RAM initialization table** here.

```mermaid
flowchart LR
  CPU[Write noise RAM command + Reg A low 3 bits] --> RAM{Noise RAM address}
  RAM -->|Even address| N0[Noise generator 0]
  RAM -->|Odd address| N1[Noise generator 1]
```


---



<details><summary>Original Atari command/register-layout scan — PDF page 29</summary>

![Original command/register drawing, page 29](assets/tech_p29.png)

</details>

<!-- Technical Manual original PDF page 30/55 -->

<sub>Original PDF page 30 · [View source](AMY_tech_manual.pdf#page=30)</sub>

#### 7.5.8 Write Last Harmonic Pair Flag Command

Command format: `10 HP4 HP3 HP2 HP1 HP0 D0`. Available with NZINIT cleared. Harmonics are assigned as even/odd pairs, starting with 0 and 1 for voice 0. There are 32 end-of-voice flags, at most eight of which should be set.

| Pair | Harmonic indices | D0=1 meaning |
|---:|---|---|
| 0 | 0–1 | Ends current voice |
| 1 | 2–3 | Ends current voice |
| 2 | 4–5 | Ends current voice |
| 3 | 6–7 | Ends current voice |
| … | … | … |
| 31 | 62–63 | Ends current voice |

For example, setting flags 3 and 31 yields an eight-harmonic voice and a 56-harmonic voice. A/B/C unused.

---



<details><summary>Original Atari command/register-layout scan — PDF page 30</summary>

![Original command/register drawing, page 30](assets/tech_p30.png)

</details>

<!-- Technical Manual original PDF page 31/55 -->

<sub>Original PDF page 31 · [View source](AMY_tech_manual.pdf#page=31)</sub>

#### 7.5.9 Write Voice Type Command

Command: `00010 V2 V1 V0`. Bits A1:A0 select the type; other bits of register A and registers B/C are not used.

| A1 | A0 | Original voice type |
|:--:|:--:|---|
| 0 | 0 | Harmonic |
| 0 | 1 | Noise type 0 |
| 1 | 0 | Noise type 1 |
| 1 | 1 | Undefined |

*Historical Technical Manual values only; no proposed fourth type is incorporated here.*

---



<details><summary>Original Atari command/register-layout scan — PDF page 31</summary>

![Original command/register drawing, page 31](assets/tech_p31.png)

</details>

<!-- Technical Manual original PDF page 32/55 -->

<sub>Original PDF page 32 · [View source](AMY_tech_manual.pdf#page=32)</sub>

### 8.2 Initialization Flow Chart

After releasing RESET (and assuming correct power and clock), the AMY 1 enters State 0. The flowchart continues across original pp. 34–36.

```mermaid
flowchart TD
  START([START]) --> POWER[Power and clock up]
  POWER --> RST[Release RESET after valid supply and clock]
  RST --> READY{RESET above VIH?}
  READY -->|No| RST
  READY -->|Yes| STATE0((State 0))
  STATE0 --> SOR[Load system options register]
  SOR --> NOISE{Use noise generators?}
  NOISE -->|No| DIS[Disable noise for all 8 voices]
  NOISE -->|Yes| NINIT[Begin noise RAM initialization]
```

**Initialization flowchart, part 1** — from printed page 34.

---


<!-- Technical Manual original PDF page 33/55 -->

<sub>Original PDF page 33 · [View source](AMY_tech_manual.pdf#page=33)</sub>

```mermaid
flowchart TD
  NINIT[Set NZINIT and keep SEQRUN = 0] --> LOAD[Load noise RAM initial conditions]
  LOAD --> CLEAR[Clear NZINIT and keep SEQRUN = 0]
  CLEAR --> VT[Assign voice types]
  VT --> ZERO[Clear all harmonic amplitudes with immediate zero breakpoint]
  ZERO --> ASSIGN[Assign last-harmonic-pair flags]
  ASSIGN --> RUN[Set SEQRUN = 1 and enter run state]
```

**Initialization flowchart, parts 2–3** — merges the continuation across printed pp. 35–36.

---


<!-- Technical Manual original PDF page 34/55 -->

<sub>Original PDF page 34 · [View source](AMY_tech_manual.pdf#page=34)</sub>

*Initialization flowchart — final step / Run state*

After all oscillator amplitudes have been loaded with immediate zero values, write the System Control Register to set **SEQRUN = 1** and clear **NZINIT = 0**. The output remains at zero until envelope data is loaded even though the oscillators are running.

When AMY is in **RUN state (State 1)**, voices can be constructed by first setting fundamental frequencies immediately, then ramping the harmonic amplitudes (and, if required, frequency). The manual allows further harmonic and frequency breakpoints in this state and quotes a maximum breakpoint rate of approximately **200,000 breakpoints per second**. Noise generation can be stopped and Noise RAM reloaded; harmonic allocations and voice types can also change. Current envelope values can be read back.

For drastic changes the manual recommends returning to State 0 by clearing SEQRUN, optionally first ramping all amplitudes to zero to avoid an audible click.


---

<!-- Technical Manual original PDF page 35/55 -->

<sub>Original PDF page 35 · [View source](AMY_tech_manual.pdf#page=35)</sub>

### 8.3 Summary

The original initialization sequence requires these operations:

1. Load the System Options Register, selecting 40 or 64 harmonics, ALE/address-pin mode, INT/RDY mode, and SUM/INDIVIDUAL output mode. Sample rate is the internal clock divided by twice the active harmonic count (for example 4 MHz / 128 = 31.25 kHz with 64 harmonics).
2. Define voices with the Last Harmonic Pair Flag command.
3. Clear all harmonic amplitudes to zero before `SEQRUN=1`.
4. Load Noise RAM initial conditions using the System Control Register and Noise RAM write command.
5. Assign each voice its initial voice type.

In READY mode, INT/RDY falls on receipt of a command and rises on completion. In INTERRUPT mode, the output emits a command-completion pulse. Individual mode produces separate voice samples; SUM mode produces their sum.

---


<!-- Technical Manual original PDF page 36/55 -->

<sub>Original PDF page 36 · [View source](AMY_tech_manual.pdf#page=36)</sub>

```mermaid
sequenceDiagram
  participant Host as Host CPU
  participant AMY as AMY 1
  Host->>AMY: Present address and command data
  Host->>AMY: Pulse WR low (with CS active)
  Note over AMY: Command begins at end of WR strobe
  alt INT mode (INT=1)
    AMY-->>Host: INT pulse when command completes
  else RDY mode (INT=0)
    AMY-->>Host: RDY low while processing
    AMY-->>Host: RDY high when complete
  end
```

**Figure 10. INT/RDY pin timing**. Event-order representation only. Original timing waveform includes low-active CS, WR, ALE, DB timing; see [source Technical Manual scan](AMY_tech_manual.pdf#page=36).

<details><summary>Original Atari diagram / timing scan — PDF page 36</summary>

![Source scan detail, Technical Manual page 36](assets/tech_p36.png)

</details>

---


<!-- Technical Manual original PDF page 37/55 -->

<sub>Original PDF page 37 · [View source](AMY_tech_manual.pdf#page=37)</sub>

## 9. Maximum ratings (beyond which useful life may be impaired)

| Parameter | Limit |
|---|---|
| Storage temperature | −65 to +150 °C |
| Ambient temperature under bias | 0 to +70 °C |
| Voltage at any pin relative to GND | −0.5 to +7 V |
| Power dissipation | **750 mW** (earlier manual; Rev. B says 1 W) |

## 10. Capacitances

Conditions: T_A = 25 °C, VCC = GND = 0 V.

| Symbol | Parameter | Max. | Unit |
|---|---|---:|---|
| C_IN | Input capacitance | 10 | pF |
| C_OUT | Output capacitance | 10 | pF |


---


<!-- Technical Manual original PDF page 38/55 -->

<sub>Original PDF page 38 · [View source](AMY_tech_manual.pdf#page=38)</sub>

## 11. D.C. CHARACTERISTICS

Conditions: ambient temperature 0 to 70 °C; VCC = +5 V **±5%**<sup>*</sup>.

**<sup>*</sup> Handwritten correction:** The typeset Technical Manual says **±10%**; the original scan (PDF p. 38) crosses this out and writes **5%**. The handwritten value is used above.

| Symbol | Parameter | Min | Max | Units | Test conditions |
|---|---|---:|---:|---|---|
| V_IL | Input low voltage | −0.5 | 0.8 | V | — |
| V_IH | Input high voltage | 2.0 | VCC+0.5 | V | — |
| V_OL | Output low voltage | — | 0.45 | V | I_OL = 2 mA |
| V_OH | Output high voltage | 2.4 | — | V | I_OH = −100 µA |
| I_L | Input leakage current | — | 10 | µA | 0 ≤ V_in ≤ VCC |
| I_O | Output leakage current | — | 10 | µA | 0.45 ≤ V_out ≤ VCC |

---


<!-- Technical Manual original PDF page 39/55 -->

<sub>Original PDF page 39 · [View source](AMY_tech_manual.pdf#page=39)</sub>

## 12. A.C. characteristics

### 12.1 Clock & reset — earlier Technical Manual

Conditions: ambient 0–70 °C; VCC = +5 V **±5%**<sup>*</sup>.

**<sup>*</sup> Handwritten correction:** The typeset Technical Manual says **±10%**; the original scan (PDF p. 39) replaces it with **5%**. The handwritten value is used above.

| No. | Symbol | Parameter | Min | Max | Unit |
|---:|---|---|---:|---:|---|
| 1 | t_p | Clock period | **200** | 500 | ns |
| 2 | t_0 | Clock high time | 0.4 t_p | 0.6 t_p | clock periods |
| 3 | t_cr | Clock rise time | — | **30** | ns |
| 4 | t_cf | Clock fall time | — | **30** | ns |
| 5 | t_rpw | RESET pulse width | **2 t_p** | — | clock periods |

RESET is held low during power-up and for at least 2 ms after the supply is valid. The later Rev. B document specifies a 100 ns minimum clock period and a 10 t_p RESET pulse instead.

```mermaid
sequenceDiagram
    participant P as Power/clock
    participant R as RESET (active low)
    P->>P: Supply and clock become valid
    Note over P,R: Keep RESET low for at least 2 ms after valid supply
    P->>R: Release RESET
    Note over R: Minimum RESET-low pulse 2 clock periods
```


---


<!-- Technical Manual original PDF page 40/55 -->

<sub>Original PDF page 40 · [View source](AMY_tech_manual.pdf#page=40)</sub>

### 12.2 Output Section

Conditions: ambient 0–70 °C; C_L = 150 pF unless otherwise noted; VCC = 5 V **±5%**<sup>*</sup>; **2 MHz ≤ CLK ≤ 5 MHz** (as printed in this A.C. output table, irrespective of the broader clock specification).

**<sup>*</sup> Handwritten correction:** The typeset output-table condition has **±10%** crossed out and **5%** written in the Technical Manual (PDF p. 40). The handwritten value is used above.

| No. | Symbol | Parameter | Min | Max | Unit |
|---:|---|---|---:|---:|---|
| 1 | t_col | CLK to OUTSTB low | 0 | 150 | ns |
| 2 | t_cot | CLK to OUTSTB high | 0 | 150 | ns |
| 3 | t_cvt | CLK to V0 falling edge | 0 | 150 | ns |
| 4 | t_cvl | CLK to V0 rising edge | 0 | 150 | ns |
| 5 | t_s | Sample period, 40 harmonic mode | 80 × t_p | 80 × t_p | — |
| 5 | t_s | Sample period, 64 harmonic mode | 128 × t_p | 128 × t_p | — |
| 6 | t_sh | Sample bus hold time from CLK | 20 | — | ns |
| 7 | t_csh1 | CLK to SAMP0–15 data valid | — | 150 | ns |
| 8 | t_csf | OE rising to SAMP0–15 high impedance | 0 | 150 | ns |
| 9 | t_cse | OE falling to SAMP0–15 valid | 0 | 150 | ns |

---


<!-- Technical Manual original PDF page 41/55 -->

<sub>Original PDF page 41 · [View source](AMY_tech_manual.pdf#page=41)</sub>

**Output timing, INDIVIDUAL voice mode (rotated scan).**

```mermaid
sequenceDiagram
    participant CLK as CLK
    participant O as OUTSTB
    participant V as V0
    participant S as SAMP(0–15)
    participant E as OE
    Note over CLK,E: One sample period = 80 or 128 clock periods
    CLK->>O: Output strobe for active voice
    O->>S: Current voice sample valid
    Note over V: V0 marks voice zero once per sample period
    E->>S: OE high puts output bus into high impedance
```

*Mermaid is only an event summary. See the original PDF timing waveform at [page 41](AMY_tech_manual.pdf#page=41) for numbered timing intervals and analog transitions.*

<details><summary>Original Atari diagram / timing scan — PDF page 41</summary>

![Source scan detail, Technical Manual page 41](assets/tech_p41.png)

</details>

---


<!-- Technical Manual original PDF page 42/55 -->

<sub>Original PDF page 42 · [View source](AMY_tech_manual.pdf#page=42)</sub>

### 12.3 System Bus Interface (Read/Write, address pin and ALE modes)

> **Editorial convention:** Timing values in six rows are placed under their physically intended Min/Max headings; the asterisks identify corrections to the original *printed column placement*. Atari’s unaltered table is visible on PDF pp. 42–43. The other timing rows remain as printed.

| No. | Symbol | Parameter | Min | Max | Unit |
|---:|---|---|---:|---:|---|
| 1 | t_ar | Address valid to RD | 0 | — | ns |
| 2 | t_rr | RD pulse width | 200 | — | ns |
| 3 | t_af | ALE float time | 10 | 100 | ns |
| 4 | t_chr | CS hold time after RD | 0 | — | ns |
| 5 | t_cr | CS active to RD | 0 | — | ns |
| 6 | t_rd | Read access time | — | 150<sup>*</sup> | ns |
| 7 | t_ao | Address to data valid | — | 150<sup>*</sup> | ns |
| 8 | t_cd | CS active to data valid | — | 150<sup>*</sup> | ns |
| 9 | t_rdh | Data hold after RD | — | 10 | ns |
| 10 | t_ahr | Address hold after RD | 0 | — | ns |
| 11 | t_rdead1 | RD dead time, address-pin mode | 100 | — | ns |
| 12 | t_cycr1 | Read cycle time, address-pin mode | 300 | — | ns |
| 13 | t_rdf | Read float time, RD to DB0–7 high-Z | 10 | 100 | ns |
| 14 | t_rdead2 | RD dead time, ALE mode | 250 | — | ns |
| 15 | t_apw | ALE pulse width | 50 | — | ns |
| 16 | t_cycr2 | ALE-mode read cycle time | 450 | — | ns |

**<sup>*</sup> Editorial correction (rows 6–8):** Atari prints `150 ns` in the **Min** column. Here it is shown in **Max**, consistent with a worst-case read-access/data-valid delay. The numeric value is unchanged; this is a column correction, not a new measurement. See original PDF p. 42.

*All times are from the original scan; labels and active-low edges should be checked against the corresponding waveforms.*

---


<!-- Technical Manual original PDF page 43/55 -->

<sub>Original PDF page 43 · [View source](AMY_tech_manual.pdf#page=43)</sub>

*System Bus Interface (continued)*

| No. | Symbol | Parameter | Min | Max | Unit |
|---:|---|---|---:|---:|---|
| 17 | t_chw | CS hold after WR | 0 | — | ns |
| 18 | t_ahw | Address hold after WR | 0 | — | ns |
| 19 | t_aw | Address setup to WR | 50<sup>*</sup> | — | ns |
| 20 | t_cw | CS setup to WR | 0 | — | ns |
| 21 | t_dw | Data setup to WR | 50<sup>*</sup> | — | ns |
| 22 | t_ww | WR pulse width | 200 | — | ns |
| 23 | t_wd | Data hold after WR | 0 | — | ns |
| 24 | t_wdead1 | WR dead time, address-pin mode | 100 | — | ns |
| 25 | t_cycw | Write cycle time, address-pin mode | 300 | — | ns |
| 26 | t_alewr | ALE to WR | 50 | — | ns |
| 27 | t_cycwale | Write cycle time, ALE mode | 400 | — | ns |
| 28 | t_wdead2 | WR dead time, ALE mode | 200 | — | ns |
| 29 | t_dwa | Data valid to ALE falling edge | 50<sup>*</sup> | — | ns |
| 30 | t_wda | Data hold after ALE falling edge | 0 | — | ns |
| 31 | t_alerd | ALE falling edge to RD falling edge | 20 | — | ns |

**<sup>*</sup> Editorial correction (rows 19, 21 and 29):** Atari prints `50 ns` in the **Max** column. Here it is shown in **Min**, consistent with required address/data setup times. The numeric value is unchanged; this is a column correction, not a new measurement. See original PDF p. 43.

*All other rows follow the printed table. For hardware design, cross-check against the original bus waveforms.*

---


<!-- Technical Manual original PDF page 44/55 -->

<sub>Original PDF page 44 · [View source](AMY_tech_manual.pdf#page=44)</sub>

```mermaid
sequenceDiagram
    participant CPU as Multiplexed-bus CPU
    participant AMY as AMY 1
    CPU->>AMY: DB0–1 carry register address, followed by ALE pulse
    CPU->>AMY: Assert CS and RD
    AMY-->>CPU: DB0–7 read data valid
    CPU->>AMY: RD deasserted
    Note over CPU,AMY: For a write, assert WR and drive DB0–7 instead
```

*ALE-mode timing figures from the original PDF; event order preserved, actual nanosecond setup/hold limits are in §12.3.*

<details><summary>Original Atari diagram / timing scan — PDF page 44</summary>

![Source scan detail, Technical Manual page 44](assets/tech_p44.png)

</details>

---


<!-- Technical Manual original PDF page 45/55 -->

<sub>Original PDF page 45 · [View source](AMY_tech_manual.pdf#page=45)</sub>

```mermaid
sequenceDiagram
    participant CPU as CPU (A0/A1 address pins)
    participant AMY as AMY 1
    CPU->>AMY: Drive A1/A0 to select register
    CPU->>AMY: Assert CS and RD (read) or WR (write)
    Note over CPU,AMY: For reads AMY drives DB0–7, for writes CPU drives DB0–7
    CPU->>AMY: Release strobe, then CS
```

*Address-pin-mode timing figures from the original PDF. Mermaid does not preserve the analog-like waveforms.*

<details><summary>Original Atari diagram / timing scan — PDF page 45</summary>

![Source scan detail, Technical Manual page 45](assets/tech_p45.png)

</details>

---


<!-- Technical Manual original PDF page 46/55 -->

<sub>Original PDF page 46 · [View source](AMY_tech_manual.pdf#page=46)</sub>

## APPENDIX I.

Table A shows the 13 bit tone values which correspond to full semitone steps on a piano keyboard. For example, Note A (440 Hz) will be reached if a fundamental frequency envelope reaches a destination value of 5004 Decimal (138C Hex). At

a 4 MHz internal clock rate the actual frequency will be 440.04 Hz. The MSB and LSB fields show the Decimal values of the Destination MSB and LSB

fields corresponding to the Atari Tone value.

Table B is in the same format as Table A, but the "Note" field was dropped as the values listed are "in between" 2 semitones (or notes on a piano). Table B shows that the actual frequency resolution at 440 Hz is approximately 0.4 Hz (1.5 cents).

Table C shows actual semitone/sec and decibel/sec slopes achieved by various 8 bit slope values. The M (mantissa) and E (exponent) fields are separated to give a feeling for the exponential coding scheme of slope byte. (Data valid for 4 MHz internal clock frequency and 64 harmonic mode).
> **Transcription note (number base).** This earlier Technical Manual presents MSB/LSB, positive and negative slope byte values, and mantissas in **decimal**. The later Rev. B specification prints them in **hexadecimal**. Both documents retain the number bases printed in their respective scans.



---


<!-- Technical Manual original PDF page 47/55 -->

<sub>Original PDF page 47 · [View source](AMY_tech_manual.pdf#page=47)</sub>

**Table A — complete transcription of PDF page 47.**

> **EDITORIAL REVIEW FLAG — printed low-frequency values.** Tone 140 is **5.4 Hz** and tone 204 is **5.7 Hz** in both original tables. These are clearly legible, but are slightly lower than a direct calculation from the stated 440.04 Hz reference. I have retained Atari’s printed values.

| Atari tone (dec) | MSB (dec) | LSB (dec) | Frequency (Hz) | Note |
|---:|---:|---:|---:|---|
| 140 | 0 | 140 | 5.4 | F |
| 204 | 0 | 204 | 5.7 | F#/Gb |
| 268 | 1 | 12 | 6.1 | G |
| 332 | 1 | 76 | 6.4 | G#/Ab |
| 396 | 1 | 140 | 6.8 | A |
| 460 | 1 | 204 | 7.2 | A#/Bb |
| 524 | 2 | 12 | 7.7 | B |
| 588 | 2 | 76 | 8.1 | C |
| 652 | 2 | 140 | 8.6 | C#/Db |
| 716 | 2 | 204 | 9.1 | D |
| 780 | 3 | 12 | 9.7 | D#/Eb |
| 844 | 3 | 76 | 10.3 | E |
| 908 | 3 | 140 | 10.9 | F |
| 972 | 3 | 204 | 11.5 | F#/Gb |
| 1036 | 4 | 12 | 12.2 | G |
| 1100 | 4 | 76 | 12.9 | G#/Ab |
| 1164 | 4 | 140 | 13.7 | A |
| 1228 | 4 | 204 | 14.5 | A#/Bb |
| 1292 | 5 | 12 | 15.4 | B |
| 1356 | 5 | 76 | 16.3 | C |
| 1420 | 5 | 140 | 17.3 | C#/Db |
| 1484 | 5 | 204 | 18.3 | D |
| 1548 | 6 | 12 | 19.4 | D#/Eb |
| 1612 | 6 | 76 | 20.6 | E |
| 1676 | 6 | 140 | 21.8 | F |
| 1740 | 6 | 204 | 23.1 | F#/Gb |
| 1804 | 7 | 12 | 24.5 | G |
| 1868 | 7 | 76 | 25.9 | G#/Ab |
| 1932 | 7 | 140 | 27.5 | A |
| 1996 | 7 | 204 | 29.1 | A#/Bb |
| 2060 | 8 | 12 | 30.8 | B |
| 2124 | 8 | 76 | 32.7 | C |
| 2188 | 8 | 140 | 34.6 | C#/Db |
| 2252 | 8 | 204 | 36.7 | D |
| 2316 | 9 | 12 | 38.8 | D#/Eb |
| 2380 | 9 | 76 | 41.2 | E |
| 2444 | 9 | 140 | 43.6 | F |
| 2508 | 9 | 204 | 46.2 | F#/Gb |
| 2572 | 10 | 12 | 49 | G |
| 2636 | 10 | 76 | 51.9 | G#/Ab |
| 2700 | 10 | 140 | 55 | A |
| 2764 | 10 | 204 | 58.2 | A#/Bb |
| 2828 | 11 | 12 | 61.7 | B |
| 2892 | 11 | 76 | 65.4 | C |
| 2956 | 11 | 140 | 69.3 | C#/Db |
| 3020 | 11 | 204 | 73.4 | D |
| 3084 | 12 | 12 | 77.7 | D#/Eb |
| 3148 | 12 | 76 | 82.4 | E |
| 3212 | 12 | 140 | 87.3 | F |
| 3276 | 12 | 204 | 92.5 | F#/Gb |


<details><summary>Full original printed table — source PDF page 47</summary>

![Source scan detail, Technical Manual page 47](assets/tech_p47.png)

</details>

---


<!-- Technical Manual original PDF page 48/55 -->

<sub>Original PDF page 48 · [View source](AMY_tech_manual.pdf#page=48)</sub>

**Table A — complete transcription of PDF page 48.**

| Atari tone (dec) | MSB (dec) | LSB (dec) | Frequency (Hz) | Note |
|---:|---:|---:|---:|---|
| 3340 | 13 | 12 | 98 | G |
| 3404 | 13 | 76 | 103.8 | G#/Ab |
| 3468 | 13 | 140 | 110 | A |
| 3532 | 13 | 204 | 116.5 | A#/Bb |
| 3596 | 14 | 12 | 123.4 | B |
| 3660 | 14 | 76 | 130.8 | C |
| 3724 | 14 | 140 | 138.6 | C#/Db |
| 3788 | 14 | 204 | 146.8 | D |
| 3852 | 15 | 12 | 155.5 | D#/Eb |
| 3916 | 15 | 76 | 164.8 | E |
| 3980 | 15 | 140 | 174.6 | F |
| 4044 | 15 | 204 | 185 | F#/Gb |
| 4108 | 16 | 12 | 196 | G |
| 4172 | 16 | 76 | 207.6 | G#/Ab |
| 4236 | 16 | 140 | 220 | A |
| 4300 | 16 | 204 | 233.1 | A#/Bb |
| 4364 | 17 | 12 | 246.9 | B |
| 4428 | 17 | 76 | 261.6 | C |
| 4492 | 17 | 140 | 277.2 | C#/Db |
| 4556 | 17 | 204 | 293.6 | D |
| 4620 | 18 | 12 | 311.1 | D#/Eb |
| 4684 | 18 | 76 | 329.6 | E |
| 4748 | 18 | 140 | 349.2 | F |
| 4812 | 18 | 204 | 370 | F#/Gb |
| 4876 | 19 | 12 | 392 | G |
| 4940 | 19 | 76 | 415.3 | G#/Ab |
| 5004 | 19 | 140 | 440 | A |
| 5068 | 19 | 204 | 466.2 | A#/Bb |
| 5132 | 20 | 12 | 493.9 | B |
| 5196 | 20 | 76 | 523.3 | C |
| 5260 | 20 | 140 | 554.4 | C#/Db |
| 5324 | 20 | 204 | 587.3 | D |
| 5388 | 21 | 12 | 622.3 | D#/Eb |
| 5452 | 21 | 76 | 659.3 | E |
| 5516 | 21 | 140 | 698.5 | F |
| 5580 | 21 | 204 | 740 | F#/Gb |
| 5644 | 22 | 12 | 784 | G |
| 5708 | 22 | 76 | 830.7 | G#/Ab |
| 5772 | 22 | 140 | 880 | A |
| 5836 | 22 | 204 | 932.4 | A#/Bb |
| 5900 | 23 | 12 | 987.8 | B |
| 5964 | 23 | 76 | 1046.6 | C |
| 6028 | 23 | 140 | 1108.8 | C#/Db |
| 6092 | 23 | 204 | 1174.7 | D |
| 6156 | 24 | 12 | 1244.6 | D#/Eb |
| 6220 | 24 | 76 | 1318.6 | E |
| 6284 | 24 | 140 | 1397 | F |
| 6348 | 24 | 204 | 1480.1 | F#/Gb |


<details><summary>Full original printed table — source PDF page 48</summary>

![Source scan detail, Technical Manual page 48](assets/tech_p48.png)

</details>

---


<!-- Technical Manual original PDF page 49/55 -->

<sub>Original PDF page 49 · [View source](AMY_tech_manual.pdf#page=49)</sub>

**Table A — complete transcription of PDF page 49.**

| Atari tone (dec) | MSB (dec) | LSB (dec) | Frequency (Hz) | Note |
|---:|---:|---:|---:|---|
| 6412 | 25 | 12 | 1568.1 | G |
| 6476 | 25 | 76 | 1661.4 | G#/Ab |
| 6540 | 25 | 140 | 1760.1 | A |
| 6604 | 25 | 204 | 1864.8 | A#/Bb |
| 6668 | 26 | 12 | 1975.7 | B |
| 6732 | 26 | 76 | 2093.2 | C |
| 6796 | 26 | 140 | 2217.7 | C#/Db |
| 6860 | 26 | 204 | 2349.5 | D |
| 6924 | 27 | 12 | 2489.2 | D#/Eb |
| 6988 | 27 | 76 | 2637.3 | E |
| 7052 | 27 | 140 | 2794.1 | F |
| 7116 | 27 | 204 | 2960.2 | F#/Gb |
| 7180 | 28 | 12 | 3136.3 | G |
| 7244 | 28 | 76 | 3322.7 | G#/Ab |
| 7308 | 28 | 140 | 3520.3 | A |
| 7372 | 28 | 204 | 3729.7 | A#/Bb |
| 7436 | 29 | 12 | 3951.4 | B |
| 7500 | 29 | 76 | 4186.4 | C |
| 7564 | 29 | 140 | 4435.4 | C#/Db |
| 7628 | 29 | 204 | 4699.1 | D |
| 7692 | 30 | 12 | 4978.5 | D#/Eb |
| 7756 | 30 | 76 | 5274.6 | E |
| 7820 | 30 | 140 | 5588.2 | F |
| 7884 | 30 | 204 | 5920.5 | F#/Gb |
| 7948 | 31 | 12 | 6272.6 | G |
| 8012 | 31 | 76 | 6645.5 | G#/Ab |
| 8076 | 31 | 140 | 7040.7 | A |
| 8140 | 31 | 204 | 7459.4 | A#/Bb |


<details><summary>Full original printed table — source PDF page 49</summary>

![Source scan detail, Technical Manual page 49](assets/tech_p49.png)

</details>

---


<!-- Technical Manual original PDF page 50/55 -->

<sub>Original PDF page 50 · [View source](AMY_tech_manual.pdf#page=50)</sub>

**Table B — complete transcription of PDF page 50.**

| Atari tone (dec) | MSB (dec) | LSB (dec) | Frequency (Hz) |
|---:|---:|---:|---:|
| 4941 | 19 | 77 | 415.7 |
| 4942 | 19 | 78 | 416 |
| 4943 | 19 | 79 | 416.4 |
| 4944 | 19 | 80 | 416.8 |
| 4945 | 19 | 81 | 417.2 |
| 4946 | 19 | 82 | 417.5 |
| 4947 | 19 | 83 | 417.9 |
| 4948 | 19 | 84 | 418.3 |
| 4949 | 19 | 85 | 418.7 |
| 4950 | 19 | 86 | 419.1 |
| 4951 | 19 | 87 | 419.4 |
| 4952 | 19 | 88 | 419.8 |
| 4953 | 19 | 89 | 420.2 |
| 4954 | 19 | 90 | 420.6 |
| 4955 | 19 | 91 | 421 |
| 4956 | 19 | 92 | 421.3 |
| 4957 | 19 | 93 | 421.7 |
| 4958 | 19 | 94 | 422.1 |
| 4959 | 19 | 95 | 422.5 |
| 4960 | 19 | 96 | 422.9 |
| 4961 | 19 | 97 | 423.2 |
| 4962 | 19 | 98 | 423.6 |
| 4963 | 19 | 99 | 424 |
| 4964 | 19 | 100 | 424.4 |
| 4965 | 19 | 101 | 424.8 |
| 4966 | 19 | 102 | 425.2 |
| 4967 | 19 | 103 | 425.5 |
| 4968 | 19 | 104 | 425.9 |
| 4969 | 19 | 105 | 426.3 |
| 4970 | 19 | 106 | 426.7 |
| 4971 | 19 | 107 | 427.1 |
| 4972 | 19 | 108 | 427.5 |
| 4973 | 19 | 109 | 427.8 |
| 4974 | 19 | 110 | 428.2 |
| 4975 | 19 | 111 | 428.6 |
| 4976 | 19 | 112 | 429 |
| 4977 | 19 | 113 | 429.4 |
| 4978 | 19 | 114 | 429.8 |
| 4979 | 19 | 115 | 430.2 |
| 4980 | 19 | 116 | 430.6 |
| 4981 | 19 | 117 | 431 |
| 4982 | 19 | 118 | 431.3 |
| 4983 | 19 | 119 | 431.7 |
| 4984 | 19 | 120 | 432.1 |
| 4985 | 19 | 121 | 432.5 |
| 4986 | 19 | 122 | 432.9 |
| 4987 | 19 | 123 | 433.3 |
| 4988 | 19 | 124 | 433.7 |
| 4989 | 19 | 125 | 434.1 |
| 4990 | 19 | 126 | 434.5 |
| 4991 | 19 | 127 | 434.9 |
| 4992 | 19 | 128 | 435.3 |
| 4993 | 19 | 129 | 435.6 |


*Atari’s printed note: range of two semitones; resolution of one Atari tone (1/64 semitone); centred around A (440 Hz).*

<details><summary>Full original printed table — source PDF page 50</summary>

![Source scan detail, Technical Manual page 50](assets/tech_p50.png)

</details>

---


<!-- Technical Manual original PDF page 51/55 -->

<sub>Original PDF page 51 · [View source](AMY_tech_manual.pdf#page=51)</sub>

**Table B — complete transcription of PDF page 51.**

| Atari tone (dec) | MSB (dec) | LSB (dec) | Frequency (Hz) |
|---:|---:|---:|---:|
| 4994 | 19 | 130 | 436 |
| 4995 | 19 | 131 | 436.4 |
| 4996 | 19 | 132 | 436.8 |
| 4997 | 19 | 133 | 437.2 |
| 4998 | 19 | 134 | 437.6 |
| 4999 | 19 | 135 | 438 |
| 5000 | 19 | 136 | 438.4 |
| 5001 | 19 | 137 | 438.8 |
| 5002 | 19 | 138 | 439.2 |
| 5003 | 19 | 139 | 439.6 |
| 5004 | 19 | 140 | 440 |
| 5005 | 19 | 141 | 440.4 |
| 5006 | 19 | 142 | 440.8 |
| 5007 | 19 | 143 | 441.2 |
| 5008 | 19 | 144 | 441.6 |
| 5009 | 19 | 145 | 442 |
| 5010 | 19 | 146 | 442.4 |
| 5011 | 19 | 147 | 442.8 |
| 5012 | 19 | 148 | 443.2 |
| 5013 | 19 | 149 | 443.6 |
| 5014 | 19 | 150 | 444 |
| 5015 | 19 | 151 | 444.4 |
| 5016 | 19 | 152 | 444.8 |
| 5017 | 19 | 153 | 445.2 |
| 5018 | 19 | 154 | 445.6 |
| 5019 | 19 | 155 | 446 |
| 5020 | 19 | 156 | 446.4 |
| 5021 | 19 | 157 | 446.8 |
| 5022 | 19 | 158 | 447.2 |
| 5023 | 19 | 159 | 447.6 |
| 5024 | 19 | 160 | 448 |
| 5025 | 19 | 161 | 448.4 |
| 5026 | 19 | 162 | 448.8 |
| 5027 | 19 | 163 | 449.2 |
| 5028 | 19 | 164 | 449.6 |
| 5029 | 19 | 165 | 450 |
| 5030 | 19 | 166 | 450.4 |
| 5031 | 19 | 167 | 450.8 |
| 5032 | 19 | 168 | 451.3 |
| 5033 | 19 | 169 | 451.7 |
| 5034 | 19 | 170 | 452.1 |
| 5035 | 19 | 171 | 452.5 |
| 5036 | 19 | 172 | 452.9 |
| 5037 | 19 | 173 | 453.3 |
| 5038 | 19 | 174 | 453.7 |
| 5039 | 19 | 175 | 454.1 |
| 5040 | 19 | 176 | 454.5 |
| 5041 | 19 | 177 | 454.9 |
| 5042 | 19 | 178 | 455.3 |
| 5043 | 19 | 179 | 455.8 |


<details><summary>Full original printed table — source PDF page 51</summary>

![Source scan detail, Technical Manual page 51](assets/tech_p51.png)

</details>

---


<!-- Technical Manual original PDF page 52/55 -->

<sub>Original PDF page 52 · [View source](AMY_tech_manual.pdf#page=52)</sub>

**Table B — complete transcription of PDF page 52.**

| Atari tone (dec) | MSB (dec) | LSB (dec) | Frequency (Hz) |
|---:|---:|---:|---:|
| 5044 | 19 | 180 | 456.2 |
| 5045 | 19 | 181 | 456.6 |
| 5046 | 19 | 182 | 457 |
| 5047 | 19 | 183 | 457.4 |
| 5048 | 19 | 184 | 457.8 |
| 5049 | 19 | 185 | 458.2 |
| 5050 | 19 | 186 | 458.6 |
| 5051 | 19 | 187 | 459.1 |
| 5052 | 19 | 188 | 459.5 |
| 5053 | 19 | 189 | 459.9 |
| 5054 | 19 | 190 | 460.3 |
| 5055 | 19 | 191 | 460.7 |
| 5056 | 19 | 192 | 461.1 |
| 5057 | 19 | 193 | 461.6 |
| 5058 | 19 | 194 | 462 |
| 5059 | 19 | 195 | 462.4 |
| 5060 | 19 | 196 | 462.8 |
| 5061 | 19 | 197 | 463.2 |
| 5062 | 19 | 198 | 463.6 |
| 5063 | 19 | 199 | 464.1 |
| 5064 | 19 | 200 | 464.5 |
| 5065 | 19 | 201 | 464.9 |
| 5066 | 19 | 202 | 465.3 |
| 5067 | 19 | 203 | 465.7 |


<details><summary>Full original printed table — source PDF page 52</summary>

![Source scan detail, Technical Manual page 52](assets/tech_p52.png)

</details>

---


<!-- Technical Manual original PDF page 53/55 -->

<sub>Original PDF page 53 · [View source](AMY_tech_manual.pdf#page=53)</sub>

**Table C — complete transcription of PDF page 53.**

| + slope (dec) | − slope (dec) | Semitones/s | dB/s | M (dec) | E (dec) |
|---:|---:|---:|---:|---:|---:|
| 0 | 128 | 0 | 0 | 0 | 0 |
| 1 | 159 | 0.11 | 1.9 | 1 | 0 |
| 2 | 158 | 0.23 | 3.81 | 2 | 0 |
| 3 | 157 | 0.35 | 5.72 | 3 | 0 |
| 4 | 156 | 0.47 | 7.62 | 4 | 0 |
| 5 | 155 | 0.59 | 9.53 | 5 | 0 |
| 6 | 154 | 0.71 | 11.44 | 6 | 0 |
| 7 | 153 | 0.83 | 13.35 | 7 | 0 |
| 8 | 152 | 0.95 | 15.25 | 8 | 0 |
| 9 | 151 | 1.07 | 17.16 | 9 | 0 |
| 10 | 150 | 1.19 | 19.07 | 10 | 0 |
| 11 | 149 | 1.31 | 20.98 | 11 | 0 |
| 12 | 148 | 1.43 | 22.88 | 12 | 0 |
| 13 | 147 | 1.54 | 24.79 | 13 | 0 |
| 14 | 146 | 1.66 | 26.7 | 14 | 0 |
| 15 | 145 | 1.78 | 28.61 | 15 | 0 |
| 16 | 144 | 1.9 | 30.51 | 16 | 0 |
| 17 | 143 | 2.02 | 32.42 | 17 | 0 |
| 18 | 142 | 2.14 | 34.33 | 18 | 0 |
| 19 | 141 | 2.26 | 36.23 | 19 | 0 |
| 20 | 140 | 2.38 | 38.14 | 20 | 0 |
| 21 | 139 | 2.5 | 40.05 | 21 | 0 |
| 22 | 138 | 2.62 | 41.96 | 22 | 0 |
| 23 | 137 | 2.74 | 43.86 | 23 | 0 |
| 24 | 136 | 2.86 | 45.77 | 24 | 0 |
| 25 | 135 | 2.98 | 47.68 | 25 | 0 |
| 26 | 134 | 3.09 | 49.59 | 26 | 0 |
| 27 | 133 | 3.21 | 51.49 | 27 | 0 |
| 28 | 132 | 3.33 | 53.4 | 28 | 0 |
| 29 | 131 | 3.45 | 55.31 | 29 | 0 |
| 30 | 130 | 3.57 | 57.22 | 30 | 0 |
| 31 | 129 | 3.69 | 59.12 | 31 | 0 |
| 32 | 160 | 0 | 0 | 0 | 1 |
| 33 | 191 | 0.47 | 7.62 | 1 | 1 |
| 34 | 190 | 0.95 | 15.25 | 2 | 1 |
| 35 | 189 | 1.43 | 22.88 | 3 | 1 |
| 36 | 188 | 1.9 | 30.51 | 4 | 1 |
| 37 | 187 | 2.38 | 38.14 | 5 | 1 |
| 38 | 186 | 2.86 | 45.77 | 6 | 1 |
| 39 | 185 | 3.33 | 53.4 | 7 | 1 |
| 40 | 184 | 3.81 | 61.03 | 8 | 1 |
| 41 | 183 | 4.29 | 68.66 | 9 | 1 |
| 42 | 182 | 4.76 | 76.29 | 10 | 1 |
| 43 | 181 | 5.24 | 83.92 | 11 | 1 |
| 44 | 180 | 5.72 | 91.55 | 12 | 1 |
| 45 | 179 | 6.19 | 99.18 | 13 | 1 |
| 46 | 178 | 6.67 | 106.81 | 14 | 1 |
| 47 | 177 | 7.15 | 114.44 | 15 | 1 |
| 48 | 176 | 7.62 | 122.07 | 16 | 1 |


*The slope code 0 occurs at each exponent with M = 0, as printed in Atari’s table. Negative codes use the chip’s sign/exponent/mantissa encoding.*

<details><summary>Full original printed table — source PDF page 53</summary>

![Source scan detail, Technical Manual page 53](assets/tech_p53.png)

</details>

---


<!-- Technical Manual original PDF page 54/55 -->

<sub>Original PDF page 54 · [View source](AMY_tech_manual.pdf#page=54)</sub>

**Table C — complete transcription of PDF page 54.**

| + slope (dec) | − slope (dec) | Semitones/s | dB/s | M (dec) | E (dec) |
|---:|---:|---:|---:|---:|---:|
| 49 | 175 | 8.1 | 129.69 | 17 | 1 |
| 50 | 174 | 8.58 | 137.32 | 18 | 1 |
| 51 | 173 | 9.05 | 144.95 | 19 | 1 |
| 52 | 172 | 9.53 | 152.58 | 20 | 1 |
| 53 | 171 | 10.01 | 160.21 | 21 | 1 |
| 54 | 170 | 10.49 | 167.84 | 22 | 1 |
| 55 | 169 | 10.96 | 175.47 | 23 | 1 |
| 56 | 168 | 11.44 | 183.1 | 24 | 1 |
| 57 | 167 | 11.92 | 190.73 | 25 | 1 |
| 58 | 166 | 12.39 | 198.36 | 26 | 1 |
| 59 | 165 | 12.87 | 205.99 | 27 | 1 |
| 60 | 164 | 13.35 | 213.62 | 28 | 1 |
| 61 | 163 | 13.82 | 221.25 | 29 | 1 |
| 62 | 162 | 14.3 | 228.88 | 30 | 1 |
| 63 | 161 | 14.78 | 236.51 | 31 | 1 |
| 64 | 192 | 0 | 0 | 0 | 2 |
| 65 | 223 | 1.9 | 30.51 | 1 | 2 |
| 66 | 222 | 3.81 | 61.03 | 2 | 2 |
| 67 | 221 | 5.72 | 91.55 | 3 | 2 |
| 68 | 220 | 7.62 | 122.07 | 4 | 2 |
| 69 | 219 | 9.53 | 152.58 | 5 | 2 |
| 70 | 218 | 11.44 | 183.1 | 6 | 2 |
| 71 | 217 | 13.35 | 213.62 | 7 | 2 |
| 72 | 216 | 15.25 | 244.14 | 8 | 2 |
| 73 | 215 | 17.16 | 274.65 | 9 | 2 |
| 74 | 214 | 19.07 | 305.17 | 10 | 2 |
| 75 | 213 | 20.98 | 335.69 | 11 | 2 |
| 76 | 212 | 22.88 | 366.21 | 12 | 2 |
| 77 | 211 | 24.79 | 396.72 | 13 | 2 |
| 78 | 210 | 26.7 | 427.24 | 14 | 2 |
| 79 | 209 | 28.61 | 457.76 | 15 | 2 |
| 80 | 208 | 30.51 | 488.28 | 16 | 2 |
| 81 | 207 | 32.42 | 518.79 | 17 | 2 |
| 82 | 206 | 34.33 | 549.31 | 18 | 2 |
| 83 | 205 | 36.23 | 579.83 | 19 | 2 |
| 84 | 204 | 38.14 | 610.35 | 20 | 2 |
| 85 | 203 | 40.05 | 640.86 | 21 | 2 |
| 86 | 202 | 41.96 | 671.38 | 22 | 2 |
| 87 | 201 | 43.86 | 701.9 | 23 | 2 |
| 88 | 200 | 45.77 | 732.42 | 24 | 2 |
| 89 | 199 | 47.68 | 762.93 | 25 | 2 |
| 90 | 198 | 49.59 | 793.45 | 26 | 2 |
| 91 | 197 | 51.49 | 823.97 | 27 | 2 |
| 92 | 196 | 53.4 | 854.49 | 28 | 2 |
| 93 | 195 | 55.31 | 885 | 29 | 2 |
| 94 | 194 | 57.22 | 915.52 | 30 | 2 |
| 95 | 193 | 59.12 | 946.04 | 31 | 2 |


<details><summary>Full original printed table — source PDF page 54</summary>

![Source scan detail, Technical Manual page 54](assets/tech_p54.png)

</details>

---


<!-- Technical Manual original PDF page 55/55 -->

<sub>Original PDF page 55 · [View source](AMY_tech_manual.pdf#page=55)</sub>

**Table C — complete transcription of PDF page 55.**

> **EDITORIAL REVIEW FLAG — pitch-slope maximum.** The top row of Table C gives **236.51 semitones/s** (and **3784.17 dB/s**), whereas the musical specifications state a maximum fundamental-frequency slope of about **118 semitones/s**. Both values are clear in the original scans. This may reflect a frequency-path update-rate distinction; no numerical correction has been assumed. See `APPENDIX_I_QA_REVIEW.md`.

| + slope (dec) | − slope (dec) | Semitones/s | dB/s | M (dec) | E (dec) |
|---:|---:|---:|---:|---:|---:|
| 96 | 224 | 0 | 0 | 0 | 3 |
| 97 | 255 | 7.62 | 122.07 | 1 | 3 |
| 98 | 254 | 15.25 | 244.14 | 2 | 3 |
| 99 | 253 | 22.88 | 366.21 | 3 | 3 |
| 100 | 252 | 30.51 | 488.28 | 4 | 3 |
| 101 | 251 | 38.14 | 610.35 | 5 | 3 |
| 102 | 250 | 45.77 | 732.42 | 6 | 3 |
| 103 | 249 | 53.4 | 854.49 | 7 | 3 |
| 104 | 248 | 61.03 | 976.56 | 8 | 3 |
| 105 | 247 | 68.66 | 1098.63 | 9 | 3 |
| 106 | 246 | 76.29 | 1220.7 | 10 | 3 |
| 107 | 245 | 83.92 | 1342.77 | 11 | 3 |
| 108 | 244 | 91.55 | 1464.84 | 12 | 3 |
| 109 | 243 | 99.18 | 1586.91 | 13 | 3 |
| 110 | 242 | 106.81 | 1708.98 | 14 | 3 |
| 111 | 241 | 114.44 | 1831.05 | 15 | 3 |
| 112 | 240 | 122.07 | 1953.12 | 16 | 3 |
| 113 | 239 | 129.69 | 2075.19 | 17 | 3 |
| 114 | 238 | 137.32 | 2197.26 | 18 | 3 |
| 115 | 237 | 144.95 | 2319.33 | 19 | 3 |
| 116 | 236 | 152.58 | 2441.4 | 20 | 3 |
| 117 | 235 | 160.21 | 2563.47 | 21 | 3 |
| 118 | 234 | 167.84 | 2685.54 | 22 | 3 |
| 119 | 233 | 175.47 | 2807.61 | 23 | 3 |
| 120 | 232 | 183.1 | 2929.68 | 24 | 3 |
| 121 | 231 | 190.73 | 3051.75 | 25 | 3 |
| 122 | 230 | 198.36 | 3173.82 | 26 | 3 |
| 123 | 229 | 205.99 | 3295.89 | 27 | 3 |
| 124 | 228 | 213.62 | 3417.96 | 28 | 3 |
| 125 | 227 | 221.25 | 3540.03 | 29 | 3 |
| 126 | 226 | 228.88 | 3662.1 | 30 | 3 |
| 127 | 225 | 236.51 | 3784.17 | 31 | 3 |


<details><summary>Full original printed table — source PDF page 55</summary>

![Source scan detail, Technical Manual page 55](assets/tech_p55.png)

</details>

---

