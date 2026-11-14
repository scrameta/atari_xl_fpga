/*
 * AMY Rev C drum machine - note engine version
 * Atari 8-bit / PokeyMAX / cc65
 *
 * The kit lives in the note engine (spec 6), with the Rev C engine
 * extensions (6.8): each hit is one engine event, sent from a 50 Hz
 * frame loop.  The 6502 does no envelope or pitch work at all.
 *
 *   per instrument, in the engine        per hit, from the 6502
 *   ------------------------------       ----------------------
 *   8 harmonic slots: level, decay       note-on: note, level
 *   voice type (white noise, type 1)     (velocity), band limit
 *   detune and diffusion per slot        note-off (closed hat)
 *   exponential pitch drop (7.6)         a stereo mask change for
 *   proportional decay (cowbell)         panned instruments
 *   retrigger (clap bursts)
 *
 * Noise inside a tonal voice: a slot with diffusion 63 has its phase
 * re-randomised every sample, so it is white noise with its own
 * envelope (the kick's beater click, hat and cymbal sizzle, tom and rim
 * stick clicks, the clap snap).  Voices that are all noise (the snare
 * wires) are Rev C white-noise voices (type 3); the clap keeps the
 * original type-1 band noise.
 *
 * Grooves run on whole frames: 7 frames a sixteenth (107 bpm) or 9+7
 * swung (94 bpm, 56%) on PAL, 8 or 10+8 on NTSC, so the timing is exact.
 *
 * Assumptions: AMY Rev C C.3 with the engine extensions
 * (revc_prop.patch, revc_engine.patch), $D2C0-$D2CF, 8.192 MHz,
 * 8 voices x 8 harmonics.
 *
 * Build: see Makefile.  The song loops; any key stops playback.
 */

#include <stdint.h>
#include <stdio.h>
#include "amy_io.h"

#if defined(__CC65__) && !defined(AMY_SIM)
#define KEY_CH  (*(volatile uint8_t *)0x02FC)
/* CPU-time display: the screen goes white while the player code runs
 * (border and text background), so its share of each frame shows as
 * white bands.  The OS restores the colours from the shadows each VBI. */
#define COLPF2  (*(volatile uint8_t *)0xD018)
#define COLBK   (*(volatile uint8_t *)0xD01A)
#define COLOR2  (*(volatile uint8_t *)0x02C6)
#define COLOR4  (*(volatile uint8_t *)0x02C8)
#define BUSY_ON()   (COLPF2 = COLBK = 0x0E)
#define BUSY_OFF()  (COLPF2 = COLOR2, COLBK = COLOR4)
#else
#define BUSY_ON()   ((void)0)
#define BUSY_OFF()  ((void)0)
#endif

/* Output gain, VOLUME/32.  One harmonic at full level peaks at about
 * 1600/32768 of full scale at VOLUME 32 (measured on the Rev C RTL), so
 * a single sine kick fundamental can't be louder than that times the
 * volume.  To make the kick the loudest thing in the mix, every other
 * voice is trimmed down by MIX_TRIM (EXT_VATT, 1/4 dB) and the master
 * volume goes up by the same amount.  With Rev C off there are
 * no trims, so it runs at the lower volume. */
#define MIX_TRIM        12
#define VOLUME_EXT      160
#define VOLUME_OFF      112

/* ===================================================================
 * Voices: 8 voices x 8 harmonic slots (engine layout 1).  An engine
 * event on a voice sets all eight of its slots, so each voice belongs
 * to one group of instruments that may cut each other.
 * =================================================================== */

enum {
    V_KICK,     /* kick, 808                                    */
    V_SNARE,    /* snare head                                   */
    V_WIRES,    /* snare wires: white-noise voice (type 3)      */
    V_HAT,      /* hi-hat: metal partials + noise slots         */
    V_METAL,    /* crash / ride / cowbell                       */
    V_CLAP,     /* clap: original noise type 1, retriggered     */
    V_TOM,      /* three toms, panned per hit                   */
    V_RIM       /* rimshot                                      */
};

/* ===================================================================
 * Pitch (Rev C, 8.192 MHz): T = 4978 + 768*log2(f/440), 1/64 semitone.
 * Engine notes are semitones above NOTE0 (word 40).  NOTE0's position
 * within the semitone (2418 mod 64) is the snare's and the toms'.
 * =================================================================== */

#define NOTE0           2418
#define NOTE(t)         ((uint8_t)(((t) - NOTE0 + 32) / 64))

