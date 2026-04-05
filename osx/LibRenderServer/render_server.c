#define _POSIX_C_SOURCE 200809L

#include "render_server.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <xcb/xcb.h>

#include "iomfb.h"
#include "compositing.h"

#define RENDER_SERVER_MODEL_REFRESH_HZ 60
#define RENDER_SERVER_DISPLAYFD 99
#define RENDER_SERVER_MAX_PIXEL_CLOCK_MHZ 300.0
#define RENDER_SERVER_DEFAULT_REFRESH_HZ 60

typedef struct {
    xcb_connection_t *connection;
    xcb_screen_t     *screen;
    pid_t             xorg_pid;
    int               screen_index;
    int               display_number;
    uint16_t          width;
    uint16_t          height;
    uint8_t           bits_per_pixel;
    uint32_t          refresh_hz;
    bool              composite_enabled;
    char              display_name[64];
    char              xorg_path[PATH_MAX];
    char              config_path[PATH_MAX];
    char              log_path[PATH_MAX];
} XServerState;

static volatile sig_atomic_t g_render_server_running = 1;

static void handle_shutdown_signal(int signal_number)
{
    (void)signal_number;
    g_render_server_running = 0;
}

static void render_server_install_signal_handlers(void)
{
    signal(SIGINT, handle_shutdown_signal);
    signal(SIGTERM, handle_shutdown_signal);
}

static bool render_server_file_is_executable(const char *path)
{
    return path != NULL && access(path, X_OK) == 0;
}

static void render_server_add_ns(struct timespec *ts, int64_t ns)
{
    ts->tv_nsec += (long)(ns % 1000000000LL);
    ts->tv_sec += (time_t)(ns / 1000000000LL);
    if (ts->tv_nsec >= 1000000000L) {
        ts->tv_nsec -= 1000000000L;
        ts->tv_sec += 1;
    }
}

static int64_t render_server_timespec_diff_ns(const struct timespec *a,
                                              const struct timespec *b)
{
    return ((int64_t)a->tv_sec - (int64_t)b->tv_sec) * 1000000000LL +
           ((int64_t)a->tv_nsec - (int64_t)b->tv_nsec);
}

static int render_server_find_xorg(char *path_out, size_t path_out_size)
{
    static const char *const candidates[] = {
        "/opt/local/bin/Xorg",
        "/opt/X11/bin/Xorg",
        NULL,
    };

    for (size_t i = 0; candidates[i] != NULL; ++i) {
        if (!render_server_file_is_executable(candidates[i])) {
            continue;
        }

        if (snprintf(path_out, path_out_size, "%s", candidates[i]) >= (int)path_out_size) {
            return 1;
        }
        return 0;
    }

    fprintf(stderr, "[RenderServer] failed to locate an Xorg binary\n");
    return 1;
}

static bool render_server_parse_display_value(const char *value, int *display_out)
{
    if (value == NULL || *value == '\0' || strchr(value, '/') != NULL) {
        return false;
    }

    const char *start = value;
    const char *last_colon = strrchr(value, ':');
    if (last_colon != NULL) {
        start = last_colon + 1;
    } else if (*start == ':') {
        ++start;
    }

    if (*start == '\0') {
        return false;
    }

    char *end = NULL;
    long parsed = strtol(start, &end, 10);
    if (end == start || parsed < 0 || parsed > 1024) {
        return false;
    }

    if (*end != '\0' && *end != '.') {
        return false;
    }

    *display_out = (int)parsed;
    return true;
}

static int render_server_requested_display(void)
{
    int requested = -1;
    const char *display = getenv("DISPLAY");

    if (render_server_parse_display_value(display, &requested)) {
        return requested;
    }

    return -1;
}

