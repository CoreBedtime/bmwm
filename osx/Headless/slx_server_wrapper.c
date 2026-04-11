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

static int cxdetour__() {
    return 1;
}
static int patch_wspostlocalnotification(void) {
    void *sym;
    sym = DobbySymbolResolver("SkyLight", "CGXUpdateDisplay");
    if (DobbyHook(sym, (void *)cxdetour__, (void **)&orig_func) != 0)  return -1;

    return 0;
}

extern void SLXServer(int argc, char **argv);

int main(int argc, char **argv) {
    patch_wspostlocalnotification();

    SLXServer(argc, argv);
    return 0;
}
#endif