#define N_KICK          NOTE(2568)      /*  49.0 Hz */
#define N_808           NOTE(2452)      /*  45.0 Hz */
#define N_SNARE         NOTE(3250)      /*  92.5 Hz: half the 185 Hz head */
#define N_RIM           NOTE(5015)      /* 455   Hz */
#define N_TOM_L         NOTE(2546)      /*  49.0 Hz: half the 98 Hz floor tom */
#define N_TOM_M         NOTE(2866)      /*  65.4 Hz */
#define N_TOM_H         NOTE(3186)      /*  87.3 Hz */
#define N_HAT           NOTE(6299)      /* 1450  Hz */
#define N_RIDE          NOTE(5245)      /* 560   Hz */
#define N_CRASH         NOTE(5340)      /* 610   Hz */
#define N_COW           NOTE(4872)      /* 400   Hz */
#define N_CLAP          NOTE(4554)      /* 300   Hz (type-1 noise band) */
#define N_WIRES         NOTE(5771)      /* 900   Hz (original noise, unlocked) */

/* ===================================================================
 * Envelope slopes
 *
 * Amplitudes are logarithmic (1/4 dB), so one decaying breakpoint is an
 * exact exponential decay.  DEC(t) falls 60 dB in t ms.
 * Rate = 1.953 * M * 4^E dB/s at 32 kHz; the smallest exponent that
 * fits is used.  PROP(e, k): proportional slope (7.6), tau = 2^k
 * updates of 128/32/8/2 samples (e = 0..3).
 * =================================================================== */

#define RATE_mdB(t)     (60000000UL / (t))
#define UNIT(e)         (1953UL << (2 * (e)))
#define MANT(t, e)      ((RATE_mdB(t) + UNIT(e) / 2) / UNIT(e))
#define NEGS(e, m)      (0x80 | ((e) << 5) | ((32 - (m)) & 0x1F))
#define DEC(t)  ((uint8_t)(MANT(t, 0) <= 31 ? NEGS(0, (MANT(t, 0) < 1 ? 1 : MANT(t, 0))) : \
                           MANT(t, 1) <= 31 ? NEGS(1, MANT(t, 1)) : \
                           MANT(t, 2) <= 31 ? NEGS(2, MANT(t, 2)) : \
                           NEGS(3, (MANT(t, 3) > 31 ? 31 : MANT(t, 3)))))
#define PROP(e, k)      ((uint8_t)(((e) << 5) | (k)))

/* ===================================================================
 * Instruments (engine instruments 0-10)
 *
 * Per slot k (harmonic k+1 of the voice): peak level at full velocity
 * (1/4 dB, 0 = slot off), decay slope (to silence), detune (k+1+d/64),
 * diffusion (63 = white noise), flags.
 * =================================================================== */

#define SF_PROP     1               /* proportional decay */
#define NZ          63              /* diffusion: the slot is noise */

typedef struct { uint8_t level, dec; int8_t det; uint8_t sto, flags; } slot_t;

typedef struct {
    uint8_t rel;                    /* release slope (note-off)        */
    uint8_t type;                   /* voice type, sent on select      */
    uint8_t rep;                    /* retrigger: count << 4 | period << 2 */
    uint8_t trim;                   /* voice attenuation, 1/4 dB       */
    int8_t  poff;                   /* pitch start, 1/4 semitones      */
    uint8_t prate;                  /* proportional pitch slope        */
    slot_t  s[8];
} idef_t;

enum {
    IN_KICK, IN_808, IN_SNARE, IN_WIRES, IN_RIM, IN_HAT,
    IN_CRASH, IN_RIDE, IN_COW, IN_CLAP, IN_TOM, IN_COUNT
};

#define OFF     { 0, 0, 0, 0, 0 }

