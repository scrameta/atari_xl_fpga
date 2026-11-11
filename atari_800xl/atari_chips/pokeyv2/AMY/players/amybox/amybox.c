/*
 * AMY MUSIC BOX for PokeyMAX                                   cc65 / atari
 *
 * A re-creation of John Howard Palevich's "AMY Music Box" (August 1983), which
 * played Atari Music Composer files on the AMY test rig: an IBM PC sent Chroma
 * style key events to an 8051 that drove the chip.  Here the PokeyMAX AMY's
 * note engine plays the 8051's part:
 *
 *   songs    the .MUS files from the 1983 AMY demo disks, converted by
 *            mksongs.py with a port of the original PARSE.C (ties, slurs,
 *            measure accents, 72.8 Hz tempo clock all as in MBOX/JCODE)
 *   timing   JCODE's interrupt logic: one score unit every `tempo` ticks of
 *            a 72.8 Hz clock, here run once per frame from the VBI counter
 *   sound    4 voices x 16 harmonics (engine layout 0).  The instruments
 *            (mkinst.py) live in the engine: per-harmonic level, attack,
 *            decay and release, and with Rev C on, per-harmonic detune
 *            and diffusion.  The 6502 only sends events: note on (note,
 *            level, band limit), note off, instrument select.
 *
 * Keys: A-Z play a song   SPACE next song   1-4 change a voice's instrument
 *       0 next ensemble    + - volume        * stereo/mono
 *       R Rev C features on/off               ESC stop
 * The screen background goes white while the player code runs.
 *
 * Needs AMY Rev C (8.192 MHz) with the note engine and its extensions
 * (revc_engine.patch).
 *
 * Build:  cl65 -t atari -Oirs -o amybox.xex amybox.c
 * Test:   cc -O2 -o amybox_host amybox.c        logs every AMY register write
 *         cl65 -t sim6502 -Oirs -DSONG=5 -DENS=0 -DFRAMES=300 -o amybox_sim amybox.c
 *         sim65 amybox_sim                      the same log from the 6502 code
 */
#include <string.h>
#include "songs.h"
#include "inst.h"

#if defined(__CC65__) && !defined(__SIM6502__)
#define ATARI 1
#include <atari.h>
#include <conio.h>
#define AMY ((volatile unsigned char *)0xD2C0)     /* PokeyMAX AMY registers */
static void amy_w(unsigned char r, unsigned char v)
{
    if (r < 8)
        while (AMY[0] & 0x40)                       /* FIFO full */
            ;
    AMY[r] = v;
}
static void amy_idle(void)
{
    while (AMY[0] & 0x80)                           /* busy: queue, reset, load */
        ;
}
static unsigned char eng_status(void) { return AMY[14]; }
/* CPU time: border and text background white while the player runs */
#define BUSY_ON()   (GTIA_WRITE.colpf2 = GTIA_WRITE.colbk = 0x0E)
#define BUSY_OFF()  (GTIA_WRITE.colpf2 = OS.color2, GTIA_WRITE.colbk = OS.color4)
#else
#include <stdio.h>
#include <stdlib.h>
static unsigned long log_frame;
#ifdef __SIM6502__
static void amy_w(unsigned char r, unsigned char v) { printf("%lu %u %u\n", log_frame, r, v); }
#else
static FILE *logf;
static void amy_w(unsigned char r, unsigned char v) { fprintf(logf, "%lu %u %u\n", log_frame, r, v); }
#endif
static void amy_idle(void) {}
static unsigned char eng_status(void) { return 0; }   /* never busy, never full */
#define BUSY_ON()   ((void)0)
#define BUSY_OFF()  ((void)0)
#endif

/* AMY commands */
#define WRVTYP  0x10    /* + voice: voice type (A: 0 = harmonic) */
#define WRSOR   0x20    /* | options */
#define WRSCR   0x30    /* | control */
#define WRHABP  0x40    /* + harmonic: amplitude breakpoint (A slope, C dest) */
#define CLRLHPF 0x80    /* + 2f */
#define SETLHPF 0x81    /* + 2f */
#define EXT_RESET 0x39  /* Rev C: detune, diffusion, attenuation to 0 */
#define OPT_INDIVIDUAL 0x04
#define REG_LEFT   4    /* PokeyMAX: voices on the left channel */
#define REG_RIGHT  5
#define REG_VOLUME 6
#define REG_EXT    7    /* Rev C unlock port */

