#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>
#include <xpc/xpc.h>

#include "launch-wrangler.h"

/*
 * Inline the small bit of private libxpc state this helper needs so the
 * source stays self-contained.
 */
#define OS_ALLOC_ONCE_KEY_LIBXPC 1

struct xpc_global_data {
	uint64_t a;
	uint64_t xpc_flags;
	mach_port_t task_bootstrap_port;
#if !defined(__LP64__)
	uint32_t padding;
#endif
	xpc_object_t xpc_bootstrap_pipe;
};

struct _os_alloc_once_s {
	long once;
	void *ptr;
};

extern struct _os_alloc_once_s _os_alloc_once_table[];

typedef xpc_object_t xpc_pipe_t;

typedef void (*xpc_dictionary_applier_f)(const char *key, xpc_object_t val, void *ctx);

extern int xpc_pipe_routine(xpc_pipe_t pipe, xpc_object_t message, xpc_object_t *reply);
extern int _xpc_pipe_interface_routine(xpc_pipe_t pipe, uint64_t routine, xpc_object_t message,
    xpc_object_t *reply, uint64_t flags);
extern void xpc_dictionary_apply_f(xpc_object_t xdict, void *ctx, xpc_dictionary_applier_f applier);
extern const char *xpc_strerror(int err);

enum {
	XPC_ROUTINE_LIST = 815,
	XPC_ROUTINE_REMOVE = 816,
	ENOSERVICE = 113,
	EBADRESP = 118,
};

static int launchctl_send_xpc_to_launchd(uint64_t routine, xpc_object_t msg, xpc_object_t* reply) {
    xpc_object_t bootstrap_pipe =
        ((struct xpc_global_data*)_os_alloc_once_table[OS_ALLOC_ONCE_KEY_LIBXPC].ptr)->xpc_bootstrap_pipe;

    xpc_dictionary_set_uint64(msg, "subsystem", routine >> 8);
    xpc_dictionary_set_uint64(msg, "routine", routine);

    int ret = 0;
    if (__builtin_available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, bridgeOS 6.0, *)) {
        ret = _xpc_pipe_interface_routine(bootstrap_pipe, 0, msg, reply, 0);
    } else {
        ret = xpc_pipe_routine(bootstrap_pipe, msg, reply);
    }

    if (ret == 0 && (ret = xpc_dictionary_get_int64(*reply, "error")) == 0)
        return 0;

    return ret;
}

static void launchctl_setup_xpc_dict(xpc_object_t dict) {
    if (__builtin_available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, bridgeOS 6.0, *)) {
        xpc_dictionary_set_uint64(dict, "type", 7);
    } else {
        xpc_dictionary_set_uint64(dict, "type", 1);
    }
    xpc_dictionary_set_uint64(dict, "handle", 0);
}

static bool matches_amfi(const char* text) {
    return text != NULL &&
           (strstr(text, "MobileFileIntegrity") != NULL || strstr(text, "amfid") != NULL || strstr(text, "amfi") != NULL);
}

static bool service_should_keep(const char* label, xpc_object_t service) {
    if (matches_amfi(label))
        return true;

    static const char* const fields[] = {
        "name", "label", "program", "path", "executable", "binary", NULL,
    };

    for (const char* const* field = fields; *field != NULL; field++) {
        const char* value = xpc_dictionary_get_string(service, *field);
        if (matches_amfi(value))
            return true;
    }

    return false;
}

struct service_list {
    const char** items;
    size_t       count;
    size_t       capacity;
    bool         failed;
};

static void service_list_append(struct service_list* list, const char* name) {
    if (list->failed)
        return;

    if (list->count == list->capacity) {
        size_t       new_capacity = list->capacity == 0 ? 16 : list->capacity * 2;
        const char** items        = realloc(list->items, new_capacity * sizeof(*items));
        if (items == NULL) {
            fprintf(stderr, "[MainUserspace] out of memory while collecting services\n");
            list->failed = true;
            return;
        }

        list->items    = items;
        list->capacity = new_capacity;
    }

    list->items[list->count++] = name;
}

static void collect_service_name(const char* label, xpc_object_t value, void* context) {
    struct service_list* list = context;
    if (list->failed)
        return;
    if (value == NULL || xpc_get_type(value) != XPC_TYPE_DICTIONARY)
        return;
    if (service_should_keep(label, value))
        return;

    service_list_append(list, label);
}

static int remove_service_by_name(const char* name) {
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t reply   = NULL;

    if (request == NULL)
        return ENOMEM;

    launchctl_setup_xpc_dict(request);
    xpc_dictionary_set_string(request, "name", name);

    int ret = launchctl_send_xpc_to_launchd(XPC_ROUTINE_REMOVE, request, &reply);
    if (reply != NULL)
        xpc_release(reply);
    xpc_release(request);
    return ret;
}

int launch_wrangler_main(void) {
    xpc_object_t        request   = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t        reply     = NULL;
    struct service_list removals  = {0};
    int                 ret       = 0;
    bool                had_error = false;

    if (request == NULL) {
        fprintf(stderr, "[MainUserspace] failed to allocate launchd request\n");
        return 1;
    }

    launchctl_setup_xpc_dict(request);

    ret = launchctl_send_xpc_to_launchd(XPC_ROUTINE_LIST, request, &reply);
    if (ret != 0) {
        fprintf(stderr, "[MainUserspace] failed to list launchd services: %d: %s\n", ret, xpc_strerror(ret));
        goto out;
    }

    xpc_object_t services = xpc_dictionary_get_value(reply, "services");
    if (services == NULL || xpc_get_type(services) != XPC_TYPE_DICTIONARY) {
        fprintf(stderr, "[MainUserspace] launchd returned an invalid services dictionary\n");
        ret = EBADRESP;
        goto out;
    }

    xpc_dictionary_apply_f(services, &removals, collect_service_name);
    if (removals.failed) {
        ret = ENOMEM;
        goto out;
    }

    for (size_t i = 0; i < removals.count; i++) {
        int remove_ret = remove_service_by_name(removals.items[i]);
        if (remove_ret == 0 || remove_ret == ENOSERVICE)
            continue;

        had_error = true;
        fprintf(stderr, "[MainUserspace] remove %s: %d: %s\n", removals.items[i], remove_ret, xpc_strerror(remove_ret));
    }

out:
    free(removals.items);
    if (reply != NULL)
        xpc_release(reply);
    xpc_release(request);
    return (ret == 0 && !had_error) ? 0 : 1;
}