static const idef_t idef[IN_COUNT] = {
    /* Kick: 49 Hz body, its 2nd to 4th harmonics nearly as loud as the
     * fundamental (a driven, square-ish body that still carries on small
     * speakers), 24-semitone exponential drop with tau 16 ms (the thump),
     * three detuned, diffused beater partials and a noise click.  Not
     * trimmed: everything else is MIX_TRIM down. */
    { DEC(60), 0, 0, 0, 96, PROP(3, 8), {
        { 255, DEC(800), 0,   0,  0 },
        { 252, DEC(360), 0,   0,  0 },
        { 244, DEC(180), 0,   0,  0 },
        { 234, DEC(110), 0,   0,  0 },
        { 192, DEC(25),  -17, 48, 0 },
        { 186, DEC(22),  9,   48, 0 },
        { 180, DEC(19),  -25, 48, 0 },
        { 206, DEC(15),  0,   NZ, 0 } } },
    /* 808: 45 Hz boom, 1.4 s, 10 semitones down with tau 16 ms. */
    { DEC(80), 0, 0, 0, 40, PROP(3, 8), {
        { 252, DEC(1400), 0, 0, 0 },
        { 206, DEC(260),  0, 0, 0 },
        { 182, DEC(110),  0, 0, 0 },
        OFF, OFF, OFF, OFF, OFF } },
    /* Snare head: circular-membrane modes 1, 1.594, 2.136, 2.296, 2.918,
     * 3.501, 4.06 x 185 Hz on harmonics 2-8 of 92.5 Hz, rattled by
     * diffusion, 3 semitones down (tau 8 ms). */
    { DEC(60), 0, 0, MIX_TRIM, 12, PROP(3, 7), {
        OFF,
        { 234, DEC(300), 0,   8,  0 },
        { 228, DEC(220), 12,  14, 0 },
        { 222, DEC(170), 17,  18, 0 },
        { 220, DEC(150), -26, 20, 0 },
        { 212, DEC(120), -10, 22, 0 },
        { 204, DEC(100), 0,   24, 0 },
        { 198, DEC(90),  8,   26, 0 } } },
    /* Snare wires: crack, body, tail (white noise voice). */
    { DEC(150), 3, 0, MIX_TRIM, 0, 0, {
        OFF,
        { 232, DEC(16),  0, 0, 0 },
        { 222, DEC(190), 0, 0, 0 },
        { 214, DEC(260), 0, 0, 0 },
        OFF, OFF, OFF, OFF } },
    /* Rimshot: woody inharmonic ring 455 Hz - 2.65 kHz and a stick click. */
    { DEC(60), 0, 0, MIX_TRIM, 0, 0, {
        { 230, DEC(130), 0,   0,  0 },
        { 226, DEC(90),  -26, 0,  0 },
        { 222, DEC(70),  -23, 4,  0 },
        { 214, DEC(55),  -25, 8,  0 },
        { 206, DEC(45),  -6,  12, 0 },
        { 196, DEC(38),  -11, 16, 0 },
        { 222, DEC(15),  0,   NZ, 0 },
        OFF } },
    /* Hi-hat: five partials 2.0 - 7.4 kHz, heavily diffused, plus crack,
     * body and sizzle noise.  Open: as is.  Closed: a note-off straight
     * after the note-on, so the release (DEC(45)) is its decay. */
    { DEC(45), 0, 0, MIX_TRIM, 0, 0, {
        { 182, DEC(380), 26, 40, 0 },
        { 198, DEC(440), 12, 44, 0 },
        { 214, DEC(520), 26, 46, 0 },
        { 226, DEC(600), -8, 48, 0 },
        { 232, DEC(640), 5,  48, 0 },
        { 224, DEC(22),  0,  NZ, 0 },
        { 208, DEC(60),  0,  NZ, 0 },
        { 214, DEC(650), 0,  NZ, 0 } } },
    /* Crash: close partial pairs 0.8 - 3.9 kHz, full diffusion, noise
     * burst, body and a 3 s tail. */
    { DEC(400), 0, 0, MIX_TRIM, 0, 0, {
        { 212, DEC(2600), 19,  40, 0 },
        { 218, DEC(2400), -13, 42, 0 },
        { 224, DEC(2200), 27,  44, 0 },
        { 226, DEC(2000), -6,  44, 0 },
        { 228, DEC(1800), 22,  46, 0 },
        { 222, DEC(110),  0,   NZ, 0 },
        { 214, DEC(1300), 0,   NZ, 0 },
        { 202, DEC(2900), 0,   NZ, 0 } } },
    /* Ride: bell partials 560 Hz - 3.6 kHz, light diffusion, ping and wash. */
    { DEC(300), 0, 0, MIX_TRIM, 0, 0, {
        { 196, DEC(1900), 0,   0,  0 },
        { 202, DEC(1600), 17,  4,  0 },
        { 194, DEC(1400), -17, 8,  0 },
        { 190, DEC(1150), 21,  12, 0 },
        { 186, DEC(950),  -8,  14, 0 },
        { 178, DEC(800),  29,  16, 0 },
        { 176, DEC(35),   0,   NZ, 0 },
        { 164, DEC(1300), 0,   NZ, 0 } } },
    /* 808 cowbell: the two square waves (540 + 800 Hz) and their 3rd
     * harmonics.  Proportional decay towards silence (tau 256 ms for the
     * squares, 128 ms for the 3rd harmonics): fast at first, slower as it
     * fades, the 808's two-stage shape. */
    { DEC(100), 0, 0, MIX_TRIM, 0, 0, {
        { 250, PROP(2, 10), 22,  0, SF_PROP },
        { 254, PROP(2, 10), 0,   0, SF_PROP },
        OFF,
        { 220, PROP(2, 9),  3,   0, SF_PROP },
        OFF,
        { 224, PROP(2, 9),  0,   0, SF_PROP },
        { 212, PROP(2, 9),  -16, 0, SF_PROP },
        OFF } },
    /* Clap: band noise 0.6 - 2.4 kHz (type 1), four bursts 8 ms apart
     * (three retriggers), a noise snap on the clean first harmonic, and
     * the outer bands ringing on as the room. */
    { DEC(100), 1, (3 << 4) | (0 << 2), MIX_TRIM, 0, 0, {
        { 212, DEC(15),  0, NZ, 0 },
        { 192, DEC(320), 0, 0,  0 },
        { 224, DEC(60),  0, 0,  0 },
        { 230, DEC(25),  0, 0,  0 },
        { 230, DEC(25),  0, 0,  0 },
        { 222, DEC(60),  0, 0,  0 },
        { 202, DEC(320), 0, 0,  0 },
        { 188, DEC(360), 0, 0,  0 } } },
    /* Toms: membrane modes on harmonics 2-8 of half the drum's pitch,
     * 5 semitones down (tau 32 ms), a stick click on the first. */
    { DEC(80), 0, 0, MIX_TRIM, 20, PROP(3, 9), {
        { 208, DEC(20),  0,   NZ, 0 },
        { 248, DEC(750), 0,   0,  0 },
        { 234, DEC(440), 12,  4,  0 },
        { 226, DEC(330), 17,  6,  0 },
        { 222, DEC(300), -26, 8,  0 },
        { 208, DEC(220), -10, 10, 0 },
        { 200, DEC(180), 0,   12, 0 },
        { 192, DEC(150), 8,   14, 0 } } },
};

