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
#include <unistd.h>

extern char** environ;
extern void amfid_patch(void);
extern void windowserver_HALT(bool cont);

static int spawn_main_userspace(void) {
    char binary_path[PROC_PIDPATHINFO_MAXSIZE];
    int  path_len = proc_pidpath(getpid(), binary_path, sizeof(binary_path));
    if (path_len <= 0) {
        fprintf(stderr, "[amfid_handler] proc_pidpath(self): %s\n", strerror(errno));
        return -1;
    }

    char* binary_dir = strrchr(binary_path, '/');
    if (!binary_dir) {
        fprintf(stderr, "[amfid_handler] failed to derive binary directory\n");
        return -1;
    }
    *binary_dir = '\0';

    char helper_path[PROC_PIDPATHINFO_MAXSIZE];
    int  helper_len = snprintf(helper_path, sizeof(helper_path), "%s/MainUserspace", binary_path);
    if (helper_len < 0 || helper_len >= (int)sizeof(helper_path)) {
        fprintf(stderr, "[amfid_handler] helper path too long\n");
        return -1;
    }

    const uid_t target_uid = 501;
    errno = 0;
    struct passwd* pw = getpwuid(target_uid);
    if (!pw) {
        fprintf(stderr, "[amfid_handler] getpwuid(%u): %s\n", (unsigned)target_uid,
                strerror(errno != 0 ? errno : ENOENT));
        return -1;
    }

    pid_t helper_pid = fork();
    if (helper_pid < 0) {
        fprintf(stderr, "[amfid_handler] fork(): %s\n", strerror(errno));
        return -1;
    }

    if (helper_pid == 0) {
        if (initgroups(pw->pw_name, pw->pw_gid) != 0) {
            fprintf(stderr, "[amfid_handler] initgroups(%s): %s\n", pw->pw_name, strerror(errno));
            _exit(127);
        }
        if (setgid(pw->pw_gid) != 0) {
            fprintf(stderr, "[amfid_handler] setgid(%u): %s\n", (unsigned)pw->pw_gid, strerror(errno));
            _exit(127);
        }
        if (setuid(pw->pw_uid) != 0) {
            fprintf(stderr, "[amfid_handler] setuid(%u): %s\n", (unsigned)pw->pw_uid, strerror(errno));
            _exit(127);
        }

        char* const argv[] = {"MainUserspace", NULL};
        execve(helper_path, argv, environ);
        fprintf(stderr, "[amfid_handler] execve(%s): %s\n", helper_path, strerror(errno));
        _exit(127);
    }

    printf("[amfid_handler] spawned MainUserspace (pid %d)\n", helper_pid);

    int status = 0;
    for (;;) {
        pid_t waited = waitpid(helper_pid, &status, 0);
        if (waited == helper_pid)
            break;
        if (waited < 0 && errno == EINTR)
            continue;
        if (waited < 0) {
            fprintf(stderr, "[amfid_handler] waitpid(%d): %s\n", helper_pid, strerror(errno));
            return -1;
        }
    }

    if (WIFEXITED(status)) {
        int exit_status = WEXITSTATUS(status);
        printf("[amfid_handler] MainUserspace exited with status %d\n", exit_status);
        return exit_status;
    }
    if (WIFSIGNALED(status)) {
        printf("[amfid_handler] MainUserspace terminated by signal %d\n", WTERMSIG(status));
        return 1;
    }

    return 1;
}

int main(void) {
    amfid_patch();
    windowserver_HALT(false);

    int rc = spawn_main_userspace();

    windowserver_HALT(true);
    return rc == 0 ? 0 : 1;
}