static int render_server_generate_modeline(uint32_t width,
                                           uint32_t height,
                                           char *mode_name_out,
                                           size_t mode_name_out_size,
                                           char *modeline_out,
                                           size_t modeline_out_size)
{
    static const char *const cvt_candidates[] = {
        "/opt/local/bin/cvt",
        "/opt/X11/bin/cvt",
        NULL,
    };
    static const char *const gtf_candidates[] = {
        "/opt/local/bin/gtf",
        "/opt/X11/bin/gtf",
        NULL,
    };
    static const int refresh_rates[] = {60, 50, 40, 30, 20, 15};

    for (size_t candidate_index = 0; cvt_candidates[candidate_index] != NULL; ++candidate_index) {
        if (!render_server_file_is_executable(cvt_candidates[candidate_index])) {
            continue;
        }

        for (size_t refresh_index = 0; refresh_index < sizeof(refresh_rates) / sizeof(refresh_rates[0]); ++refresh_index) {
            for (int reduced = 0; reduced < 2; ++reduced) {
                if (reduced != 0 && refresh_rates[refresh_index] != RENDER_SERVER_MODEL_REFRESH_HZ) {
                    continue;
                }

                char command[PATH_MAX + 96];
                if (snprintf(command,
                             sizeof(command),
                             "\"%s\" %s%u %u %d 2>/dev/null",
                             cvt_candidates[candidate_index],
                             reduced != 0 ? "-r " : "",
                             width,
                             height,
                             refresh_rates[refresh_index]) >= (int)sizeof(command)) {
                    continue;
                }

                FILE *pipe = popen(command, "r");
                if (pipe == NULL) {
                    continue;
                }

                char line[512];
                int result = 1;
                while (fgets(line, sizeof(line), pipe) != NULL) {
                    char *modeline = strstr(line, "Modeline ");
                    if (modeline == NULL) {
                        continue;
                    }

                    char *newline = strchr(modeline, '\n');
                    if (newline != NULL) {
                        *newline = '\0';
                    }

                    char *quote_start = strchr(modeline, '"');
                    if (quote_start == NULL) {
                        break;
                    }

                    char *quote_end = strchr(quote_start + 1, '"');
                    if (quote_end == NULL) {
                        break;
                    }

                    char *clock_start = quote_end + 1;
                    while (*clock_start == ' ' || *clock_start == '\t') {
                        ++clock_start;
                    }

                    char *clock_end = NULL;
                    double pixel_clock = strtod(clock_start, &clock_end);
                    if (clock_end == clock_start || pixel_clock > RENDER_SERVER_MAX_PIXEL_CLOCK_MHZ) {
                        break;
                    }

                    size_t mode_name_len = (size_t)(quote_end - (quote_start + 1));
                    if (mode_name_len == 0 || mode_name_len >= mode_name_out_size) {
                        break;
                    }

                    memcpy(mode_name_out, quote_start + 1, mode_name_len);
                    mode_name_out[mode_name_len] = '\0';

                    if (snprintf(modeline_out, modeline_out_size, "%s", modeline) >=
                        (int)modeline_out_size) {
                        break;
                    }

                    result = 0;
                    break;
                }

                pclose(pipe);
                if (result == 0) {
                    return 0;
                }
            }
        }
    }

    for (size_t candidate_index = 0; gtf_candidates[candidate_index] != NULL; ++candidate_index) {
        if (!render_server_file_is_executable(gtf_candidates[candidate_index])) {
            continue;
        }

        for (size_t refresh_index = 0; refresh_index < sizeof(refresh_rates) / sizeof(refresh_rates[0]); ++refresh_index) {
            char command[PATH_MAX + 96];
            if (snprintf(command,
                         sizeof(command),
                         "\"%s\" %u %u %d 2>/dev/null",
                         gtf_candidates[candidate_index],
                         width,
                         height,
                         refresh_rates[refresh_index]) >= (int)sizeof(command)) {
                continue;
            }

            FILE *pipe = popen(command, "r");
            if (pipe == NULL) {
                continue;
            }

            char line[512];
            int result = 1;
            while (fgets(line, sizeof(line), pipe) != NULL) {
                char *modeline = strstr(line, "Modeline ");
                if (modeline == NULL) {
                    continue;
                }

                char *newline = strchr(modeline, '\n');
                if (newline != NULL) {
                    *newline = '\0';
                }

                char *quote_start = strchr(modeline, '"');
                if (quote_start == NULL) {
                    break;
                }

                char *quote_end = strchr(quote_start + 1, '"');
                if (quote_end == NULL) {
                    break;
                }

                char *clock_start = quote_end + 1;
                while (*clock_start == ' ' || *clock_start == '\t') {
                    ++clock_start;
                }

                char *clock_end = NULL;
                double pixel_clock = strtod(clock_start, &clock_end);
                if (clock_end == clock_start || pixel_clock > RENDER_SERVER_MAX_PIXEL_CLOCK_MHZ) {
                    break;
                }

                size_t mode_name_len = (size_t)(quote_end - (quote_start + 1));
                if (mode_name_len == 0 || mode_name_len >= mode_name_out_size) {
                    break;
                }

                memcpy(mode_name_out, quote_start + 1, mode_name_len);
                mode_name_out[mode_name_len] = '\0';

                if (snprintf(modeline_out, modeline_out_size, "%s", modeline) >=
                    (int)modeline_out_size) {
                    break;
                }

                result = 0;
                break;
            }

            pclose(pipe);
            if (result == 0) {
                return 0;
            }
        }
    }

    fprintf(stderr,
            "[RenderServer] failed to generate an Xorg modeline for %ux%u\n",
            width,
            height);
    return 1;
}

