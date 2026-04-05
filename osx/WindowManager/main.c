#define _POSIX_C_SOURCE 200809L

#include "bwm.h"

#include <signal.h>
#include <stdio.h>

volatile sig_atomic_t g_bwm_running = 1;

static void handle_signal(int sig)
{
    (void)sig;
    g_bwm_running = 0;
}

int main(void)
{
    signal(SIGINT,  handle_signal);
    signal(SIGTERM, handle_signal);
    signal(SIGHUP,  handle_signal);

    BwmWM wm;
    if (bwm_init(&wm) != 0) return 1;

    bwm_adopt_existing_windows(&wm);

    if (bwm_input_start(&wm) != 0) {
        fprintf(stderr, "[bwm] warning: HID input unavailable, continuing without it\n");
    }

    int result = bwm_run(&wm);

    bwm_input_stop();
    bwm_destroy(&wm);
    return result;
}