/* ===================================================================
 * Engine access (spec 6.2)
 * =================================================================== */

static uint8_t cur_inst[8];

/* Every wait on the chip is bounded (about 1 s on the Atari), so a wedged
 * chip can't hang the program: it gives up and carries on, and the next
 * configure() resets it. */
#define SPIN_MAX    20000U

static void spin_while(uint8_t reg, uint8_t mask)
{
    uint16_t n = SPIN_MAX;

    while ((amy_peek(reg) & mask) && --n)
        ;
}

static void eng_wait_idle(void)
{
    spin_while(E_STATUS, 0x80);
}

static void eng_word(uint8_t addr, uint32_t w)
{
    eng_wait_idle();
    amy_reg(E_ADDR, addr);
    amy_reg(E_W0, (uint8_t)w);
    amy_reg(E_W1, (uint8_t)(w >> 8));
    amy_reg(E_W2, (uint8_t)(w >> 16));
    amy_reg(E_WRITE, (uint8_t)(w >> 24));
}

static void eng_event(uint8_t ev, uint8_t w0, uint8_t w1, uint8_t w2)
{
    spin_while(E_STATUS, 0x40);             /* queue full */
    amy_reg(E_W0, w0);
    amy_reg(E_W1, w1);
    amy_reg(E_W2, w2);
    amy_reg(E_EVENT, ev);
}

#define note_on(v, n, l)    eng_event((uint8_t)(0x90 | (v)), (n), (l), 8)
#define note_off(v)         eng_event((uint8_t)(0x80 | (v)), 0, 0, 0)

static void select_inst(uint8_t v, uint8_t i)
{
    if (cur_inst[v] != i) {
        eng_event((uint8_t)(0xA0 | (v)), i, 0, 0);
        cur_inst[v] = i;
    }
}

/* Base page: note-0 pitch, headers, 16 harmonic entries per instrument.
 * Extension page: headers and coefficients for every word, zeros
 * included (the page is not cleared by reset). */
static void upload_kit(void)
{
    uint8_t i, k;
    const idef_t *d;
    const slot_t *s;
    uint32_t w, x;

    eng_word(40, NOTE0);
    for (i = 0, d = idef; i < IN_COUNT; ++i, ++d) {
        eng_word((uint8_t)(48 + i), d->rel | (1UL << 23));     /* decay mode */
        for (k = 0; k < 16; ++k) {
            s = &d->s[k & 7];
            w = 0xFF;                                           /* slot off */
            if (k < 8 && s->level)
                w = (uint8_t)(255 - s->level) | ((uint32_t)s->dec << 16) | 0xFF000000UL;
            eng_word((uint8_t)(64 + 16 * i + k), w);
        }
    }
    amy_reg(E_CONFIG, 0x07);                                    /* XPAGE */
    for (i = 0; i < 128; ++i) {
        w = 0;
        if (i < IN_COUNT) {
            d = &idef[i];
            w = d->type | d->rep | ((uint16_t)d->trim << 8) |
                ((uint32_t)(uint8_t)d->poff << 16) | ((uint32_t)d->prate << 24);
        } else if (i >= 32 && i < 32 + 8 * IN_COUNT && ((i - 32) & 7) < 4) {
            d = &idef[(i - 32) >> 3];
            for (k = 0; k < 2; ++k) {
                s = &d->s[(((i - 32) & 7) << 1) | k];
                x = (s->det & 0x3F) | ((uint16_t)s->sto << 8) |
                    ((s->flags & SF_PROP) ? 0x8000U : 0);
                w |= x << (16 * k);
            }
        }
        eng_word(i, w);
    }
    amy_reg(E_CONFIG, 0x03);                                    /* 8x8, on */
    eng_wait_idle();
}

/* ===================================================================
 * Raw chip set-up (engine idle)
 * =================================================================== */

#define EXT_RESET       0x39

static void amy_put(uint8_t r, uint8_t v)
{
    spin_while(R_CMD, 0x40);                /* FIFO full */
    amy_reg(r, v);
}

/* B is always written: a proportional breakpoint from the engine may
 * have left bit 7 set. */
