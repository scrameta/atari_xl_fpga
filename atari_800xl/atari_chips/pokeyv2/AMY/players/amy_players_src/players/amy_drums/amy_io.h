/*
 * amy_io.h - AMY Rev C and copper register access for the drum machine
 *
 * Target (cc65, Atari): direct register writes, frames from RTCLOK.
 * Host (gcc) and sim65: amy_host.c logs every write as "ms reg value"
 * with a simulated 50 Hz frame clock, for tools/render.py.
 */
#ifndef AMY_IO_H
#define AMY_IO_H

#include <stdint.h>

/* ---- PokeyMAX AMY register map ($D2C0-$D2CF) ---------------------- */
#define R_CMD       0x0   /* write: command; read: bit7 busy, bit6 FIFO full */
#define R_A         0x1
#define R_B         0x2
#define R_C         0x3
#define R_LEFT      0x4   /* voice mask, left channel  */
#define R_RIGHT     0x5   /* voice mask, right channel */
#define R_VOLUME    0x6   /* gain = value/32           */
#define R_EXT       0x7   /* extension unlock port     */

#if defined(__CC65__) && !defined(AMY_SIM)

#define AMY_REG(r)      (*(volatile uint8_t *)(0xD2C0 + (r)))
#define amy_reg(r, v)   (AMY_REG(r) = (v))
#define amy_peek(r)     (AMY_REG(r))
#define cop_w(r, v)     (*(volatile uint8_t *)(0xD200 + (r)) = (v))   /* copper: $D295-$D29E */
#define cop_r(r)        (*(volatile uint8_t *)(0xD200 + (r)))
#define cfg_w(r, v)     (*(volatile uint8_t *)(0xD200 + (r)) = (v))   /* the configuration window */
#define cfg_r(r)        (*(volatile uint8_t *)(0xD200 + (r)))
#define RTCLOK2         (*(volatile uint8_t *)0x0014)
#define frame_tick()    (RTCLOK2)
#define video_pal()     ((*(volatile uint8_t *)0xD014 & 0x0E) == 0)
#define say(s)          puts(s)

#else

void amy_reg(uint8_t reg, uint8_t value);
uint8_t amy_peek(uint8_t reg);
#define cop_w(r, v)     amy_reg((r), (v))       /* logged as registers $95-$9E */
#define cop_r(r)        ((r) == 0x95 ? 1 : 0)   /* running, latch free */
#define cfg_w(r, v)     ((void)(r), (void)(v))  /* not logged: a PokeyMAX with the copper */
#define cfg_r(r)        ((r) == 0x1C ? 1 : (r) == 0x17 ? 0x3F : (r) == 0x20 ? 7 : 0)
uint8_t frame_tick(void);           /* advances simulated time by one frame */
#define video_pal()     (1)
void host_say(const char *s);
#define say(s)          host_say(s)

#endif

#endif
