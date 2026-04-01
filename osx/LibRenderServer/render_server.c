#include "render_server.h"

#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "iomfb.h"

static volatile sig_atomic_t g_render_server_running = 1;

static void handle_shutdown_signal(int signal_number)
{
    (void)signal_number;
    g_render_server_running = 0;
}

static void fill_checkerboard(uint8_t *buffer, size_t width, size_t height, size_t stride)
{
    // 64x64 tiles give the checkerboard a clear, low-frequency pattern.
    const size_t tile_size = 64;

    for (size_t y = 0; y < height; ++y) {
        uint8_t *row = buffer + (y * stride);
        for (size_t x = 0; x < width; ++x) {
            bool white = (((x / tile_size) + (y / tile_size)) & 1) != 0;
            uint8_t value = white ? 0xFF : 0x00;
            uint8_t *pixel = row + (x * 4);
            pixel[0] = value;
            pixel[1] = value;
            pixel[2] = value;
            pixel[3] = 0xFF;
        }
    }
}

static int render_server_prepare_checkerboard(RenderState *state)
{
    ScreenprocBuffers buffers;
    memset(&buffers, 0, sizeof(buffers));
    screenproc_get_buffers(state, &buffers);

    if (buffers.buffer0 == NULL || buffers.buffer1 == NULL || buffers.width == 0 || buffers.height == 0) {
        fprintf(stderr, "[RenderServer] framebuffer buffers are unavailable\n");
        return 1;
    }

    if ((size_t)buffers.stride < ((size_t)buffers.width * 4)) {
        fprintf(stderr, "[RenderServer] framebuffer stride is too small\n");
        return 1;
    }

    fill_checkerboard((uint8_t *)buffers.buffer0, buffers.width, buffers.height, buffers.stride);
    fill_checkerboard((uint8_t *)buffers.buffer1, buffers.width, buffers.height, buffers.stride);
    screenproc_render_frame(state);

    return 0;
}

static void render_server_install_signal_handlers(void)
{
    signal(SIGINT, handle_shutdown_signal);
    signal(SIGTERM, handle_shutdown_signal);
}

int render_server_run(void)
{
    RenderState *state = screenproc_create();
    if (state == NULL) {
        fprintf(stderr, "[RenderServer] failed to create framebuffer state\n");
        return 1;
    }

    if (render_server_prepare_checkerboard(state) != 0) {
        screenproc_destroy(state);
        return 1;
    }

    render_server_install_signal_handlers();

    while (g_render_server_running) {
        sleep(1);
        screenproc_render_frame(state);
    }

    screenproc_destroy(state);
    return 0;
}
