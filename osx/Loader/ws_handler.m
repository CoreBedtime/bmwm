#import <Foundation/Foundation.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <string.h>

/* ── CoreSymbolication Definitions ──────────────────────────────────────── */

struct sCSTypeRef {
    void* csCppData;
    void* csCppObj;
};
typedef struct sCSTypeRef CSTypeRef;

typedef CSTypeRef CSSymbolicatorRef;
typedef CSTypeRef CSSymbolOwnerRef;
typedef CSTypeRef CSSymbolRef;

struct sCSRange {
   unsigned long long location;
   unsigned long long length;
};
typedef struct sCSRange CSRange;

#define kCSNow 0x80000000u

extern CSSymbolicatorRef CSSymbolicatorCreateWithTask(task_t task);
extern CSSymbolOwnerRef CSSymbolicatorGetSymbolOwnerWithNameAtTime(CSSymbolicatorRef cs, const char* name, uint64_t time);
extern CSSymbolRef CSSymbolOwnerGetSymbolWithName(CSSymbolOwnerRef owner, const char* name);
extern CSRange CSSymbolGetRange(CSSymbolRef sym);
extern Boolean CSIsNull(CSTypeRef cs);
extern void CSRelease(CSTypeRef cs);

/* ── find WindowServer's PID ────────────────────────────────────────────── */

static pid_t
find_windowserver_pid(void)
{
    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0) / sizeof(pid_t);
    pid_t *pids = calloc(n, sizeof(pid_t));
    n = proc_listpids(PROC_ALL_PIDS, 0, pids, n * sizeof(pid_t)) / sizeof(pid_t);

    pid_t result = -1;
    for (int i = 0; i < n; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pids[i], path, sizeof(path)) > 0) {
            char *last_slash = strrchr(path, '/');
            if (last_slash && strcmp(last_slash, "/WindowServer") == 0) {
                result = pids[i];
                break;
            }
        }
    }
    free(pids);
    return result;
}

static mach_vm_address_t gWSDeviceList_addr = 0;
static uint64_t saved_gWSDeviceList = 0;
static task_t ws_task = MACH_PORT_NULL;

void find_gWSDeviceList(void) {
    pid_t pid = find_windowserver_pid();
    if (pid < 0) {
        printf("[ws_handler] WindowServer not found\n");
        return;
    }
    printf("[ws_handler] Found WindowServer at PID %d\n", pid);

    kern_return_t kr = task_for_pid(mach_task_self(), (int)pid, &ws_task);
    if (kr != KERN_SUCCESS) {
        printf("[ws_handler] task_for_pid(%d): %s\n", pid, mach_error_string(kr));
        return;
    }

    CSSymbolicatorRef symbolicator = CSSymbolicatorCreateWithTask(ws_task);
    if (CSIsNull(symbolicator)) {
        printf("[ws_handler] Failed to create symbolicator\n");
        return;
    }

    CSSymbolOwnerRef owner = CSSymbolicatorGetSymbolOwnerWithNameAtTime(symbolicator, "CoreDisplay", kCSNow);
    if (CSIsNull(owner)) {
        printf("[ws_handler] Failed to find CoreDisplay symbol owner\n");
        CSRelease(symbolicator);
        return;
    }

    CSSymbolRef symbol = CSSymbolOwnerGetSymbolWithName(owner, "_gWSDeviceList");
    if (CSIsNull(symbol)) {
        printf("[ws_handler] Failed to find _gWSDeviceList symbol\n");
        CSRelease(symbolicator);
        return;
    }

    CSRange range = CSSymbolGetRange(symbol);
    gWSDeviceList_addr = range.location;
    printf("[ws_handler] Found _gWSDeviceList at 0x%llx\n", (unsigned long long)gWSDeviceList_addr);

    CSRelease(symbolicator);
}

void hide_displays(void) {
    printf("[ws_handler] hide_displays called\n");
    if (gWSDeviceList_addr == 0) {
        find_gWSDeviceList();
    }

    if (gWSDeviceList_addr != 0 && ws_task != MACH_PORT_NULL) {
        mach_vm_size_t read_size = 8;
        uint64_t current_val = 0;
        kern_return_t kr = mach_vm_read_overwrite(ws_task, gWSDeviceList_addr, 8, (mach_vm_address_t)&current_val, &read_size);
        if (kr != KERN_SUCCESS) {
            printf("[ws_handler] Failed to read _gWSDeviceList: %s\n", mach_error_string(kr));
            return;
        }

        if (current_val != 0) {
            saved_gWSDeviceList = current_val;
            uint64_t zero = 0;
            kr = mach_vm_write(ws_task, gWSDeviceList_addr, (vm_offset_t)&zero, 8);
            if (kr == KERN_SUCCESS) {
                printf("[ws_handler] Zeroed _gWSDeviceList\n");
            } else {
                printf("[ws_handler] Failed to write _gWSDeviceList: %s\n", mach_error_string(kr));
            }
        } else {
            printf("[ws_handler] _gWSDeviceList is already NULL\n");
        }
    }
}

void restore_displays(void) {
    if (gWSDeviceList_addr != 0 && saved_gWSDeviceList != 0 && ws_task != MACH_PORT_NULL) {
        kern_return_t kr = mach_vm_write(ws_task, gWSDeviceList_addr, (vm_offset_t)&saved_gWSDeviceList, 8);
        if (kr == KERN_SUCCESS) {
            printf("[ws_handler] Restored _gWSDeviceList\n");
        } else {
            printf("[ws_handler] Failed to restore _gWSDeviceList: %s\n", mach_error_string(kr));
        }
    }
}