static void amy_cmd(uint8_t cmd, uint8_t a, uint8_t b, uint8_t c)
{
    amy_put(R_A, a);
    amy_put(R_B, b);
    amy_put(R_C, c);
    amy_put(R_CMD, cmd);
}

static void amy_wait_idle(void)
{
    spin_while(R_CMD, 0x80);
}

/*
 * Seed the Noise RAM for the original noise types (Rev B 7.5.7):
 * rows 0-14 hold the three 15-bit pseudo-random registers (A/B/C in
 * data bits 2/1/0; any non-zero value runs), rows 20-31 the UD
 * counter (bit 2), noise value (bit 1) and shift control (bit 0).
 * UD = VAL = 0; S selects the brightest settings.
 */
static void seed_noise_ram(void)
{
    static const uint16_t shift_word[2] = { 0x80F, 0x00F };
    uint8_t g, row;

    amy_put(R_CMD, 0x32);                   /* NZINIT, halted */
    for (g = 0; g < 2; ++g) {
        for (row = 0; row < 15; ++row)
            amy_cmd((uint8_t)(0x80 | (row << 1) | g),
                    (uint8_t)((row * 3 + 1 + g * 5) & 7), 0, 0);
        for (row = 0; row < 12; ++row)
            amy_cmd((uint8_t)(0x80 | ((20 + row) << 1) | g),
                    (uint8_t)((shift_word[g] >> row) & 1), 0, 0);
    }
    amy_put(R_CMD, 0x30);                   /* noise run, halted */
}

static uint8_t mask_l, mask_r;

static void wait_frames(uint8_t n);

static void configure(uint8_t extended)
{
    uint8_t i;

    /* The engine keeps its state through an Atari reset (only the FPGA's
     * own reset clears it), and an EVENT write is queued even while the
     * engine is off: a write to $D2CB from any other program leaves an
     * event that keeps STATUS busy until the engine is turned on. So: turn
     * it on first (the queue drains), reset the chip (its FIFO empties, so
     * the engine's writes can't wait on it), and only then wait for idle. */
    amy_reg(E_CONFIG, 0x03);                /* engine on: drain its queue */
    amy_reg(R_CMD, 0);                      /* wrapper/core reset */
    eng_wait_idle();
    amy_reg(E_CONFIG, 0);                   /* engine off */
    amy_reg(R_CMD, 0);                      /* wrapper/core reset */
    wait_frames(1);
    amy_wait_idle();

    amy_cmd(0x24, 0, 0, 0);                 /* SOR: INDIVIDUAL, 64 harmonics */
    seed_noise_ram();
    for (i = 0; i < 8; ++i)                 /* voice types, while locked */
        amy_cmd((uint8_t)(0x10 | i), i == V_CLAP ? 1 : i == V_WIRES ? 2 : 0, 0, 0);
    for (i = 0; i < 64; ++i)
        amy_cmd((uint8_t)(0x40 | i), 0, 0, 0);
    for (i = 0; i < 32; ++i)                /* 8 harmonics per voice */
        amy_cmd((uint8_t)(0x80 | (i << 1) | ((i & 3) == 3)), 0, 0, 0);
    amy_put(R_CMD, 0x31);                   /* SEQRUN */

    if (extended) {
        amy_wait_idle();
        amy_reg(R_EXT, 0xA5);
        amy_reg(R_EXT, 0x5A);
        amy_cmd(EXT_RESET, 0, 0, 0);
    }

    mask_l = mask_r = 0xFF;
    amy_reg(R_LEFT, mask_l);
    amy_reg(R_RIGHT, mask_r);
    amy_reg(R_VOLUME, extended ? VOLUME_EXT : VOLUME_OFF);

    amy_wait_idle();
    upload_kit();
    /* Unlocked, a select sends the voice type, trim, detune and
     * diffusion; locked it only sets the voice's instrument. */
    for (i = 0; i < 8; ++i)
        cur_inst[i] = 0xFF;
    select_inst(V_KICK, IN_KICK);
    select_inst(V_SNARE, IN_SNARE);
    select_inst(V_WIRES, IN_WIRES);
    select_inst(V_HAT, IN_HAT);
    select_inst(V_METAL, IN_CRASH);
    select_inst(V_CLAP, IN_CLAP);
    select_inst(V_TOM, IN_TOM);
    select_inst(V_RIM, IN_RIM);
    eng_wait_idle();
}

static void silence(void)
{
    uint8_t i;

    eng_wait_idle();
    for (i = 0; i < 64; ++i)
        amy_cmd((uint8_t)(0x40 | i), DEC(40), 0, 0);
}

/* ===================================================================
 * Frames
 * =================================================================== */

static uint16_t frame;
static uint8_t last_tick;

static void next_frame(void)
{
    uint8_t t;

    do
        t = frame_tick();
    while (t == last_tick);
    frame += (uint8_t)(t - last_tick);
    last_tick = t;
}

static void wait_until(uint16_t f)
{
    while ((int16_t)(frame - f) < 0)
        next_frame();
}

