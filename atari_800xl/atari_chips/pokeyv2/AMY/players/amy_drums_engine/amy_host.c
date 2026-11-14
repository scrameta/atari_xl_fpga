/*
 * amy_host.c - host (gcc) and sim65 stand-in for the AMY registers
 *
 * Every register write is logged as "ms reg value" to amy_log.txt (or
 * $AMY_LOG on the host).  Reads return "idle" (0).  Time is a simulated
 * 50 Hz frame clock: each frame_tick() call that the player spins on
 * advances one frame, so the log has exact frame times.
 */
#include <stdio.h>
#include <stdlib.h>
#include "amy_io.h"

static FILE *log_f;
static unsigned long sim_ms;
static uint8_t tick;

static void open_log(void)
{
#ifndef __CC65__
    const char *n = getenv("AMY_LOG");
    log_f = fopen(n ? n : "amy_log.txt", "w");
#else
    log_f = fopen("amy_log.txt", "w");
#endif
    if (!log_f) { perror("amy log"); exit(1); }
}

void amy_reg(uint8_t reg, uint8_t value)
{
    if (!log_f) open_log();
    fprintf(log_f, "%lu %u %u\n", sim_ms, reg, value);
}

uint8_t amy_peek(uint8_t reg)
{
    (void)reg;
    return 0;                   /* never busy, never full */
}

/* The player only reads the frame counter while waiting for it to
 * change, so each read is one 20 ms frame. */
uint8_t frame_tick(void)
{
    ++tick;
    sim_ms += 20;
#ifndef __CC65__
    if (getenv("AMY_MAX_MS") && sim_ms > strtoul(getenv("AMY_MAX_MS"), 0, 10)) {
        fclose(log_f);
        exit(0);
    }
#endif
    return tick;
}

void host_say(const char *s)
{
#ifndef __CC65__
    fprintf(stderr, "[%7.3f s] %s\n", sim_ms / 1000.0, s);
#else
    (void)s;
#endif
}