static int render_server_write_xorg_config(XServerState *server, uint32_t width, uint32_t height)
{
    char mode_name[128];
    char modeline[512];
    char config_template[] = "/tmp/applicator-render-server-XXXXXX";

    if (render_server_generate_modeline(width,
                                        height,
                                        mode_name,
                                        sizeof(mode_name),
                                        modeline,
                                        sizeof(modeline)) != 0) {
        return 1;
    }

    int config_fd = mkstemp(config_template);
    if (config_fd < 0) {
        fprintf(stderr, "[RenderServer] failed to create a temporary Xorg config: %s\n", strerror(errno));
        return 1;
    }

    if (snprintf(server->config_path, sizeof(server->config_path), "%s", config_template) >=
        (int)sizeof(server->config_path)) {
        close(config_fd);
        unlink(config_template);
        return 1;
    }

    if (snprintf(server->log_path,
                 sizeof(server->log_path),
                 "/tmp/applicator-render-server-%ld.log",
                 (long)getpid()) >= (int)sizeof(server->log_path)) {
        close(config_fd);
        unlink(server->config_path);
        return 1;
    }

    FILE *config = fdopen(config_fd, "w");
    if (config == NULL) {
        fprintf(stderr, "[RenderServer] failed to open the temporary Xorg config: %s\n", strerror(errno));
        close(config_fd);
        unlink(server->config_path);
        return 1;
    }

    fprintf(config,
            "Section \"ServerLayout\"\n"
            "    Identifier \"Layout0\"\n"
            "    Screen \"Screen0\"\n"
            "EndSection\n"
            "\n"
            "Section \"Monitor\"\n"
            "    Identifier \"Monitor0\"\n"
            "    HorizSync 1.0-300.0\n"
            "    VertRefresh 1.0-300.0\n"
            "    %s\n"
            "EndSection\n"
            "\n"
            "Section \"Device\"\n"
            "    Identifier \"DummyDevice\"\n"
            "    Driver \"dummy\"\n"
            "    VideoRam 512000\n"
            "EndSection\n"
            "\n"
            "Section \"Screen\"\n"
            "    Identifier \"Screen0\"\n"
            "    Device \"DummyDevice\"\n"
            "    Monitor \"Monitor0\"\n"
            "    DefaultDepth 24\n"
            "    SubSection \"Display\"\n"
            "        Depth 24\n"
            "        Modes \"%s\"\n"
            "        Virtual %u %u\n"
            "    EndSubSection\n"
            "EndSection\n",
            modeline,
            mode_name,
            width,
            height);

    if (fclose(config) != 0) {
        fprintf(stderr, "[RenderServer] failed to finalize the Xorg config: %s\n", strerror(errno));
        unlink(server->config_path);
        server->config_path[0] = '\0';
        return 1;
    }

    server->width = (uint16_t)width;
    server->height = (uint16_t)height;
    return 0;
}

