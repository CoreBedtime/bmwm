/*
 * AppLaunchRunner.m
 *
 * Frida-backed implementation used by the AppLaunch bootstrapper.
 * This file is intentionally plain C so it does not depend on ObjC runtime
 * initialization before the launch logic runs.
 */

#include <CoreFoundation/CoreFoundation.h>

#include "frida-core.h"

#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <mach-o/getsect.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern char **environ;

static GMainLoop *g_loop = NULL;
static guint g_target_pid = 0;
static gboolean g_target_resumed = FALSE;

int AppLaunchRun(int argc, char *argv[]);

static void log_stage(const char *stage)
{
    char buffer[256];
    int len = snprintf(buffer, sizeof(buffer), "[helper] %s\n", stage);
    if (len > 0) {
        write(STDERR_FILENO, buffer, (size_t) len);
    }
}

static void on_message(FridaScript *script,
                       const gchar *message,
                       const gchar *data,
                       gint data_size,
                       gpointer user_data)
{
    (void)script;
    (void)data;
    (void)data_size;
    (void)user_data;

    g_print("%s\n", message);
}

static gboolean stop_loop(gpointer user_data)
{
    (void)user_data;

    if (g_loop != NULL) {
        g_main_loop_quit(g_loop);
    }

    return G_SOURCE_REMOVE;
}

static gboolean watch_target_process(gpointer user_data)
{
    (void)user_data;

    if (g_target_pid != 0 && kill((pid_t) g_target_pid, 0) == -1 && errno == ESRCH) {
        g_print("[*] Target app exited\n");
        g_idle_add(stop_loop, NULL);
        return G_SOURCE_REMOVE;
    }

    return G_SOURCE_CONTINUE;
}

static void on_signal(int signo)
{
    (void)signo;
    g_idle_add(stop_loop, NULL);
}

static bool path_is_directory(const char *path)
{
    struct stat st;

    if (path == NULL || stat(path, &st) != 0) {
        return false;
    }

    return S_ISDIR(st.st_mode);
}

static bool copy_path_string(const char *source,
                             char *destination,
                             size_t destination_size)
{
    int written = 0;

    if (source == NULL || destination == NULL || destination_size == 0) {
        return false;
    }

    written = snprintf(destination, destination_size, "%s", source);
    return written >= 0 && (size_t) written < destination_size;
}

static bool copy_resolved_executable_path(const char *target_path,
                                          char *executable_path,
                                          size_t executable_path_size)
{
    bool ok = false;
    char *resolved = NULL;
    const char *source_path = target_path;

    if (target_path == NULL || *target_path == '\0') {
        return false;
    }

    resolved = realpath(target_path, NULL);
    if (resolved != NULL) {
        source_path = resolved;
    }

    if (access(source_path, X_OK) != 0) {
        goto out;
    }

    ok = copy_path_string(source_path, executable_path, executable_path_size);

out:
    if (resolved != NULL) {
        free(resolved);
    }
    return ok;
}

static bool copy_path_lookup_executable(const char *target_name,
                                        char *executable_path,
                                        size_t executable_path_size)
{
    bool ok = false;
    char *path_copy = NULL;
    char *cursor = NULL;
    char *entry = NULL;
    const char *path_env = getenv("PATH");

    if (target_name == NULL || *target_name == '\0') {
        return false;
    }

    if (strchr(target_name, '/') != NULL) {
        return copy_resolved_executable_path(target_name,
                                             executable_path,
                                             executable_path_size);
    }

    if (path_env == NULL || *path_env == '\0') {
        path_env = "/usr/bin:/bin:/usr/sbin:/sbin";
    }

    path_copy = strdup(path_env);
    if (path_copy == NULL) {
        return false;
    }

    cursor = path_copy;
    while ((entry = strsep(&cursor, ":")) != NULL) {
        char candidate[PATH_MAX];
        const char *dir = (*entry == '\0') ? "." : entry;
        int written = snprintf(candidate, sizeof(candidate), "%s/%s", dir, target_name);
        if (written < 0 || (size_t) written >= sizeof(candidate)) {
            continue;
        }

        if (!copy_resolved_executable_path(candidate,
                                           executable_path,
                                           executable_path_size)) {
            continue;
        }

        ok = true;
        break;
    }

    free(path_copy);
    return ok;
}