static void wait_frames(uint8_t n)
{
    wait_until(frame + n);
}

/* ===================================================================
 * Kit: what one hit sends
 * =================================================================== */

enum { PAN_KEEP, PAN_L, PAN_C, PAN_R };

#define X_WIRES     1           /* also hit the snare wires       */
#define X_CHOKE     2           /* note-off the snare wires       */
#define X_CLOSED    4           /* note-off at once: the release   */

enum {
    I_KICK, I_K808, I_SNARE, I_RIM, I_CLAP, I_CHH, I_OHH, I_RIDE,
    I_TOML, I_TOMM, I_TOMH, I_CRASH, I_COW, I_COUNT
};

typedef struct { uint8_t voice, inst, note, quiet, pan, extra; } hit_t;

static const hit_t kit[I_COUNT] = {
    { V_KICK,  IN_KICK,  N_KICK,  0,  PAN_KEEP, 0 },
    { V_KICK,  IN_808,   N_808,   0,  PAN_KEEP, 0 },
    { V_SNARE, IN_SNARE, N_SNARE, 0,  PAN_KEEP, X_WIRES },
    { V_RIM,   IN_RIM,   N_RIM,   0,  PAN_KEEP, X_CHOKE },
    { V_CLAP,  IN_CLAP,  N_CLAP,  0,  PAN_KEEP, 0 },
    { V_HAT,   IN_HAT,   N_HAT,   0,  PAN_KEEP, X_CLOSED },
    { V_HAT,   IN_HAT,   N_HAT,   22, PAN_KEEP, 0 },
    { V_METAL, IN_RIDE,  N_RIDE,  0,  PAN_C,    0 },
    { V_TOM,   IN_TOM,   N_TOM_L, 0,  PAN_R,    0 },    /* audience view: */
    { V_TOM,   IN_TOM,   N_TOM_M, 0,  PAN_C,    0 },    /* floor tom right */
    { V_TOM,   IN_TOM,   N_TOM_H, 0,  PAN_L,    0 },
    { V_METAL, IN_CRASH, N_CRASH, 0,  PAN_C,    0 },
    { V_METAL, IN_COW,   N_COW,   0,  PAN_R,    0 },
};

static void set_pan(uint8_t voice, uint8_t pan)
{
    uint8_t bit = (uint8_t)(1 << voice);

    mask_l |= bit;
    mask_r |= bit;
    if (pan == PAN_L)
        mask_r &= (uint8_t)~bit;
    else if (pan == PAN_R)
        mask_l &= (uint8_t)~bit;
    amy_reg(R_LEFT, mask_l);
    amy_reg(R_RIGHT, mask_r);
}

/* Velocity 1..127 -> attenuation in quarter dB (0 .. ~20 dB). */
static uint8_t vel_att(uint8_t vel)
{
    return (uint8_t)(((127 - vel) * 5) >> 3);
}

static void hit(uint8_t i, uint8_t vel)
{
    const hit_t *h = &kit[i];
    uint8_t lvl = (uint8_t)(255 - vel_att(vel) - h->quiet);

    select_inst(h->voice, h->inst);
    if (h->pan != PAN_KEEP)
        set_pan(h->voice, h->pan);
    note_on(h->voice, h->note, lvl);
    if (h->extra & X_WIRES) {
        select_inst(V_WIRES, IN_WIRES);
        note_on(V_WIRES, N_WIRES, lvl);
    }
    if (h->extra & X_CHOKE)
        note_off(V_WIRES);
    if (h->extra & X_CLOSED)
        note_off(h->voice);
}

/* ===================================================================
 * Patterns
 *
 * One bar of sixteenths per string:
 *   .  rest    o  ghost (45)   x  normal (95)   X  accent (127)
 *   1-9  velocity 14..126
 * =================================================================== */

typedef struct { uint8_t inst; const char *steps; } track_t;
#define TRK_END { 0xFF, 0 }

static uint8_t vel_of(char c)
{
    if (c == 'X') return 127;
    if (c == 'x') return 95;
    if (c == 'o') return 45;
    if (c >= '1' && c <= '9') return (uint8_t)((c - '0') * 14);
    return 0;
}

static const track_t p_electro_a[] = {
    { I_K808,  "X..x..X...X....." },
    { I_CLAP,  "....X.......X..." },
    { I_COW,   "x..x..x.....x.x." },
    { I_CHH,   "XxxxXxxxXxxxXx.x" },
    { I_OHH,   "..............x." },
    TRK_END
};

static const track_t p_electro_b[] = {
    { I_K808,  "X..x..X...X..x.x" },
    { I_CLAP,  "....X.......X.xX" },
    { I_COW,   "x..x..x..x......" },
    { I_CHH,   "XxxxXxxxXxxx...." },
    { I_TOMH,  "............X..." },
    { I_TOMM,  ".............X.." },
    { I_TOML,  "..............XX" },
    TRK_END
};