static int render_server_wait_for_displayfd(pid_t xorg_pid, int read_fd, int *display_out)
{
    char buffer[64];
    size_t used = 0;
    int waited_ms = 0;

    memset(buffer, 0, sizeof(buffer));

    for (;;) {
        struct pollfd fd = {
            .fd = read_fd,
            .events = POLLIN | POLLHUP,
            .revents = 0,
        };

        int poll_result = poll(&fd, 1, 100);
        if (poll_result < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "[RenderServer] polling Xorg displayfd failed: %s\n", strerror(errno));
            return 1;
        }

        int status = 0;
        pid_t waited = waitpid(xorg_pid, &status, WNOHANG);
        if (waited == xorg_pid) {
            fprintf(stderr, "[RenderServer] Xorg exited before reporting a display number\n");
            return 1;
        }

        if (poll_result == 0) {
            waited_ms += 100;
            if (waited_ms >= 10000) {
                fprintf(stderr, "[RenderServer] timed out waiting for Xorg to report a display number\n");
                return 1;
            }
            continue;
        }

        if ((fd.revents & (POLLIN | POLLHUP)) == 0) {
            continue;
        }

        ssize_t read_size = read(read_fd, buffer + used, sizeof(buffer) - used - 1);
        if (read_size < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "[RenderServer] reading the Xorg displayfd failed: %s\n", strerror(errno));
            return 1;
        }

        if (read_size == 0) {
            break;
        }

        used += (size_t)read_size;
        buffer[used] = '\0';

        char *end = NULL;
        long parsed = strtol(buffer, &end, 10);
        if (end != buffer && parsed >= 0 && parsed <= 1024) {
            *display_out = (int)parsed;
            return 0;
        }
    }

    fprintf(stderr, "[RenderServer] Xorg did not report a usable display number\n");
    return 1;
}

static int render_server_spawn_xorg(XServerState *server, int requested_display)
{
    int display_pipe[2] = {-1, -1};
    bool auto_display = requested_display < 0;

    if (auto_display && pipe(display_pipe) != 0) {
        fprintf(stderr, "[RenderServer] failed to create the Xorg displayfd pipe: %s\n", strerror(errno));
        return 1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        if (display_pipe[0] >= 0) {
            close(display_pipe[0]);
        }
        if (display_pipe[1] >= 0) {
            close(display_pipe[1]);
        }
        fprintf(stderr, "[RenderServer] failed to fork Xorg: %s\n", strerror(errno));
        return 1;
    }

    if (pid == 0) {
        if (auto_display) {
            close(display_pipe[0]);
            if (dup2(display_pipe[1], RENDER_SERVER_DISPLAYFD) < 0) {
                _exit(127);
            }
            close(display_pipe[1]);
        }

        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            if (devnull > STDERR_FILENO) {
                close(devnull);
            }
        }

        char display_arg[16];
        char *argv[16];
        size_t argc = 0;

        argv[argc++] = server->xorg_path;
        if (!auto_display) {
            snprintf(display_arg, sizeof(display_arg), ":%d", requested_display);
            argv[argc++] = display_arg;
        }
        argv[argc++] = "-quiet";
        argv[argc++] = "-config";
        argv[argc++] = server->config_path;
        argv[argc++] = "-nolisten";
        argv[argc++] = "tcp";
        argv[argc++] = "-noreset";
        argv[argc++] = "-logfile";
        argv[argc++] = server->log_path;
        if (auto_display) {
            argv[argc++] = "-displayfd";
            argv[argc++] = "99";
        }
        argv[argc] = NULL;

        execv(server->xorg_path, argv);
        _exit(127);
    }

    server->xorg_pid = pid;

    if (auto_display) {
        close(display_pipe[1]);
        int read_result = render_server_wait_for_displayfd(pid, display_pipe[0], &server->display_number);
        close(display_pipe[0]);
        if (read_result != 0) {
            return 1;
        }
    } else {
        server->display_number = requested_display;
    }

    if (snprintf(server->display_name,
                 sizeof(server->display_name),
                 ":%d",
                 server->display_number) >= (int)sizeof(server->display_name)) {
        fprintf(stderr, "[RenderServer] failed to build the display name\n");
        return 1;
    }

    return 0;
}

