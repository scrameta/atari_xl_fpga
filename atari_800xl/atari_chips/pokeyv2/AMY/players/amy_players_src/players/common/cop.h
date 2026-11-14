/*
 * cop.h - drive the copper note engine (copgen.py) from a C player
 *
 * The note engine is a copper++ program in the PokeyMAX sample RAM ($E000-$EFFF, loaded by
 * the XEX's first segment).  Thread v plays voice v; each engine event of the old note
 * engine is one copper start on that thread:
 *
 *   cop_on(v, inst, note, level, harmonics)   cop_off(v, inst)   cop_sel(v, inst)
 *
 * where inst is the voice's current instrument (the player keeps track of it, as the engine
 * did).  A start waits in the copper's start latch until the thread is at rest, so a start
 * to a voice that is still busy with its last one (an off straight after an on, say) would
 * make the 6502 wait until the copper has done the first.  So the last event is held back:
 * when the next one is for the same voice and instrument, the two go as one start of a
 * combined entry (select then on, on then off, two ons with the same harmonics, off then
 * on); otherwise the held one goes first.  cop_flush() sends the held event: call it
 * before the player waits for the next frame (the held event then still goes in the same
 * 1 ms tick).  cop_stop() and cop_mode() flush first.
 *
 * Before including, define:
 *   cop_w(r, v)    write $D200 + r       cop_r(r)    read $D200 + r
 *   cfg_w(r, v)    the same, for the configuration window (the host builds make these
 *   cfg_r(r)       a no-op and a stand-in, so the logs only have chip and copper writes)
 *   COP_SPIN       the most polls of a wait (a bound, so a missing copper can't hang)
 * and include the player's generated header (COP_ON() etc.).
 *
 * Nothing is written to the copper's registers unless cop_init() found it: on an older
 * PokeyMAX core (or a stock POKEY) $D295-$D29E are POKEY 1 shadows, SEROUT among them.
 */
#ifndef COP_H
#define COP_H

#define C_CTRL   0x95        /* bit 0 run, bit 1 STOPALL, bit 6 (read) start latch busy */
#define C_ADDRL  0x96
#define C_ADDRH  0x97
#define C_START  0x98        /* thread number; read: running mask */
#define C_KILL   0x99
#define C_TICKL  0x9B
#define C_TICKH  0x9C
#define C_BASE   0x9D
#define C_PARAM  0x9E

#define COP_TICK 16          /* scanlines: a 1 ms tick (0.97 kHz PAL, 0.98 kHz NTSC) */

static unsigned char cop_ok;      /* cop_init found the copper */
static unsigned char cop_pg;      /* the mode's page of entries (the combined ones: the next) */
static unsigned char cop_hp;      /* CADDRH as last written */

/* the held event: voice (0xFF: none), what, instrument; a start's parameters */
#define COP_SEL_    1
#define COP_ON_     2
#define COP_OFF_    3
static unsigned char cop_hv = 0xFF, cop_hop, cop_hi;
static unsigned char cop_par[5];

/* The copper is there: a PokeyMAX ($D21C reads $01 with the configuration mapped), a core
 * with the 32-byte window (RESTRICT bit 7 reads 0; older cores read 1 there and have no
 * CAPABILITY2), and CAPABILITY2 says copper and 64 KiB sample RAM. */
static unsigned char cop_present(void)
{
    unsigned char ok = 0;
    cfg_w(0x0C, 0x3F);
    if (cfg_r(0x1C) == 0x01 && !(cfg_r(0x17) & 0x80) && (cfg_r(0x20) & 0x06) == 0x06)
        ok = 1;
    cfg_w(0x0C, 0x00);
    return ok;
}

static void cop_wait(void)
{
    unsigned int n = COP_SPIN;
    while ((cop_r(C_CTRL) & 0x40) && --n)
        ;
}

/* find the copper (once, before anything else: before cop_stop() too) */
#define cop_find()      (cop_ok = cop_present())