/* note engine (spec 6.2) */
#define E_W0     8
#define E_W1     9
#define E_W2     10
#define E_EVENT  11
#define E_ADDR   12
#define E_WRITE  13
#define E_CONFIG 15     /* bit 0 on, bit 1 8x8 layout, bit 2 extension page */

#define VOICES 4

static unsigned int  tickadd;        /* 72.8 Hz ticks per frame, x1000 */
static unsigned char revc = 1;       /* Rev C features (detune, diffusion) */

/* ---- the note engine -------------------------------------------------- */
static void eng_wait_idle(void)
{
    while (eng_status() & 0x80)
        ;
}

static void eng_event(unsigned char ev, unsigned char w0, unsigned char w1, unsigned char w2)
{
    while (eng_status() & 0x40)          /* queue full (16 events) */
        ;
    amy_w(E_W0, w0);
    amy_w(E_W1, w1);
    amy_w(E_W2, w2);
    amy_w(E_EVENT, ev);
}

static void eng_word(unsigned char addr, unsigned long w)
{
    eng_wait_idle();
    amy_w(E_ADDR, addr);
    amy_w(E_W0, (unsigned char)w);
    amy_w(E_W1, (unsigned char)(w >> 8));
    amy_w(E_W2, (unsigned char)(w >> 16));
    amy_w(E_WRITE, (unsigned char)(w >> 24));
}

/* the instruments: base page, then the extension page (every word: it is
 * not cleared by reset) */
static void eng_upload(void)
{
    unsigned char i, k;
    amy_w(E_CONFIG, 0x01);                       /* 4 x 16, on */
    eng_word(40, ENG_FREQ0);
    for (i = 0; i < NINST; ++i) {
        eng_word(48 + i, eng_hdr[i]);
        for (k = 0; k < 16; ++k)
            eng_word(64 + 16 * i + k, eng_harm[i][k]);
    }
    amy_w(E_CONFIG, 0x05);                       /* extension page */
    for (i = 0; i < 128; ++i)
        eng_word(i, (i >= 32 && i < 32 + 8 * NINST) ? ext_coef[(i - 32) >> 3][i & 7] : 0);
    amy_w(E_CONFIG, 0x01);
    eng_wait_idle();
}

/* ---- song state (as JCODE's) ---------------------------------------- */
static const unsigned char *song;    /* current song blob */
static const unsigned char *durtab;
static unsigned char tempo, treg;
static unsigned int  tacc;
static unsigned char playing;

static const unsigned char *vp[VOICES];      /* stream pointer */
static unsigned char vstate[VOICES];         /* 0 attack next, 1 on, 2 gap, 3 dead */
static unsigned char von[VOICES], vgap[VOICES];
static unsigned char vbase[VOICES], vrest[VOICES];

static unsigned char vinst[VOICES];
static unsigned char ens, volume, stereo;

static void note_on(unsigned char v, unsigned char n, unsigned char vel)
{
    unsigned char k = (unsigned char)(n - 64 - HMAX_LO);
    eng_event(0x90 + v, n,
              0xB8 + (vel >> 2),                /* velocity 128 -> $D8, 255 -> $F7 */
              hmax[k < HMAX_N ? k : HMAX_N - 1]);
}

static void note_off(unsigned char v)
{
    eng_event(0x80 + v, 0, 0, 0);
}

static void all_off(void)
{
    unsigned char v;
    for (v = 0; v < VOICES; ++v)
        note_off(v);
}

/* one score unit: JCODE's state machine */
static void unit(void)
{
    unsigned char v, b, alive = 0;
    const unsigned char *d, *p;
    for (v = 0; v < VOICES; ++v) {
        switch (vstate[v]) {
        case 0:
            p = vp[v];
            while ((b = *p) == 1) { vbase[v] = p[1]; p += 2; }
            if (b == 0) { vp[v] = p; vstate[v] = 3; break; }
            d = durtab + 2 * p[1];
            von[v] = d[0]; vgap[v] = d[1];
            vrest[v] = (b == 2);
            if (!vrest[v])
                note_on(v, b & 0x7f, vbase[v] + ((b & 0x80) ? 16 : 0));
            vp[v] = p + 2;
            vstate[v] = 1;
            /* fall through */
        case 1:
            if (--von[v] == 0) {
                if (!vrest[v]) note_off(v);
                vstate[v] = 2;
            }
            break;
        case 2:
            if (--vgap[v] == 0) vstate[v] = 0;
            break;
        }
        if (vstate[v] != 3) alive = 1;
    }
    if (!alive) playing = 0;
}