static xcb_screen_t *render_server_get_screen(xcb_connection_t *connection, int screen_index)
{
    xcb_screen_iterator_t iterator = xcb_setup_roots_iterator(xcb_get_setup(connection));

    for (int i = 0; i < screen_index && iterator.rem > 0; ++i) {
        xcb_screen_next(&iterator);
    }

    return iterator.data;
}

static uint8_t render_server_bits_per_pixel(xcb_connection_t *connection, uint8_t depth)
{
    const xcb_setup_t *setup = xcb_get_setup(connection);
    xcb_format_iterator_t iterator = xcb_setup_pixmap_formats_iterator(setup);

    while (iterator.rem > 0) {
        if (iterator.data->depth == depth) {
            return iterator.data->bits_per_pixel;
        }
        xcb_format_next(&iterator);
    }

    return 0;
}

static int render_server_connect_x11(XServerState *server)
{
    for (int attempt = 0; attempt < 200; ++attempt) {
        int status = 0;
        pid_t waited = waitpid(server->xorg_pid, &status, WNOHANG);
        if (waited == server->xorg_pid) {
            fprintf(stderr, "[RenderServer] Xorg exited while the display was starting\n");
            return 1;
        }

        xcb_connection_t *connection = xcb_connect(server->display_name, &server->screen_index);
        if (connection != NULL && xcb_connection_has_error(connection) == 0) {
            server->connection = connection;
            server->screen = render_server_get_screen(connection, server->screen_index);
            if (server->screen == NULL) {
                fprintf(stderr, "[RenderServer] failed to find the X11 screen\n");
                xcb_disconnect(connection);
                server->connection = NULL;
                return 1;
            }

            server->bits_per_pixel = render_server_bits_per_pixel(connection, server->screen->root_depth);
            if (server->bits_per_pixel != 32) {
                fprintf(stderr,
                        "[RenderServer] unsupported X11 root format: depth=%u bpp=%u\n",
                        server->screen->root_depth,
                        server->bits_per_pixel);
                xcb_disconnect(connection);
                server->connection = NULL;
                return 1;
            }

            if (server->screen->width_in_pixels != server->width ||
                server->screen->height_in_pixels != server->height) {
                fprintf(stderr,
                        "[RenderServer] X11 root geometry mismatch: expected %ux%u, got %ux%u\n",
                        server->width,
                        server->height,
                        server->screen->width_in_pixels,
                        server->screen->height_in_pixels);
                xcb_disconnect(connection);
                server->connection = NULL;
                return 1;
            }

            return 0;
        }

        if (connection != NULL) {
            xcb_disconnect(connection);
        }

        struct timespec wait_time = {
            .tv_sec = 0,
            .tv_nsec = 50 * 1000 * 1000,
        };
        nanosleep(&wait_time, NULL);
    }

    fprintf(stderr, "[RenderServer] failed to connect to the X server on %s\n", server->display_name);
    return 1;
}

static bool render_server_external_wm(void)
{
    const char *val = getenv("RENDER_SERVER_EXTERNAL_WM");
    return val != NULL && val[0] == '1' && val[1] == '\0';
}

