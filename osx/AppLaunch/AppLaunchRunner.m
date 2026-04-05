/*
 * AppLaunchRunner.m
 *
 * Frida-backed implementation used by the AppLaunch bootstrapper.
 * This file is intentionally plain C so it does not depend on ObjC runtime
 * initialization before the launch logic runs.
 */

#include <CoreFoundation/CoreFoundation.h>

#include "frida-core.h"

#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

static GMainLoop *g_loop = NULL;
static guint g_target_pid = 0;

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

static bool copy_executable_path(const char *bundle_path,
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
    gboolean session_attached = FALSE;
    gboolean script_loaded = FALSE;
    int exit_code = 0;
    gint num_devices = 0;
    gint i = 0;

    fprintf(stderr, "[helper] entered AppLaunchRun argc=%d\n", argc);

    if (argc < 2) {
        fprintf(stderr, "Usage: %s /path/to/App.app [app-args...]\n", argv[0]);
        return 1;
    }

    if (!copy_executable_path(argv[1], executable_path, sizeof(executable_path))) {
        g_printerr("Failed to resolve executable path for: %s\n", argv[1]);
        return 1;
    }

    executable_name = strrchr(executable_path, '/');
    if (executable_name != NULL) {
        executable_name++;
    } else {
        executable_name = executable_path;
    }

    frida_init();

    fprintf(stderr, "[helper] creating device manager\n");
    manager = frida_device_manager_new();

    fprintf(stderr, "[helper] enumerating devices\n");
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

    fprintf(stderr, "[helper] polling for launched process\n");
    for (gint attempt = 0; attempt < 100; attempt++) {
        if (find_target_pid(local_device, executable_name, &g_target_pid)) {
            break;
        }

        g_usleep(100000);
    }

    if (g_target_pid == 0) {
        g_printerr("Failed to find launched app process: %s\n", executable_name);
        exit_code = 1;
        goto out;
    }

    g_print("[*] Found process pid %u\n", g_target_pid);

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

    script = frida_session_create_script_sync(session,
                                             "function resolveExport(name) {\n"
                                             "  if (typeof Module.getGlobalExportByName === 'function') {\n"
                                             "    return Module.getGlobalExportByName(name);\n"
                                             "  }\n"
                                             "  if (typeof Module.findExportByName === 'function') {\n"
                                             "    return Module.findExportByName(null, name);\n"
                                             "  }\n"
                                             "  throw new Error('No export lookup function available');\n"
                                             "}\n"
                                             "var openPtr = resolveExport('open');\n"
                                             "if (openPtr !== null) {\n"
                                             "  Interceptor.attach(openPtr, {\n"
                                             "    onEnter: function (args) {\n"
                                             "      var path = '<unavailable>';\n"
                                             "      try {\n"
                                             "        path = args[0].readUtf8String();\n"
                                             "      } catch (e) {\n"
                                             "        path = '<error: ' + e + '>';\n"
                                             "      }\n"
                                             "      console.log('[*] open(\"' + path + '\")');\n"
                                             "    }\n"
                                             "  });\n"
                                             "}\n"
                                             "var closePtr = resolveExport('close');\n"
                                             "if (closePtr !== null) {\n"
                                             "  Interceptor.attach(closePtr, {\n"
                                             "    onEnter: function (args) {\n"
                                             "      console.log('[*] close(' + args[0].toInt32() + ')');\n"
                                             "    }\n"
                                             "  });\n"
                                             "}",
                                             NULL,
                                             NULL,
                                             &error);
    if (error != NULL) {
        g_printerr("Failed to create script: %s\n", error->message);
        g_error_free(error);
        error = NULL;
        exit_code = 1;
        goto out;
    }

    g_signal_connect(script, "message", G_CALLBACK(on_message), NULL);

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

    g_timeout_add_seconds(1, watch_target_process, NULL);
    g_loop = g_main_loop_new(NULL, FALSE);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    g_main_loop_run(g_loop);

out:
    if (error != NULL) {
        g_error_free(error);
    }

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
