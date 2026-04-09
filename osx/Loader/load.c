#include <errno.h>
#include <grp.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <pwd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

extern char** environ;
extern void amfid_patch(void);

extern void hide_displays(void);
extern void restore_displays(void);

static int spawn_main_userspace(void) {
    char binary_path[PROC_PIDPATHINFO_MAXSIZE];
    int  path_len = proc_pidpath(getpid(), binary_path, sizeof(binary_path));
    if (path_len <= 0) {
        fprintf(stderr, "[loader] proc_pidpath(self): %s\n", strerror(errno));
        return -1;
    }

    char* binary_dir = strrchr(binary_path, '/');
    if (!binary_dir) {
        fprintf(stderr, "[loader] failed to derive binary directory\n");
        return -1;
    }
    *binary_dir = '\0';

    char helper_path[PROC_PIDPATHINFO_MAXSIZE];
    int  helper_len = snprintf(helper_path, sizeof(helper_path), "%s/MainUserspace", binary_path);
    if (helper_len < 0 || helper_len >= (int)sizeof(helper_path)) {
        fprintf(stderr, "[loader] helper path too long\n");
        return -1;
    }

    const uid_t target_uid = 501;
    errno = 0;
    struct passwd* pw = getpwuid(target_uid);
    if (!pw) {
        fprintf(stderr, "[loader] getpwuid(%u): %s\n", (unsigned)target_uid,
                strerror(errno != 0 ? errno : ENOENT));
        return -1;
    }

    pid_t helper_pid = fork();
    if (helper_pid < 0) {
        fprintf(stderr, "[loader] fork(): %s\n", strerror(errno));
        return -1;
    }

    if (helper_pid == 0) {
        if (initgroups(pw->pw_name, pw->pw_gid) != 0) {
            fprintf(stderr, "[loader] initgroups(%s): %s\n", pw->pw_name, strerror(errno));
            _exit(127);
        }
        if (setgid(pw->pw_gid) != 0) {
            fprintf(stderr, "[loader] setgid(%u): %s\n", (unsigned)pw->pw_gid, strerror(errno));
            _exit(127);
        }
        if (setuid(pw->pw_uid) != 0) {
            fprintf(stderr, "[loader] setuid(%u): %s\n", (unsigned)pw->pw_uid, strerror(errno));
            _exit(127);
        }

        char* const argv[] = {"MainUserspace", NULL};
        execve(helper_path, argv, environ);
        fprintf(stderr, "[loader] execve(%s): %s\n", helper_path, strerror(errno));
        _exit(127);
    }

    printf("[loader] spawned MainUserspace (pid %d)\n", helper_pid);
    fflush(stdout);

    int status = 0;
    for (;;) {
        pid_t waited = waitpid(helper_pid, &status, 0);
        if (waited == helper_pid)
            break;
        if (waited < 0 && errno == EINTR)
            continue;
        if (waited < 0) {
            fprintf(stderr, "[loader] waitpid(%d): %s\n", helper_pid, strerror(errno));
            return -1;
        }
    }

    if (WIFEXITED(status)) {
        int exit_status = WEXITSTATUS(status);
        printf("[loader] MainUserspace exited with status %d\n", exit_status);
        fflush(stdout);
        return exit_status;
    }
    if (WIFSIGNALED(status)) {
        printf("[loader] MainUserspace terminated by signal %d\n", WTERMSIG(status));
        return 1;
    }

    return 1;
}


void respawn_headless(void);

static int copy_slxserver_to_overlay(const char *binary_dir) {
    const char *overlay_path = "/var/protein/overlays/bin";
    char src_path[PROC_PIDPATHINFO_MAXSIZE];
    char dst_path[PROC_PIDPATHINFO_MAXSIZE];
    
    struct stat st;
    if (snprintf(src_path, sizeof(src_path), "%s/SLXServer", binary_dir) >= (int)sizeof(src_path)) {
        fprintf(stderr, "[loader] SLXServer src path too long\n");
        return -1;
    }
    
    if (stat(src_path, &st) != 0) {
        fprintf(stderr, "[loader] SLXServer not found at %s: %s\n", src_path, strerror(errno));
        return -1;
    }
    
    if (mkdir(overlay_path, 0755) != 0 && errno != EEXIST) {
        fprintf(stderr, "[loader] failed to create overlay bin dir: %s\n", strerror(errno));
        return -1;
    }
    
    if (snprintf(dst_path, sizeof(dst_path), "%s/SLXServer", overlay_path) >= (int)sizeof(dst_path)) {
        fprintf(stderr, "[loader] SLXServer dst path too long\n");
        return -1;
    }
    
    int src_fd = open(src_path, O_RDONLY);
    if (src_fd < 0) {
        fprintf(stderr, "[loader] failed to open SLXServer: %s\n", strerror(errno));
        return -1;
    }
    
    int dst_fd = open(dst_path, O_WRONLY | O_CREAT | O_TRUNC, st.st_mode);
    if (dst_fd < 0) {
        close(src_fd);
        fprintf(stderr, "[loader] failed to create SLXServer in overlay: %s\n", strerror(errno));
        return -1;
    }
    
    char buf[8192];
    ssize_t n;
    while ((n = read(src_fd, buf, sizeof(buf))) > 0) {
        if (write(dst_fd, buf, n) != n) {
            close(src_fd);
            close(dst_fd);
            fprintf(stderr, "[loader] failed to write SLXServer: %s\n", strerror(errno));
            return -1;
        }
    }
    
    close(src_fd);
    close(dst_fd);
    
    chmod(dst_path, st.st_mode | S_IXUSR | S_IXGRP | S_IXOTH);
    
    printf("[loader] copied SLXServer to overlay\n");
    return 0;
}

int main(void) {
    amfid_patch();
    
    char binary_path[PROC_PIDPATHINFO_MAXSIZE];
    int path_len = proc_pidpath(getpid(), binary_path, sizeof(binary_path));
    if (path_len <= 0) {
        fprintf(stderr, "[loader] proc_pidpath(self): %s\n", strerror(errno));
        return 1;
    }
    
    char *binary_dir = strrchr(binary_path, '/');
    if (!binary_dir) {
        fprintf(stderr, "[loader] failed to derive binary directory\n");
        return 1;
    }
    *binary_dir = '\0';
    
    copy_slxserver_to_overlay(binary_dir);
    
    respawn_headless();
    
    int rc = spawn_main_userspace();
    return rc == 0 ? 0 : 1;
}