static int render_server_claim_window_manager(XServerState *server)
{
    /* When an external WM (e.g. bwm) will manage windows, skip claiming
     * SubstructureRedirect — the external WM will own it instead. */
    if (render_server_external_wm()) {
        fprintf(stdout,
                "[RenderServer] external WM mode: skipping window manager claim on %s\n",
                server->display_name);
        fflush(stdout);
        return 0;
    }

    uint32_t event_mask = XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
                          XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
                          XCB_EVENT_MASK_PROPERTY_CHANGE;

    xcb_void_cookie_t cookie = xcb_change_window_attributes_checked(server->connection,
                                                                    server->screen->root,
                                                                    XCB_CW_EVENT_MASK,
                                                                    &event_mask);
    xcb_generic_error_t *error = xcb_request_check(server->connection, cookie);
    if (error != NULL) {
        if (error->error_code == XCB_ACCESS) {
            fprintf(stderr,
                    "[RenderServer] another X11 window manager is already running on %s\n",
                    server->display_name);
        } else {
            fprintf(stderr,
                    "[RenderServer] failed to select root window events on %s\n",
                    server->display_name);
        }
        free(error);
        return 1;
    }

    xcb_intern_atom_cookie_t atom_cookie = xcb_intern_atom(server->connection, 0, 5, "WM_S0");
    xcb_intern_atom_reply_t *atom_reply = xcb_intern_atom_reply(server->connection, atom_cookie, NULL);
    if (atom_reply != NULL) {
        xcb_set_selection_owner(server->connection,
                                server->screen->root,
                                atom_reply->atom,
                                XCB_CURRENT_TIME);
        free(atom_reply);
    }

    xcb_flush(server->connection);
    return 0;
}

static void render_server_handle_map_request(XServerState *server, const xcb_map_request_event_t *event)
{
    uint32_t border_width = 0;
    xcb_configure_window(server->connection,
                         event->window,
                         XCB_CONFIG_WINDOW_BORDER_WIDTH,
                         &border_width);
    xcb_map_window(server->connection, event->window);
    xcb_set_input_focus(server->connection,
                        XCB_INPUT_FOCUS_POINTER_ROOT,
                        event->window,
                        XCB_CURRENT_TIME);
}

static void render_server_handle_configure_request(XServerState *server,
                                                   const xcb_configure_request_event_t *event)
{
    uint32_t values[7];
    unsigned int count = 0;

    if (event->value_mask & XCB_CONFIG_WINDOW_X) {
        values[count++] = (uint32_t)event->x;
    }
    if (event->value_mask & XCB_CONFIG_WINDOW_Y) {
        values[count++] = (uint32_t)event->y;
    }
    if (event->value_mask & XCB_CONFIG_WINDOW_WIDTH) {
        values[count++] = (uint32_t)event->width;
    }
    if (event->value_mask & XCB_CONFIG_WINDOW_HEIGHT) {
        values[count++] = (uint32_t)event->height;
    }
    if (event->value_mask & XCB_CONFIG_WINDOW_BORDER_WIDTH) {
        values[count++] = (uint32_t)event->border_width;
    }
    if (event->value_mask & XCB_CONFIG_WINDOW_SIBLING) {
        values[count++] = event->sibling;
    }
    if (event->value_mask & XCB_CONFIG_WINDOW_STACK_MODE) {
        values[count++] = event->stack_mode;
    }

    xcb_configure_window(server->connection, event->window, event->value_mask, values);
}

static void render_server_drain_x11_events(XServerState *server)
{
    for (;;) {
        xcb_generic_event_t *event = xcb_poll_for_event(server->connection);
        if (event == NULL) {
            break;
        }

        switch (event->response_type & 0x7F) {
            case XCB_MAP_REQUEST:
                render_server_handle_map_request(server, (const xcb_map_request_event_t *)event);
                break;
            case XCB_CONFIGURE_REQUEST:
                render_server_handle_configure_request(server,
                                                       (const xcb_configure_request_event_t *)event);
                break;
            default:
                break;
        }

        free(event);
    }

    xcb_flush(server->connection);
}

