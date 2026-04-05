/*
 * main.m
 *
 * Thin AppLaunch bootstrapper. It keeps Frida out of the main executable's
 * startup path so usage checks can run without tripping Frida's constructors.
 */

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
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

static bool path_is_directory(const char *path)
{
    struct stat st;

    if (path == NULL || stat(path, &st) != 0) {
        return false;
    }

    return S_ISDIR(st.st_mode);
}

static bool copy_path_string(const char *source,
                             char *destination,
                             size_t destination_size)
{
    int written = 0;

    if (source == NULL || destination == NULL || destination_size == 0) {
        return false;
    }

    written = snprintf(destination, destination_size, "%s", source);
    return written >= 0 && (size_t) written < destination_size;
}

static bool copy_resolved_executable_path(const char *target_path,
                                          char *executable_path,
                                          size_t executable_path_size)
{
    bool ok = false;
    char *resolved = NULL;
    const char *source_path = target_path;

    if (target_path == NULL || *target_path == '\0') {
        return false;
    }

    resolved = realpath(target_path, NULL);
    if (resolved != NULL) {
        source_path = resolved;
    }

    if (access(source_path, X_OK) != 0) {
        goto out;
    }

    ok = copy_path_string(source_path, executable_path, executable_path_size);

out:
    if (resolved != NULL) {
        free(resolved);
    }
    return ok;
}

static bool copy_path_lookup_executable(const char *target_name,
                                        char *executable_path,
                                        size_t executable_path_size)
{
    bool ok = false;
    char *path_copy = NULL;
    char *cursor = NULL;
    char *entry = NULL;
    const char *path_env = getenv("PATH");

    if (target_name == NULL || *target_name == '\0') {
        return false;
    }

    if (strchr(target_name, '/') != NULL) {
        return copy_resolved_executable_path(target_name,
                                             executable_path,
                                             executable_path_size);
    }

    if (path_env == NULL || *path_env == '\0') {
        path_env = "/usr/bin:/bin:/usr/sbin:/sbin";
    }

    path_copy = strdup(path_env);
    if (path_copy == NULL) {
        return false;
    }

    cursor = path_copy;
    while ((entry = strsep(&cursor, ":")) != NULL) {
        char candidate[PATH_MAX];
        const char *dir = (*entry == '\0') ? "." : entry;
        int written = snprintf(candidate, sizeof(candidate), "%s/%s", dir, target_name);
        if (written < 0 || (size_t) written >= sizeof(candidate)) {
            continue;
        }

        if (!copy_resolved_executable_path(candidate,
                                           executable_path,
                                           executable_path_size)) {
            continue;
        }

        ok = true;
        break;
    }

    free(path_copy);
    return ok;
}

static bool copy_bundle_executable_path(const char *bundle_path,
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

static bool copy_target_executable_path(const char *target_path,
                                        char *executable_path,
                                        size_t executable_path_size)
{
    if (path_is_directory(target_path)) {
        if (copy_bundle_executable_path(target_path,
                                        executable_path,
                                        executable_path_size)) {
            return true;
        }
    }

    return copy_path_lookup_executable(target_path,
                                       executable_path,
                                       executable_path_size);
}

static bool launch_executable(const char *executable_path,
                              int argc,
                              char *argv[],
                              pid_t *child_pid_out)
{
    size_t spawn_argc = (size_t) argc - 1;
    char **spawn_argv = calloc(spawn_argc + 1, sizeof(char *));
    pid_t child_pid = 0;
    int rc = 0;
    posix_spawnattr_t attrs;
    short flags = 0;

    if (spawn_argv == NULL) {
        return false;
    }

    spawn_argv[0] = (char *) executable_path;
    for (int j = 2; j < argc; j++) {
        spawn_argv[j - 1] = argv[j];
    }

    rc = posix_spawnattr_init(&attrs);
    if (rc != 0) {
        free(spawn_argv);
        return false;
    }

    rc = posix_spawnattr_getflags(&attrs, &flags);
    if (rc == 0) {
        flags |= POSIX_SPAWN_START_SUSPENDED;
        rc = posix_spawnattr_setflags(&attrs, flags);
    }

    if (rc == 0) {
        rc = posix_spawn(&child_pid, executable_path, NULL, &attrs, spawn_argv, environ);
    }

    posix_spawnattr_destroy(&attrs);
    free(spawn_argv);

    if (rc == 0 && child_pid_out != NULL) {
        *child_pid_out = child_pid;
    }
    return rc == 0;
}

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr,
                "Usage: %s /path/to/App.app|/path/to/executable [target-args...]\n",
                argv[0]);
        return 1;
    }

    pid_t child_pid = 0;
    char *helper_path = copy_helper_path();
    char executable_path[PATH_MAX];
    if (helper_path == NULL) {
        fprintf(stderr, "Failed to locate AppLaunch helper library\n");
        return 1;
    }

    if (!copy_target_executable_path(argv[1], executable_path, sizeof(executable_path))) {
        fprintf(stderr, "Failed to resolve launch target: %s\n", argv[1]);
        free(helper_path);
        return 1;
    }

    fprintf(stderr, "[bootstrap] launching %s\n", executable_path);
    if (!launch_executable(executable_path, argc, argv, &child_pid)) {
        fprintf(stderr, "Failed to launch target executable: %s\n", executable_path);
        free(helper_path);
        return 1;
    }

    char child_pid_buf[32];
    snprintf(child_pid_buf, sizeof(child_pid_buf), "%d", (int) child_pid);
    setenv("APP_LAUNCH_TARGET_PID", child_pid_buf, 1);

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
