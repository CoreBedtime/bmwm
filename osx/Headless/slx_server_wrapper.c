#define _POSIX_C_SOURCE 200809L

#if defined(__aarch64__) || defined(__x86_64__) || defined(__i386__)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <dobby.h>

#define likely(x)   __builtin_expect(!!(x), 1)
#define unlikely(x) __builtin_expect(!!(x), 0)

static int (*orig_func)();

static int bdetour__() {
    return 0;
}

static int patch_wspostlocalnotification(void) {
    void *sym = DobbySymbolResolver("SkyLight", "_WSFeatureAvailabilityComputeBool");
    if (!sym) {
        return -1;
    }

    if (DobbyHook(sym, (void *)bdetour__, (void **)&orig_func) != 0) {
        return -1;
    }

    return 0;
}

extern void SLXServer(int argc, char **argv);

int main(int argc, char **argv) {
    char *new_argv[] = {
        "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
        "-virtualonly",
        "-daemon",
        NULL
    };
    int new_argc = 3;

    patch_wspostlocalnotification();

    SLXServer(new_argc, new_argv);
    return 0;
}
#endif