static bool copy_bundle_executable_path(const char *bundle_path,
                                        char *executable_path,
                                        size_t executable_path_size)
{
    bool ok = false;
    CFURLRef bundle_url = NULL;
    CFBundleRef bundle = NULL;
    CFURLRef executable_url = NULL;

    bundle_url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
                                                         (const UInt8 *) bundle_path,
                                                         (CFIndex) strlen(bundle_path),
                                                         true);
    if (bundle_url == NULL) {
        goto out;
    }

    bundle = CFBundleCreate(kCFAllocatorDefault, bundle_url);
    if (bundle == NULL) {
        goto out;
    }

    executable_url = CFBundleCopyExecutableURL(bundle);
    if (executable_url == NULL) {
        goto out;
    }

    if (!CFURLGetFileSystemRepresentation(executable_url,
                                          true,
                                          (UInt8 *) executable_path,
                                          (CFIndex) executable_path_size)) {
        goto out;
    }

    ok = true;

out:
    if (executable_url != NULL) {
        CFRelease(executable_url);
    }
    if (bundle != NULL) {
        CFRelease(bundle);
    }
    if (bundle_url != NULL) {
        CFRelease(bundle_url);
    }
    return ok;
}

static bool copy_target_executable_path(const char *target_path,
                                        char *executable_path,
                                        size_t executable_path_size)
{
    if (path_is_directory(target_path)) {
        if (copy_bundle_executable_path(target_path,
                                        executable_path,
                                        executable_path_size)) {
            return true;
        }
    }

    return copy_path_lookup_executable(target_path,
                                       executable_path,
                                       executable_path_size);
}

static bool find_target_pid(FridaDevice *device, const char *executable_name, guint *pid_out)
{
    GError *error = NULL;
    FridaProcessList *processes = NULL;
    gint num_processes = 0;

    processes = frida_device_enumerate_processes_sync(device, NULL, NULL, &error);
    if (error != NULL) {
        g_printerr("Failed to enumerate processes: %s\n", error->message);
        g_error_free(error);
        return false;
    }

    num_processes = frida_process_list_size(processes);
    for (gint i = 0; i != num_processes; i++) {
        FridaProcess *process = frida_process_list_get(processes, i);
        const gchar *process_name = frida_process_get_name(process);

        if (g_strcmp0(process_name, executable_name) == 0) {
            if (pid_out != NULL) {
                *pid_out = frida_process_get_pid(process);
            }
            frida_unref(processes);
            return true;
        }
    }

    frida_unref(processes);
    return false;
}

static bool copy_target_pid_from_env(guint *pid_out)
{
    const char *pid_text = getenv("APP_LAUNCH_TARGET_PID");
    char *end = NULL;
    unsigned long parsed = 0;

    if (pid_text == NULL || *pid_text == '\0') {
        return false;
    }

    errno = 0;
    parsed = strtoul(pid_text, &end, 10);
    if (errno != 0 || end == pid_text || *end != '\0' || parsed == 0 || parsed > UINT_MAX) {
        return false;
    }

    if (pid_out != NULL) {
        *pid_out = (guint) parsed;
    }
    return true;
}

