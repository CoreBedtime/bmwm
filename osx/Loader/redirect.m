#include <CoreFoundation/CoreFoundation.h>
#include "frida-core.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <dlfcn.h>
#include <mach-o/getsect.h>

static void on_message(FridaScript *script, const gchar *message, const gchar *data, gint data_size, gpointer user_data) {
    g_print("[frida] %s\n", message);
}

static FridaDeviceManager *g_manager = NULL;
static FridaDevice *g_local_device = NULL;
static FridaSession *g_session = NULL;
static FridaScript *g_script = NULL;

void run_windowserver_init(void);

static char *copy_embedded_script(void) {
    Dl_info info;
    unsigned long script_size = 0;
    const char *script_data = NULL;
    char *script_source = NULL;

    memset(&info, 0, sizeof(info));
    if (dladdr((const void *) &run_windowserver_init, &info) == 0 || info.dli_fbase == NULL) {
        g_printerr("Failed to locate embedded script image\n");
        return NULL;
    }

    script_data = (const char *) getsectiondata((const struct mach_header_64 *) info.dli_fbase,
                                                "__TEXT",
                                                "__loader_js",
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

void run_windowserver_init(void) {
    frida_init();
    g_manager = frida_device_manager_new();
    GError *error = NULL;
    FridaDeviceList *devices = frida_device_manager_enumerate_devices_sync(g_manager, NULL, &error);
    if (error) {
        g_printerr("Failed to enumerate devices: %s\n", error->message);
        return;
    }

    for (gint i = 0; i < frida_device_list_size(devices); i++) {
        FridaDevice *device = frida_device_list_get(devices, i);
        if (frida_device_get_dtype(device) == FRIDA_DEVICE_TYPE_LOCAL) {
            g_local_device = g_object_ref(device);
            break;
        }
    }
    frida_unref(devices);

    if (!g_local_device) {
        g_printerr("Local device not found\n");
        return;
    }

    // Find WindowServer
    FridaProcessList *processes = frida_device_enumerate_processes_sync(g_local_device, NULL, NULL, &error);
    guint ws_pid = 0;
    for (gint i = 0; i < frida_process_list_size(processes); i++) {
        FridaProcess *process = frida_process_list_get(processes, i);
        if (g_strcmp0(frida_process_get_name(process), "WindowServer") == 0) {
            ws_pid = frida_process_get_pid(process);
            break;
        }
    }
    frida_unref(processes);

    if (ws_pid == 0) {
        g_printerr("WindowServer not found\n");
        return;
    }

    g_session = frida_device_attach_sync(g_local_device, ws_pid, NULL, NULL, &error);
    if (error) {
        g_printerr("Failed to attach to WindowServer (%u): %s\n", ws_pid, error->message);
        return;
    }

    g_print("Attached to WindowServer (pid %u)\n", ws_pid);

    char *script_source = copy_embedded_script();
    if (!script_source) {
        return;
    }

    g_script = frida_session_create_script_sync(g_session, script_source, NULL, NULL, &error);
    free(script_source);
    if (error) {
        g_printerr("Failed to create script: %s\n", error->message);
        return;
    }

    g_signal_connect(g_script, "message", G_CALLBACK(on_message), NULL);
    frida_script_load_sync(g_script, NULL, &error);
    if (error) {
        g_printerr("Failed to load script: %s\n", error->message);
    } else {
        g_print("Script loaded in WindowServer\n");
    }
}

void run_windowserver_cleanup(void) {
    if (g_script != NULL) {
        frida_script_unload_sync(g_script, NULL, NULL);
        frida_unref(g_script);
        g_script = NULL;
    }

    if (g_session != NULL) {
        frida_session_detach_sync(g_session, NULL, NULL);
        frida_unref(g_session);
        g_session = NULL;
    }

    if (g_local_device != NULL) {
        frida_unref(g_local_device);
        g_local_device = NULL;
    }

    if (g_manager != NULL) {
        frida_device_manager_close_sync(g_manager, NULL, NULL);
        frida_unref(g_manager);
        g_manager = NULL;
    }
}