static const track_t p_funk[] = {
    { I_KICK,  "X.....x..X.x...." },
    { I_SNARE, "....X..o.o..X..o" },
    { I_CHH,   "XxxxXxxxXxxxXx.x" },
    { I_OHH,   "..............x." },
    TRK_END
};

static const track_t p_funk_crash[] = {
    { I_KICK,  "X.....x..X.x...." },
    { I_CRASH, "X..............." },
    { I_SNARE, "....X..o.o..X..o" },
    { I_CHH,   "..xxXxxxXxxxXx.x" },
    { I_OHH,   "..............x." },
    TRK_END
};

static const track_t p_funk_fill[] = {
    { I_KICK,  "X.....x........X" },
    { I_SNARE, "....X..oX.o.ooxx" },
    { I_TOMH,  "........xx......" },
    { I_TOML,  "..........Xx...." },
    { I_CHH,   "XxxxXxx........." },
    TRK_END
};

static const track_t p_fill_toms[] = {
    { I_KICK,  "X..............." },
    { I_SNARE, "X.oxX.ox........" },
    { I_TOMH,  "........Xx......" },
    { I_TOMM,  "..........Xx...." },
    { I_TOML,  "............XxXX" },
    TRK_END
};

static const track_t p_ride[] = {
    { I_KICK,  "X..x......X..x.." },
    { I_RIM,   "...x..x...x..x.." },
    { I_RIDE,  "X.x.X.xxX.x.X.xx" },
    { I_CHH,   "....x.......x..." },
    TRK_END
};

static const track_t p_ride_b[] = {
    { I_KICK,  "X..x......X..x.." },
    { I_RIM,   "...x..x...x....." },
    { I_SNARE, "...............X" },
    { I_RIDE,  "X.x.X.xxX.x.X.x." },
    { I_CHH,   "....x.......x..." },
    TRK_END
};

static const track_t p_end[] = {
    { I_KICK,  "X..............." },
    { I_CRASH, "X..............." },
    TRK_END
};

/* ===================================================================
 * Song
 * =================================================================== */

/* Frames per sixteenth: [groove][video][even, odd step]. */
enum { GR_ELECTRO, GR_FUNK, GR_RIDE };
static const uint8_t groove[3][2][2] = {
    { { 7, 7 }, { 8, 8 } },         /* 107 / 112 bpm               */
    { { 9, 7 }, { 10, 8 } },        /*  94 / 100 bpm, swung 56%    */
    { { 7, 7 }, { 9, 9 } },         /* 107 / 100 bpm               */
};

enum { S_PLAY, S_TOUR, S_SETUP, S_STOP };

typedef struct {
    uint8_t op;
    const track_t *pat;
    uint8_t groove;
    const char *title;
} song_t;

static const song_t song[] = {
    { S_SETUP,  0,            0,          0 },
    { S_TOUR,   0,            0,          0 },
    { S_PLAY,   p_electro_a,  GR_ELECTRO, "Electro 808" },
    { S_PLAY,   p_electro_a,  GR_ELECTRO, 0 },
    { S_PLAY,   p_electro_a,  GR_ELECTRO, 0 },
    { S_PLAY,   p_electro_b,  GR_ELECTRO, 0 },
    { S_PLAY,   p_electro_a,  GR_ELECTRO, 0 },
    { S_PLAY,   p_electro_a,  GR_ELECTRO, 0 },
    { S_PLAY,   p_electro_a,  GR_ELECTRO, 0 },
    { S_PLAY,   p_electro_b,  GR_ELECTRO, 0 },
    { S_PLAY,   p_funk_crash, GR_FUNK,    "Funk, swung 56%" },
    { S_PLAY,   p_funk,       GR_FUNK,    0 },
    { S_PLAY,   p_funk,       GR_FUNK,    0 },
    { S_PLAY,   p_funk_fill,  GR_FUNK,    0 },
    { S_PLAY,   p_funk_crash, GR_FUNK,    0 },
    { S_PLAY,   p_funk,       GR_FUNK,    0 },
    { S_PLAY,   p_funk,       GR_FUNK,    0 },
    { S_PLAY,   p_fill_toms,  GR_FUNK,    0 },
    { S_PLAY,   p_ride,       GR_RIDE,    "Ride and rimshot" },
    { S_PLAY,   p_ride,       GR_RIDE,    0 },
    { S_PLAY,   p_ride,       GR_RIDE,    0 },
    { S_PLAY,   p_ride_b,     GR_RIDE,    0 },
    { S_PLAY,   p_funk_crash, GR_FUNK,    "Funk again" },
    { S_PLAY,   p_funk,       GR_FUNK,    0 },
    { S_PLAY,   p_funk,       GR_FUNK,    0 },
    { S_PLAY,   p_fill_toms,  GR_FUNK,    0 },
    { S_PLAY,   p_funk_crash, GR_FUNK,    0 },
    { S_PLAY,   p_funk,       GR_FUNK,    0 },
    { S_PLAY,   p_funk,       GR_FUNK,    0 },
    { S_PLAY,   p_fill_toms,  GR_FUNK,    0 },
    { S_PLAY,   p_end,        GR_FUNK,    0 },
    { S_STOP,   0,            0,          0 },
};

