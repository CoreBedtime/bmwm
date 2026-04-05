/*
 * main.m
 *
 * Thin AppLaunch bootstrapper. It keeps Frida out of the main executable's
 * startup path so usage checks can run without tripping Frida's constructors.
 */

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <spawn.h>
#include <unistd.h>
#include <limits.h>
#include <libgen.h>

#include <CoreFoundation/CoreFoundation.h>

extern char **environ;

typedef int (*AppLaunchRunFunc)(int argc, char *argv[]);

static char *copy_helper_path(void)
{
    uint32_t size = 0;
    char *path = NULL;
    char *resolved = NULL;
    char *dir = NULL;
    char *helper_path = NULL;

    _NSGetExecutablePath(NULL, &size);
    path = malloc(size);
    if (path == NULL) {
        return NULL;
    }

    if (_NSGetExecutablePath(path, &size) != 0) {
        free(path);
        return NULL;
    }

    resolved = realpath(path, NULL);
    free(path);
    if (resolved == NULL) {
        return NULL;
    }

    dir = dirname(resolved);
    if (dir == NULL) {
        free(resolved);
        return NULL;
    }

    size_t helper_len = strlen(dir) + strlen("/libAppLaunchRunner.dylib") + 1;
    helper_path = malloc(helper_len);
    if (helper_path == NULL) {
        free(resolved);
        return NULL;
    }

    snprintf(helper_path, helper_len, "%s/libAppLaunchRunner.dylib", dir);
    free(resolved);
    return helper_path;
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

static bool launch_executable(const char *executable_path,
                              int argc,
                              char *argv[])
{
    size_t spawn_argc = (size_t) argc - 1;
    char **spawn_argv = calloc(spawn_argc + 1, sizeof(char *));
    pid_t child_pid = 0;
    int rc = 0;

    if (spawn_argv == NULL) {
        return false;
    }

    spawn_argv[0] = (char *) executable_path;
    for (int j = 2; j < argc; j++) {
        spawn_argv[j - 1] = argv[j];
    }

    rc = posix_spawn(&child_pid, executable_path, NULL, NULL, spawn_argv, environ);
    free(spawn_argv);
    return rc == 0;
}

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s /path/to/App.app [app-args...]\n", argv[0]);
        return 1;
    }

    char *helper_path = copy_helper_path();
    char executable_path[PATH_MAX];
    if (helper_path == NULL) {
        fprintf(stderr, "Failed to locate AppLaunch helper library\n");
        return 1;
    }

    if (!copy_executable_path(argv[1], executable_path, sizeof(executable_path))) {
        fprintf(stderr, "Failed to resolve app executable: %s\n", argv[1]);
        free(helper_path);
        return 1;
    }

    fprintf(stderr, "[bootstrap] launching %s\n", executable_path);
    if (!launch_executable(executable_path, argc, argv)) {
        fprintf(stderr, "Failed to launch app executable: %s\n", executable_path);
        free(helper_path);
        return 1;
    }

    fprintf(stderr, "[bootstrap] loading %s\n", helper_path);
    void *handle = dlopen(helper_path, RTLD_NOW);
    if (handle == NULL) {
        fprintf(stderr, "Failed to load helper: %s\n", dlerror());
        free(helper_path);
        return 1;
    }

    fprintf(stderr, "[bootstrap] loaded helper\n");
    free(helper_path);

    AppLaunchRunFunc run = (AppLaunchRunFunc) dlsym(handle, "AppLaunchRun");
    if (run == NULL) {
        fprintf(stderr, "Failed to resolve AppLaunchRun: %s\n", dlerror());
        dlclose(handle);
        return 1;
    }

    fprintf(stderr, "[bootstrap] calling helper\n");
    int exit_code = run(argc, argv);
    fprintf(stderr, "[bootstrap] helper returned %d\n", exit_code);
    dlclose(handle);
    return exit_code;
}