static void render_server_stop_xorg(XServerState *server, bool keep_log)
{
    if (server->connection != NULL) {
        xcb_disconnect(server->connection);
        server->connection = NULL;
    }

    if (server->xorg_pid > 0) {
        kill(server->xorg_pid, SIGTERM);
        for (int attempt = 0; attempt < 20; ++attempt) {
            int status = 0;
            pid_t waited = waitpid(server->xorg_pid, &status, WNOHANG);
            if (waited == server->xorg_pid) {
                server->xorg_pid = -1;
                break;
            }

            struct timespec wait_time = {
                .tv_sec = 0,
                .tv_nsec = 50 * 1000 * 1000,
            };
            nanosleep(&wait_time, NULL);
        }

        if (server->xorg_pid > 0) {
            kill(server->xorg_pid, SIGKILL);
            waitpid(server->xorg_pid, NULL, 0);
            server->xorg_pid = -1;
        }
    }

    if (server->config_path[0] != '\0') {
        unlink(server->config_path);
        server->config_path[0] = '\0';
    }

    if (!keep_log && server->log_path[0] != '\0') {
        unlink(server->log_path);
        server->log_path[0] = '\0';
    }
}

static int render_server_start_xorg(RenderState *state, XServerState *server)
{
    memset(server, 0, sizeof(*server));
    server->xorg_pid = -1;
    server->refresh_hz = RENDER_SERVER_DEFAULT_REFRESH_HZ;
    server->composite_enabled = false;

    if (render_server_find_xorg(server->xorg_path, sizeof(server->xorg_path)) != 0) {
        return 1;
    }

    uint32_t width = (uint32_t)state->surfaceSize.width;
    uint32_t height = (uint32_t)state->surfaceSize.height;
    if (width == 0 || height == 0) {
        fprintf(stderr, "[RenderServer] invalid framebuffer size for Xorg startup\n");
        return 1;
    }

    if (render_server_write_xorg_config(server, width, height) != 0) {
        return 1;
    }

    if (render_server_spawn_xorg(server, render_server_requested_display()) != 0) {
        return 1;
    }

    if (render_server_connect_x11(server) != 0) {
        return 1;
    }

    if (render_server_claim_window_manager(server) != 0) {
        return 1;
    }

    if (render_server_enable_composite(server->connection,
                                        server->screen,
                                        server->display_name,
                                        &server->composite_enabled) != 0) {
        fprintf(stderr, "[RenderServer] continuing with background-only compositing on %s\n",
                server->display_name);
    }

    if (setenv("DISPLAY", server->display_name, 1) != 0) {
        fprintf(stderr, "[RenderServer] failed to export DISPLAY=%s\n", server->display_name);
        return 1;
    }

    fprintf(stdout,
            "[RenderServer] X server ready on %s at %ux%u @ %uHz\n",
            server->display_name,
            server->width,
            server->height,
            server->refresh_hz);
    fflush(stdout);

    return 0;
}