static uint8_t ntsc;

/* Rev C features: R toggles them; the change takes effect at the next bar
 * (the kit is set up again, locked or unlocked).  Any other key stops. */
#ifndef REVC_START
#define REVC_START 1
#endif
static uint8_t revc = REVC_START;
static uint8_t reconf;

#define KEY_R   0x28                    /* Atari internal key code */

static uint8_t key_pressed(void)
{
#if defined(__CC65__) && !defined(AMY_SIM)
    uint8_t k = KEY_CH;
    if (k == 0xFF)
        return 0;
    KEY_CH = 0xFF;
    if ((k & 0x3F) == KEY_R) {
        revc ^= 1;
        reconf = 1;
        return 0;
    }
    return 1;
#else
    return 0;
#endif
}

static void say_mode(void)
{
    say(revc ? "Rev C features ON  (R toggles)" : "Rev C features OFF (R toggles)");
}

/* Bars run on an absolute frame grid; resync after set-up, tour or
 * printing (a soft resync only moves the grid if the print made us late). */
static uint16_t bar_f;
static uint8_t resync = 1;

static void play_bar(const track_t *pat, uint8_t gr)
{
    uint8_t a = groove[gr][ntsc][0], b = groove[gr][ntsc][1];
    uint16_t start;
    uint8_t step, v;
    const track_t *t;

    if (resync == 1 || (resync == 2 && (int16_t)(frame - bar_f) > 0))
        bar_f = frame + 1;
    resync = 0;
    start = bar_f;
    bar_f += 8 * (a + b);

    for (step = 0; step < 16; ++step) {
        wait_until(start + (step >> 1) * (a + b) + ((step & 1) ? a : 0));
        BUSY_ON();
        for (t = pat; t->inst != 0xFF; ++t) {
            v = vel_of(t->steps[step]);
            if (v)
                hit(t->inst, v);
        }
        BUSY_OFF();
    }
}

/* Gaps in PAL frames (20 ms). */
static const struct { uint8_t inst; uint8_t n; uint8_t gap; const char *name; } tour[] = {
    { I_KICK,  3, 22,  "Kick" },
    { I_K808,  2, 45,  "808 kick" },
    { I_SNARE, 3, 22,  "Snare" },
    { I_RIM,   3, 15,  "Rimshot" },
    { I_CLAP,  3, 22,  "Clap" },
    { I_CHH,   6, 8,   "Closed hat" },
    { I_OHH,   2, 32,  "Open hat" },
    { I_TOMH,  1, 15,  "Toms (left to right)" },
    { I_TOMM,  1, 15,  0 },
    { I_TOML,  1, 40,  0 },
    { I_RIDE,  4, 16,  "Ride" },
    { I_COW,   4, 11,  "Cowbell" },
    { I_CRASH, 1, 110, "Crash" },
};

static void play_tour(void)
{
    uint8_t i, n;

    for (i = 0; i < sizeof(tour) / sizeof(tour[0]); ++i) {
        if (tour[i].name)
            say(tour[i].name);
        for (n = 0; n < tour[i].n; ++n) {
            BUSY_ON();
            hit(tour[i].inst, 127);
            BUSY_OFF();
            wait_frames(ntsc ? (uint8_t)(tour[i].gap + tour[i].gap / 5) : tour[i].gap);
            if (key_pressed())
                return;
        }
    }
}

int main(void)
{
    const song_t *s;
    uint8_t live = 0;

    say("AMY Rev C Drum Machine");
    say("Note engine, 50 Hz");
    say("R: Rev C on/off, other keys stop");

    ntsc = video_pal() ? 0 : 1;
    last_tick = frame_tick();

    for (;;) {
        for (s = song; s->op != S_STOP; ++s) {
            if (key_pressed())
                goto done;
            if (reconf && s->op == S_PLAY) {
                reconf = 0;
                if (live)
                    wait_until(bar_f);      /* let the last bar finish */
                silence();
                wait_frames(3);
                configure(revc);
                say_mode();
                resync = 1;
            }
            if (s->title) {
                say(s->title);
                if (!resync)
                    resync = 2;
            }
            if (s->op != S_PLAY)
                resync = 1;
            live = (s->op == S_PLAY);
            switch (s->op) {
            case S_SETUP:  configure(revc); say_mode(); reconf = 0; break;
            case S_TOUR:   play_tour();  break;
            default:       play_bar(s->pat, s->groove); break;
            }
        }
        wait_frames(125);
#if !defined(__CC65__) || defined(AMY_SIM)
        break;              /* host: one pass */
#endif
    }

done:
    silence();
    wait_frames(5);
#if defined(__CC65__) && !defined(AMY_SIM)
    KEY_CH = 0xFF;
#endif
    say("Finished");
    return 0;
}