static void start_song(unsigned char i)
{
    unsigned char v;
    const unsigned char *o;
    all_off();
    song = song_data[i];
    tempo = song[0];
    durtab = song + 2;
    o = durtab + 2 * song[1];
    for (v = 0; v < VOICES; ++v) {
        vp[v] = song + (o[0] | (o[1] << 8));
        o += 2;
        vstate[v] = 0;
        vbase[v] = 128;
    }
    treg = 1;
    tacc = 0;
    playing = 1;
}

/* per frame: run the 72.8 Hz clock */
static void run_frame(void)
{
    tacc += tickadd;
    while (tacc >= 1000) {
        tacc -= 1000;
        if (playing && --treg == 0) {
            treg = tempo;
            unit();
        }
    }
}

/* Unlocked, a select also sends the instrument's detune and diffusion onto
 * the voice's 16 harmonics; locked, it only sets the voice's instrument.
 * Either way the voice is silenced first. */
static void set_inst(unsigned char v, unsigned char i)
{
    vinst[v] = i;
    eng_event(0xA0 + v, i, 0, 0);
}

static void set_ensemble(unsigned char e)
{
    unsigned char v;
    ens = e;
    for (v = 0; v < VOICES; ++v)
        set_inst(v, ens_inst[e][v]);
}

static void set_stereo(void)
{
    /* voice 0 left, voice 1 right, voices 2 and 3 in the middle */
    amy_w(REG_LEFT,  stereo ? 0x0D : 0x0F);
    amy_w(REG_RIGHT, stereo ? 0x0E : 0x0F);
}

/* Rev C features on or off: unlock or lock the extensions (locking clears
 * their coefficients), then select the instruments again so the engine
 * sends, or stops sending, detune and diffusion. */
static void set_revc(unsigned char on)
{
    unsigned char v;
    revc = on;
    eng_wait_idle();
    amy_idle();
    if (on) {
        amy_w(REG_EXT, 0xA5);
        amy_w(REG_EXT, 0x5A);
        amy_w(0, EXT_RESET);
    } else {
        amy_w(REG_EXT, 0x00);
    }
    for (v = 0; v < VOICES; ++v)
        set_inst(v, vinst[v]);
}

static void amy_init(void)
{
    unsigned char i;
    amy_w(E_CONFIG, 0x00);          /* engine off while the chip resets */
    amy_w(0, 0x00);                 /* PokeyMAX: reset the chip, drop the queue */
    amy_idle();
    amy_w(0, WRSOR | OPT_INDIVIDUAL); /* 64 harmonics, voices output separately */
    amy_w(1, 0);
    amy_w(2, 0);
    amy_w(3, 0);
    for (i = 0; i < 8; ++i)
        amy_w(0, WRVTYP + i);       /* harmonic voices, A = 0 */
    for (i = 0; i < 64; ++i)
        amy_w(0, WRHABP + i);       /* silence: slope 0, amplitude 0 */
    for (i = 0; i < 32; ++i)        /* 4 voices of 16 harmonics */
        amy_w(0, ((i & 7) == 7 ? SETLHPF : CLRLHPF) + 2 * i);
    amy_w(0, WRSCR | 1);            /* sequencer on */
    set_stereo();
    amy_w(REG_VOLUME, volume);
    amy_idle();
    eng_upload();
}

#ifdef ATARI
/* ---- screen ------------------------------------------------------------ */
static unsigned char cur_song;

static void show_status(void)
{
    unsigned char v;
    gotoxy(0, 17); cclear(40);
    gotoxy(0, 17);
    cprintf("PLAYING: %s", playing ? song_name[cur_song] : (const char *)"-");
    gotoxy(0, 18); cclear(40);
    gotoxy(0, 18);
    cprintf("ENSEMBLE: %s", ens_name[ens]);
    for (v = 0; v < VOICES; ++v) {
        gotoxy((v & 1) * 20, 19 + (v >> 1)); cclear(20);
        gotoxy((v & 1) * 20, 19 + (v >> 1));
        cprintf("%u %s", v + 1, inst_name[vinst[v]]);
    }
    gotoxy(0, 21); cclear(40);
    gotoxy(0, 21);
    cprintf("VOLUME %u  %s  REV C %s", volume, stereo ? "STEREO" : "MONO", revc ? "ON" : "OFF");
}