/* one start: n parameters from cop_par, entry hi:lo, thread v */
static void cop_send(unsigned char v, unsigned char hi, unsigned char lo, unsigned char n)
{
    unsigned char k;
    cop_wait();
    for (k = 0; k < n; ++k)
        cop_w(C_PARAM, cop_par[k]);
    if (hi != cop_hp) {
        cop_hp = hi;
        cop_w(C_ADDRH, hi);
    }
    cop_w(C_ADDRL, lo);
    cop_w(C_START, v);
}

/* send the held event */
static void cop_flush(void)
{
    unsigned char v = cop_hv, i = cop_hi;
    if (v == 0xFF)
        return;
    cop_hv = 0xFF;
    if (cop_hop == COP_ON_)
        cop_send(v, cop_pg, COP_ON(i), 3);
    else
        cop_send(v, cop_pg, cop_hop == COP_SEL_ ? COP_SEL(i) : COP_OFF(i), 0);
}

/* an event: with the held one as a combined start, or hold it */
static void cop_event(unsigned char v, unsigned char op, unsigned char inst,
                      unsigned char note, unsigned char lvl, unsigned char hm)
{
    unsigned char e = 0;
    if (!cop_ok)
        return;
    if (cop_hv == v && cop_hi == inst) {
        if (op == COP_ON_) {
            if (cop_hop == COP_SEL_)
                e = COP_SELON(inst);
            else if (cop_hop == COP_OFF_)
                e = COP_OFFON(inst);
            else if (cop_par[2] == hm) {
                cop_par[3] = note;          /* legato: the second note's note and level */
                cop_par[4] = lvl;
                cop_hv = 0xFF;
                cop_send(v, cop_pg + 1, COP_ON2(inst), 5);
                return;
            }
            if (e) {
                cop_par[0] = note;
                cop_par[1] = lvl;
                cop_par[2] = hm;
            }
        } else if (op == COP_OFF_ && cop_hop == COP_ON_)
            e = COP_ONOFF(inst);            /* the held on's parameters */
        if (e) {
            cop_hv = 0xFF;
            cop_send(v, cop_pg + 1, e, 3);
            return;
        }
    }
    cop_flush();
    cop_hv = v;
    cop_hop = op;
    cop_hi = inst;
    cop_par[0] = note;
    cop_par[1] = lvl;
    cop_par[2] = hm;
}

#define cop_on(v, inst, note, lvl, hm)  cop_event((v), COP_ON_, (inst), (note), (lvl), (hm))
#define cop_off(v, inst)                cop_event((v), COP_OFF_, (inst), 0, 0, 0)
#define cop_sel(v, inst)                cop_event((v), COP_SEL_, (inst), 0, 0, 0)

/* stop every thread (they keep their registers), drop a pending start, keep running */
#define cop_stop()      do { if (cop_ok) { cop_flush(); cop_w(C_CTRL, 0x03); } } while (0)

/* Rev C extensions on or off: the entries of that mode */
#define cop_mode(x)     do { if (cop_ok) { cop_flush(); cop_pg = (x) ? COP_PAGE_X : COP_PAGE_L; \
                                           cop_hp = cop_pg; cop_w(C_ADDRH, cop_pg); } } while (0)

/* Find the copper, then start it: 1 ms tick, AMY's registers, the mode's entries, each
 * voice's constants.  Returns 0 if there's no copper. */
static unsigned char cop_init(unsigned char xen)
{
    unsigned char v;
    if (!cop_find())
        return 0;
    cop_stop();
    cop_w(C_TICKL, COP_TICK);
    cop_w(C_TICKH, 0);
    cop_w(C_BASE, 0xC0);
    cop_mode(xen);
    for (v = 0; v < COP_VOICES; ++v) {
        cop_par[0] = (unsigned char)(COP_HPV * v);
        cop_par[1] = v;
        cop_send(v, cop_pg, COP_VINIT, 2);
    }
    return 1;
}

#endif