static int render_server_event_loop(RenderState *state,
                                    XServerState *server,
                                    const RenderServerCompositor *compositor)
{
    int x11_fd = xcb_get_file_descriptor(server->connection);
    if (x11_fd < 0) {
        fprintf(stderr, "[RenderServer] failed to get the X11 connection file descriptor\n");
        return 1;
    }

    uint32_t refresh_hz = server->refresh_hz;
    if (refresh_hz == 0) {
        refresh_hz = RENDER_SERVER_DEFAULT_REFRESH_HZ;
    }
    int64_t frame_interval_ns = 1000000000LL / (int64_t)refresh_hz;
    if (frame_interval_ns <= 0) {
        frame_interval_ns = 1000000000LL / RENDER_SERVER_DEFAULT_REFRESH_HZ;
    }

    struct timespec next_frame;
    if (clock_gettime(CLOCK_MONOTONIC, &next_frame) != 0) {
        fprintf(stderr, "[RenderServer] failed to read the monotonic clock: %s\n", strerror(errno));
        return 1;
    }
    render_server_add_ns(&next_frame, frame_interval_ns);

    while (g_render_server_running) {
        struct timespec now;
        if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
            fprintf(stderr, "[RenderServer] failed to read the monotonic clock: %s\n", strerror(errno));
            return 1;
        }

        int timeout_ms = (int)(render_server_timespec_diff_ns(&next_frame, &now) / 1000000LL);
        if (timeout_ms < 0) {
            timeout_ms = 0;
        }

        struct pollfd fd = {
            .fd = x11_fd,
            .events = POLLIN,
            .revents = 0,
        };

        int poll_result = poll(&fd, 1, timeout_ms);
        if (poll_result < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "[RenderServer] polling the X11 connection failed: %s\n", strerror(errno));
            return 1;
        }

        if (poll_result > 0) {
            if ((fd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                fprintf(stderr, "[RenderServer] the X11 connection terminated unexpectedly\n");
                return 1;
            }
            render_server_drain_x11_events(server);
        }

        if (waitpid(server->xorg_pid, NULL, WNOHANG) == server->xorg_pid) {
            fprintf(stderr, "[RenderServer] Xorg exited while the render loop was running\n");
            server->xorg_pid = -1;
            return 1;
        }

        if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
            fprintf(stderr, "[RenderServer] failed to read the monotonic clock: %s\n", strerror(errno));
            return 1;
        }

        if (render_server_timespec_diff_ns(&now, &next_frame) >= 0) {
            if (render_server_compose_frame(state,
                                            server->connection,
                                            server->screen,
                                            compositor,
                                            server->composite_enabled,
                                            server->width,
                                            server->height) != 0) {
                return 1;
            }

            do {
                render_server_add_ns(&next_frame, frame_interval_ns);
            } while (render_server_timespec_diff_ns(&now, &next_frame) >= 0);
        }
    }

    return 0;
}

int render_server_run(void)
{
    RenderState *state = screenproc_create();
    if (state == NULL) {
        fprintf(stderr, "[RenderServer] failed to create framebuffer state\n");
        return 1;
    }

    const char *background_config_path = getenv("BWM_CONFIG");
    RenderServerCompositor *compositor = render_server_compositor_create(background_config_path);
    if (compositor == NULL) {
        fprintf(stderr, "[RenderServer] failed to create the CoreGraphics compositor\n");
        screenproc_destroy(state);
        return 1;
    }

    state->activeDisplays[0] = state->displayInfo;
    state->activeDisplayCount = 1;

    if (render_server_prepare_initial_frame(state, compositor) != 0) {
        render_server_compositor_destroy(compositor);
        screenproc_destroy(state);
        return 1;
    }

    render_server_install_signal_handlers();

    XServerState server;
    bool keep_log = false;
    int result = 0;

    if (render_server_start_xorg(state, &server) != 0) {
        keep_log = true;
        if (server.log_path[0] != '\0') {
            fprintf(stderr, "[RenderServer] Xorg log preserved at %s\n", server.log_path);
        }
        render_server_stop_xorg(&server, keep_log);
        render_server_compositor_destroy(compositor);
        screenproc_destroy(state);
        return 1;
    }

    result = render_server_event_loop(state, &server, compositor);
    if (result != 0) {
        keep_log = true;
        if (server.log_path[0] != '\0') {
            fprintf(stderr, "[RenderServer] Xorg log preserved at %s\n", server.log_path);
        }
    }

    render_server_stop_xorg(&server, keep_log);
    render_server_compositor_destroy(compositor);
    screenproc_destroy(state);
    return result;
}
