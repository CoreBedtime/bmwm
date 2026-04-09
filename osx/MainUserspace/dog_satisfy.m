#import <Foundation/Foundation.h>
#import <os/log.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <stdatomic.h>

typedef kern_return_t (*wd_endpoint_register_t)(const char *name);
typedef kern_return_t (*wd_endpoint_set_alive_func_t)(id callback);
typedef kern_return_t (*wd_endpoint_activate_t)(void);

static atomic_int initialization_complete = 0;
static atomic_int stuck_reports = 0;
static os_log_t log_obj;

static void *watchdog_lib = NULL;
static wd_endpoint_register_t wd_register = NULL;
static wd_endpoint_set_alive_func_t wd_set_alive = NULL;
static wd_endpoint_activate_t wd_activate = NULL;

static int load_watchdog_functions(void) {
    watchdog_lib = dlopen("/System/Library/PrivateFrameworks/WatchdogClient.framework/WatchdogClient", RTLD_LAZY);
    if (!watchdog_lib) {
        os_log(log_obj, "Failed to load libwatchdog: %s", dlerror());
        return 0;
    }

    wd_register = (wd_endpoint_register_t)dlsym(watchdog_lib, "wd_endpoint_register");
    wd_set_alive = (wd_endpoint_set_alive_func_t)dlsym(watchdog_lib, "wd_endpoint_set_alive_func");
    wd_activate = (wd_endpoint_activate_t)dlsym(watchdog_lib, "wd_endpoint_activate");

    if (!wd_register || !wd_set_alive || !wd_activate) {
        os_log(log_obj, "Failed to find watchdog functions: %s", dlerror());
        dlclose(watchdog_lib);
        watchdog_lib = NULL;
        return 0;
    }

    return 1;
}

static int alive_callback(char **out_triage_info) {
    if (!atomic_load(&initialization_complete)) {
        if (out_triage_info) {
            asprintf(out_triage_info, "dog_satisfy: initialization not complete");
        }
        os_log(log_obj, "alive_callback: not initialized, returning stuck");
        return 1;
    }

    if (atomic_load(&stuck_reports) > 0) {
        if (out_triage_info) {
            asprintf(out_triage_info, "dog_satisfy: stuck reports present (%d)",
                     atomic_load(&stuck_reports));
        }
        os_log(log_obj, "alive_callback: stuck, returning stuck");
        return 1;
    }

    os_log_debug(log_obj, "alive_callback: alive");
    return 0;
}

void dog_satisfy_start(void) {
    log_obj = os_log_create("com.applicator.dogsatisfy", "watchdog");

    os_log(log_obj, "dog_satisfy starting");

    if (!load_watchdog_functions()) {
        os_log(log_obj, "Failed to load watchdog functions");
        return;
    }

    os_log(log_obj, "Watchdog functions loaded successfully");

    kern_return_t kr = wd_register("com.apple.applicator.dogsatisfy");
    if (kr != KERN_SUCCESS) {
        os_log(log_obj, "wd_endpoint_register failed: 0x%x", kr);
        return;
    }

    typedef int (^alive_block_t)(char **);
    alive_block_t callback = ^(char ** triage_info) {
        return alive_callback(triage_info);
    };

    kr = wd_set_alive(callback);
    if (kr != KERN_SUCCESS) {
        os_log(log_obj, "wd_endpoint_set_alive_func failed: 0x%x", kr);
        return;
    }

    kr = wd_activate();
    if (kr != KERN_SUCCESS) {
        os_log(log_obj, "wd_endpoint_activate failed: 0x%x", kr);
        return;
    }

    atomic_store(&initialization_complete, 1);
    os_log(log_obj, "dog_satisfy activated with watchdogd");
}