static void show_menu(void)
{
    unsigned char i;
    clrscr();
    cputsxy(0, 0, "AMY MUSIC BOX  -  PokeyMAX note engine");
    cputsxy(0, 1, "after J.H.Palevich, Atari 1983");
    for (i = 0; i < NSONGS; ++i) {
        gotoxy((i / 13) * 20, 3 + i % 13);
        cprintf("%c %s", 'A' + i, song_name[i]);
    }
    cputsxy(0, 23, "A-Z SPC 1-4 0 +- * R:REVC ESC");
    show_status();
}

int main(void)
{
    unsigned char c, t, v, wait_end = 0;
    tickadd = get_tv() == AT_PAL ? 1457 : 1215;
    volume = 0xF0; stereo = 1;      /* x7.5: the loudest song peaks ~4 dB below clipping */
    amy_init();
    set_ensemble(0);                /* the instruments, locked */
    set_revc(1);                    /* unlock: the selects again, with detune and diffusion */
    show_menu();
    cur_song = 0;
    start_song(0);
    show_status();
    t = OS.rtclok[2];
    for (;;) {
        while (OS.rtclok[2] == t)
            ;
        BUSY_ON();
        do {                                 /* catch up if a frame overran */
            ++t;
            run_frame();
        } while (t != OS.rtclok[2]);
        BUSY_OFF();
        if (!playing) {
            if (++wait_end == 90) {          /* next song after 1.5 s */
                wait_end = 0;
                cur_song = (cur_song + 1) % NSONGS;
                start_song(cur_song);
                show_status();
            }
        }
        if (!kbhit())
            continue;
        c = cgetc();
        if (c >= 'a' && c <= 'z') c -= 32;
        if (c == 'R') {
            all_off(); set_revc(!revc);
        } else if (c >= 'A' && c < 'A' + NSONGS) {
            cur_song = c - 'A'; start_song(cur_song);
        } else if (c == ' ') {
            cur_song = (cur_song + 1) % NSONGS; start_song(cur_song);
        } else if (c >= '1' && c <= '4') {
            v = c - '1'; set_inst(v, (vinst[v] + 1) % NINST);
        } else if (c == '0') {
            set_ensemble((ens + 1) % NENS);
        } else if (c == '+' || c == '=') {
            volume = volume >= 0xF0 ? 0xFF : volume + 0x10;
            amy_w(REG_VOLUME, volume);
        } else if (c == '-' || c == '_') {
            volume = volume == 0xFF ? 0xF0 : volume > 0x10 ? volume - 0x10 : 0x10;
            amy_w(REG_VOLUME, volume);
        } else if (c == '*') {
            stereo ^= 1; set_stereo();
        } else if (c == CH_ESC) {
            all_off(); playing = 0; wait_end = 0;
        }
        show_status();
        t = OS.rtclok[2];                    /* screen work is not music time */
    }
    return 0;
}
#else
/* host / sim65: play SONG with ensemble ENS for FRAMES frames (REVC 0/1),
 * log the AMY writes as "frame reg value" */
#ifndef REVC
#define REVC 1
#endif
#ifndef __SIM6502__
int main(int argc, char **argv)
{
    unsigned long n, frames = atol(argv[3]);
    int s = atoi(argv[1]), e = atoi(argv[2]), x = argc > 5 ? atoi(argv[5]) : REVC;
    logf = fopen(argv[4], "w");
#else
int main(void)
{
    unsigned long n, frames = FRAMES;
    int s = SONG, e = ENS, x = REVC;
#endif
    tickadd = 1457;
    volume = 0xF0; stereo = 1;
    amy_init();
    set_ensemble(e);
    set_revc(x);
    start_song(s);
    for (n = 0; n < frames && playing; ++n) {
        ++log_frame;
        run_frame();
    }
#ifndef __SIM6502__
    fprintf(stderr, "%s: %lu frames\n", song_name[s], n);
    fclose(logf);
#endif
    return 0;
}
#endif
