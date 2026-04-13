#include <CoreFoundation/CoreFoundation.h>
#include "frida-core.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <mach-o/getsect.h>
#include <libproc.h>
#include <sys/socket.h>
#include <sys/un.h>

static void on_message(FridaScript *script, const gchar *message, const gchar *data, gint data_size, gpointer user_data) {
    g_print("[frida] %s\n", message);

    // Communicate with ApplicationServer over the focus socket
    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0) return;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, "/tmp/applicator_focus.sock", sizeof(addr.sun_path) - 1);

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        send(sock, message, strlen(message), 0);
    }
    close(sock);
}

static FridaDeviceManager *g_manager = NULL;
static FridaDevice *g_local_device = NULL;
static FridaSession *g_session = NULL;
static FridaScript *g_script = NULL;
static int g_loader_sock = -1;

static void handle_focus_update(int sock) {
    char buffer[1024];
    ssize_t n = recv(sock, buffer, sizeof(buffer) - 1, 0);
    if (n > 0) {
        buffer[n] = '\0';
        g_print("[loader] Received focus update: %s\n", buffer);
        if (g_script != NULL) {
            GError *error = NULL;
            char *json = g_strdup_printf("{\"type\": \"focus\", \"payload\": \"%s\"}", buffer);
            frida_script_post(g_script, json, NULL);
            g_free(json);
        } else {
            g_print("[loader] Script not ready yet\n");
        }
    }
}

static gpointer loader_socket_thread(gpointer data) {
    unlink("/tmp/applicator_loader.sock");
    g_loader_sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (g_loader_sock < 0) return NULL;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, "/tmp/applicator_loader.sock", sizeof(addr.sun_path) - 1);

    if (bind(g_loader_sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(g_loader_sock);
        return NULL;
    }
    listen(g_loader_sock, 5);

    while (TRUE) {
        int client = accept(g_loader_sock, NULL, NULL);
        if (client >= 0) {
            handle_focus_update(client);
            close(client);
        }
    }
    return NULL;
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

static guint find_windowserver_pid(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t buf_size;
    if (sysctl(mib, 4, NULL, &buf_size, NULL, 0) != 0) {
        fprintf(stderr, "[respawn_headless] Failed to get proc list size: %s\n", strerror(errno));
    } else {
        struct kinfo_proc *procs = malloc(buf_size);
        if (procs && sysctl(mib, 4, procs, &buf_size, NULL, 0) == 0) {
            int num_procs = buf_size / sizeof(struct kinfo_proc);
            for (int i = 0; i < num_procs; i++) {
                if (strcmp(procs[i].kp_proc.p_comm, "WindowServer") == 0) {
                    return (guint)procs[i].kp_proc.p_pid;
                    break;
                }
            }
        }
        free(procs);
    }
    return 0;
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

    // Find WindowServer using libproc
    guint ws_pid = find_windowserver_pid();

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
        g_thread_new("loader-socket", loader_socket_thread, NULL);
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