static char *copy_embedded_script(void)
{
    Dl_info info;
    unsigned long script_size = 0;
    const char *script_data = NULL;
    char *script_source = NULL;

    memset(&info, 0, sizeof(info));
    if (dladdr((const void *) &AppLaunchRun, &info) == 0 || info.dli_fbase == NULL) {
        g_printerr("Failed to locate embedded script image\n");
        return NULL;
    }

    script_data = (const char *) getsectiondata((const struct mach_header_64 *) info.dli_fbase,
                                                "__TEXT",
                                                "__app_launch_js",
                                                &script_size);
    if (script_data == NULL || script_size == 0) {
        g_printerr("Failed to locate embedded script section\n");
        return NULL;
    }

    script_source = malloc((size_t) script_size + 1);
    if (script_source == NULL) {
        g_printerr("Failed to allocate embedded script buffer\n");
        return NULL;
    }

    memcpy(script_source, script_data, (size_t) script_size);
    script_source[script_size] = '\0';
    return script_source;
}

static gboolean resume_target_process(FridaDevice *device)
{
    if (g_target_resumed || g_target_pid == 0) {
        g_print("[helper] resume skipped: target already resumed or pid unset\n");
        return TRUE;
    }

    gboolean resumed = FALSE;

    g_print("[helper] attempting SIGCONT for pid %u\n", g_target_pid);
    if (kill((pid_t) g_target_pid, SIGCONT) == 0) {
        resumed = TRUE;
        g_print("[helper] SIGCONT accepted for pid %u\n", g_target_pid);
    } else {
        g_printerr("Failed to send SIGCONT to target process %u: %s\n",
                   g_target_pid,
                   strerror(errno));
    }

    if (device != NULL) {
        GError *error = NULL;

        g_print("[helper] attempting Frida device resume for pid %u\n", g_target_pid);
        frida_device_resume_sync(device, g_target_pid, NULL, &error);
        if (error != NULL) {
            g_printerr("Frida resume for target process %u reported: %s\n",
                       g_target_pid,
                       error->message);
            g_error_free(error);
        } else {
            resumed = TRUE;
            g_print("[helper] Frida resume accepted for pid %u\n", g_target_pid);
        }
    }

    if (!resumed) {
        return FALSE;
    }

    g_target_resumed = TRUE;
    g_print("[*] Resumed target process %u\n", g_target_pid);
    return TRUE;
}

