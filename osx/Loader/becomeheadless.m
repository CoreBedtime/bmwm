#import <Foundation/Foundation.h>
#import <copyfile.h>
#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mount.h>
#import <sys/param.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/wait.h>
#import <unistd.h>

#define SKYLIGHT_RESOURCES "/System/Library/PrivateFrameworks/SkyLight.framework/Resources"
#define BACKUP_PATH "/var/protein/overlays/System/Library/PrivateFrameworks/SkyLight.framework/Resources"
#define OVERLAY_STORE_PREFIX "/var/protein/overlays"

static bool is_tmpfs_mount(const char *path) {
    struct statfs fs;
    if (statfs(path, &fs) != 0) {
        return false;
    }
    return strstr(fs.f_fstypename, "tmpfs") != NULL;
}

static bool is_mount_point(const char *path) {
    struct statfs fs;
    if (statfs(path, &fs) != 0) {
        return false;
    }

    struct stat path_stat, parent_stat;
    if (stat(path, &path_stat) != 0) {
        return false;
    }

    char parent_path[PATH_MAX];
    if (snprintf(parent_path, sizeof(parent_path), "%s/..", path) >= sizeof(parent_path)) {
        return false;
    }

    if (stat(parent_path, &parent_stat) != 0) {
        return false;
    }

    return path_stat.st_dev != parent_stat.st_dev;
}

static kern_return_t unmount_if_mounted(const char *path) {
    if (is_mount_point(path)) {
        fprintf(stdout, "Unmounting existing filesystem at %s\n", path);
        if (unmount(path, MNT_FORCE) != 0) {
            fprintf(stderr, "Failed to unmount %s: %s\n", path, strerror(errno));
            return -1;
        }
    }
    return 0;
}

static kern_return_t ensure_directory_exists(const char *path) {
    if (path == NULL) {
        return -1;
    }

    char tmp[PATH_MAX];
    if (snprintf(tmp, sizeof(tmp), "%s", path) >= sizeof(tmp)) {
        return -1;
    }

    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(tmp, 0755);
            *p = '/';
        }
    }

    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
        return -1;
    }
    return 0;
}

static bool dir_exists_and_nonempty(const char *dir) {
    DIR *d = opendir(dir);
    if (d == NULL) {
        return false;
    }

    bool has_entry = false;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") != 0 && strcmp(ent->d_name, "..") != 0) {
            has_entry = true;
            break;
        }
    }

    closedir(d);
    return has_entry;
}

static kern_return_t copy_dir_recursive(const char *src, const char *dst) {
    if (src == NULL || dst == NULL) {
        return -1;
    }

    DIR *dir = opendir(src);
    if (dir == NULL) {
        return -1;
    }

    kern_return_t ret = ensure_directory_exists(dst);
    if (ret != 0) {
        closedir(dir);
        return ret;
    }

    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
        if (strcmp(ent->d_name, ".fseventsd") == 0) continue;

        char src_path[PATH_MAX];
        char dst_path[PATH_MAX];
        snprintf(src_path, sizeof(src_path), "%s/%s", src, ent->d_name);
        snprintf(dst_path, sizeof(dst_path), "%s/%s", dst, ent->d_name);

        struct stat st;
        if (lstat(src_path, &st) != 0) continue;

        if (S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode)) {
            ret = copy_dir_recursive(src_path, dst_path);
            if (ret != 0) {
                closedir(dir);
                return ret;
            }
        } else {
            copyfile_state_t cst = copyfile_state_alloc();
            if (cst == NULL) {
                closedir(dir);
                return -1;
            }

            if (copyfile(src_path, dst_path, cst, COPYFILE_ALL) != 0) {
                copyfile_state_free(cst);
                closedir(dir);
                return -1;
            }
            copyfile_state_free(cst);
        }
    }

    closedir(dir);
    return 0;
}

static kern_return_t symlink_contents_of_dir(const char *store_path, const char *overlay_path) {
    if (store_path == NULL || overlay_path == NULL) {
        return -1;
    }

    DIR *d = opendir(store_path);
    if (d == NULL) {
        return -1;
    }

    kern_return_t ret = 0;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
        if (strcmp(ent->d_name, ".fseventsd") == 0) continue;

        char store_item[PATH_MAX];
        char overlay_item[PATH_MAX];
        snprintf(store_item, sizeof(store_item), "%s/%s", store_path, ent->d_name);
        snprintf(overlay_item, sizeof(overlay_item), "%s/%s", overlay_path, ent->d_name);

        if (symlink(store_item, overlay_item) != 0 && errno != EEXIST) {
            closedir(d);
            return -1;
        }
    }

    closedir(d);
    return ret;
}

void respawn_headless(void) {
    fprintf(stdout, "[respawn_headless] Creating overlay...\n");
    fflush(stdout);

    if (ensure_directory_exists(BACKUP_PATH) != 0) {
        fprintf(stderr, "[respawn_headless] Failed to create backing store: %s\n", strerror(errno));
        return;
    }

    if (!dir_exists_and_nonempty(BACKUP_PATH)) {
        fprintf(stdout, "[respawn_headless] Backing up original contents...\n");
        fflush(stdout);
        if (copy_dir_recursive(SKYLIGHT_RESOURCES, BACKUP_PATH) != 0) {
            fprintf(stderr, "[respawn_headless] Failed to backup contents: %s\n", strerror(errno));
            return;
        }
    }

    if (unmount_if_mounted(SKYLIGHT_RESOURCES) != 0) {
        fprintf(stderr, "[respawn_headless] Failed to unmount: %s\n", strerror(errno));
        return;
    }

    struct tmpfs_args {
        uint64_t max_pages;
        uint64_t max_nodes;
        uint64_t case_insensitive;
    } args;

    args.max_pages = 1024 * 1024 * 1024 / getpagesize();
    args.max_nodes = UINT8_MAX;
    args.case_insensitive = 0;

    if (mount("tmpfs", SKYLIGHT_RESOURCES, 0, &args) != 0) {
        fprintf(stderr, "[respawn_headless] Failed to mount tmpfs: %s\n", strerror(errno));
        return;
    }

    if (symlink_contents_of_dir(BACKUP_PATH, SKYLIGHT_RESOURCES) != 0) {
        fprintf(stderr, "[respawn_headless] Failed to symlink contents: %s\n", strerror(errno));
        unmount(SKYLIGHT_RESOURCES, MNT_FORCE);
        return;
    }

    unlink(SKYLIGHT_RESOURCES "/WindowServer");

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
                    kill(procs[i].kp_proc.p_pid, SIGKILL);
                    break;
                }
            }
        }
        free(procs);
    }

    fprintf(stdout, "[respawn_headless] Done\n");
    fflush(stdout);
}