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
    FridaDeviceManager *manager = frida_device_manager_new();
    GError *error = NULL;
    FridaDeviceList *devices = frida_device_manager_enumerate_devices_sync(manager, NULL, &error);
    if (error) {
        g_printerr("Failed to enumerate devices: %s\n", error->message);
        return;
    }

    FridaDevice *local_device = NULL;
    for (gint i = 0; i < frida_device_list_size(devices); i++) {
        FridaDevice *device = frida_device_list_get(devices, i);
        if (frida_device_get_dtype(device) == FRIDA_DEVICE_TYPE_LOCAL) {
            local_device = g_object_ref(device);
            break;
        }
    }
    frida_unref(devices);

    if (!local_device) {
        g_printerr("Local device not found\n");
        frida_device_manager_close_sync(manager, NULL, NULL);
        frida_unref(manager);
        return;
    }

    // Find WindowServer
    FridaProcessList *processes = frida_device_enumerate_processes_sync(local_device, NULL, NULL, &error);
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
        frida_unref(local_device);
        frida_device_manager_close_sync(manager, NULL, NULL);
        frida_unref(manager);
        return;
    }

    FridaSession *session = frida_device_attach_sync(local_device, ws_pid, NULL, NULL, &error);
    if (error) {
        g_printerr("Failed to attach to WindowServer (%u): %s\n", ws_pid, error->message);
        frida_unref(local_device);
        frida_device_manager_close_sync(manager, NULL, NULL);
        frida_unref(manager);
        return;
    }

    g_print("Attached to WindowServer (pid %u)\n", ws_pid);

    char *script_source = copy_embedded_script();
    if (!script_source) {
        goto out;
    }

    FridaScript *script = frida_session_create_script_sync(session, script_source, NULL, NULL, &error);
    free(script_source);
    if (error) {
        g_printerr("Failed to create script: %s\n", error->message);
        goto out;
    }

    g_signal_connect(script, "message", G_CALLBACK(on_message), NULL);
    frida_script_load_sync(script, NULL, &error);
    if (error) {
        g_printerr("Failed to load script: %s\n", error->message);
    } else {
        g_print("Script loaded in WindowServer\n");
        // Detach immediately as requested
        frida_script_unload_sync(script, NULL, NULL);
    }
    frida_unref(script);

out:
    frida_session_detach_sync(session, NULL, NULL);
    frida_unref(session);
    frida_unref(local_device);
    frida_device_manager_close_sync(manager, NULL, NULL);
    frida_unref(manager);
}