__attribute__((visibility("default")))
int AppLaunchRun(int argc, char *argv[])
{
    FridaDeviceManager *manager = NULL;
    FridaDeviceList *devices = NULL;
    FridaDevice *local_device = NULL;
    FridaSession *session = NULL;
    FridaScript *script = NULL;
    GError *error = NULL;
    char executable_path[PATH_MAX];
    char *executable_name = NULL;
    char *script_source = NULL;
    gboolean session_attached = FALSE;
    gboolean script_loaded = FALSE;
    int exit_code = 0;
    gint num_devices = 0;
    gint i = 0;

    fprintf(stderr, "[helper] entered AppLaunchRun argc=%d\n", argc);

    if (argc < 2) {
        fprintf(stderr,
                "Usage: %s /path/to/App.app|/path/to/executable [target-args...]\n",
                argv[0]);
        return 1;
    }

    log_stage("step 1: resolving target executable path");
    if (!copy_target_executable_path(argv[1], executable_path, sizeof(executable_path))) {
        g_printerr("Failed to resolve launch target executable path for: %s\n", argv[1]);
        return 1;
    }

    log_stage("step 2: reading target pid from environment");
    if (!copy_target_pid_from_env(&g_target_pid)) {
        g_print("[helper] APP_LAUNCH_TARGET_PID is unset, falling back to process lookup\n");
    }

    executable_name = strrchr(executable_path, '/');
    if (executable_name != NULL) {
        executable_name++;
    } else {
        executable_name = executable_path;
    }

    frida_init();

    log_stage("step 3: creating Frida device manager");
    manager = frida_device_manager_new();

    log_stage("step 4: enumerating devices");
    devices = frida_device_manager_enumerate_devices_sync(manager, NULL, &error);
    if (error != NULL) {
        g_printerr("Failed to enumerate devices: %s\n", error->message);
        g_error_free(error);
        error = NULL;
        exit_code = 1;
        goto out;
    }

    num_devices = frida_device_list_size(devices);
    for (i = 0; i != num_devices; i++) {
        FridaDevice *device = frida_device_list_get(devices, i);
        const gchar *device_name = frida_device_get_name(device);

        g_print("[*] Found device: \"%s\"\n", device_name);
        if (frida_device_get_dtype(device) == FRIDA_DEVICE_TYPE_LOCAL) {
            if (g_strcmp0(device_name, "Local System") == 0) {
                if (local_device != NULL) {
                    frida_unref(local_device);
                }
                local_device = g_object_ref(device);
            } else if (local_device == NULL) {
                local_device = g_object_ref(device);
            }
        }
    }

    if (local_device == NULL) {
        g_printerr("No local device was found\n");
        exit_code = 1;
        goto out;
    }

    log_stage("step 5: selecting local device");
    if (g_target_pid == 0) {
        log_stage("step 6: polling for launched process");
        for (gint attempt = 0; attempt < 100; attempt++) {
            if (find_target_pid(local_device, executable_name, &g_target_pid)) {
                break;
            }

            g_usleep(100000);
        }
    }

    if (g_target_pid == 0) {
        g_printerr("Failed to find launched app process: %s\n", executable_name);
        exit_code = 1;
        goto out;
    }

    g_print("[*] Found process pid %u\n", g_target_pid);

    log_stage("step 7: attaching to target process");
    session = frida_device_attach_sync(local_device, g_target_pid, NULL, NULL, &error);
    if (error != NULL) {
        g_printerr("Failed to attach to pid %u: %s\n", g_target_pid, error->message);
        g_error_free(error);
        error = NULL;
        exit_code = 1;
        goto out;
    }

    g_print("[*] Attached to pid %u\n", g_target_pid);
    session_attached = TRUE;

    log_stage("step 8: loading embedded Frida script data");
    script_source = copy_embedded_script();
    if (script_source == NULL) {
        exit_code = 1;
        goto out;
    }

    log_stage("step 9: creating Frida script");
    script = frida_session_create_script_sync(session,
                                             script_source,
                                             NULL,
                                             NULL,
                                             &error);
    free(script_source);
    script_source = NULL;
    if (error != NULL) {
        g_printerr("Failed to create script: %s\n", error->message);
        g_error_free(error);
        error = NULL;
        exit_code = 1;
        goto out;
    }

    g_signal_connect(script, "message", G_CALLBACK(on_message), NULL);

    log_stage("step 10: loading Frida script");
    frida_script_load_sync(script, NULL, &error);
    if (error != NULL) {
        g_printerr("Failed to load script: %s\n", error->message);
        g_error_free(error);
        error = NULL;
        exit_code = 1;
        goto out;
    }

    g_print("[*] Script loaded\n");
    script_loaded = TRUE;

    log_stage("step 11: resuming target process");
    if (!resume_target_process(local_device)) {
        exit_code = 1;
        goto out;
    }

    log_stage("step 12: entering main loop");
    g_timeout_add_seconds(1, watch_target_process, NULL);
    g_loop = g_main_loop_new(NULL, FALSE);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    g_main_loop_run(g_loop);

out:
    log_stage("cleanup: unwinding helper state");
    if (error != NULL) {
        g_error_free(error);
    }
    if (script_source != NULL) {
        free(script_source);
    }

    resume_target_process(local_device);

    if (script != NULL) {
        if (script_loaded) {
            frida_script_unload_sync(script, NULL, NULL);
        }
        frida_unref(script);
    }

    if (session != NULL) {
        if (session_attached) {
            frida_session_detach_sync(session, NULL, NULL);
        }
        frida_unref(session);
    }

    if (local_device != NULL) {
        frida_unref(local_device);
    }

    if (devices != NULL) {
        frida_unref(devices);
    }

    if (manager != NULL) {
        frida_device_manager_close_sync(manager, NULL, NULL);
        frida_unref(manager);
    }

    if (g_loop != NULL) {
        g_main_loop_unref(g_loop);
        g_loop = NULL;
    }

    return exit_code;
}
