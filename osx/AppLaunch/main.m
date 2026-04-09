/*
 * main.m
 *
 * Thin AppLaunch bootstrapper. It keeps Frida out of the main executable's
 * startup path so usage checks can run without tripping Frida's constructors.
 */

#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <limits.h>
#include <libgen.h>
#include <dirent.h>
#include <pwd.h>

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <sys/stat.h>

extern const CFStringRef kSecCodeSignerIdentity;
extern const CFStringRef kSecCodeSignerEntitlements;
extern const CFStringRef kSecCodeSignerDigestAlgorithm;
typedef struct __SecCodeSigner *SecCodeSignerRef;
extern OSStatus SecCodeSignerCreate(CFDictionaryRef parameters, SecCSFlags flags, SecCodeSignerRef *signer);
extern OSStatus SecCodeSignerAddSignatureWithErrors(SecCodeSignerRef signer, SecStaticCodeRef code, SecCSFlags flags, CFErrorRef *errors);

void depacify(uint8_t *d, size_t s) {
    uint32_t m = *(uint32_t*)d;
    if (m == MH_MAGIC_64) {
        struct mach_header_64 *h = (struct mach_header_64*)d;
        if (h->cputype == CPU_TYPE_ARM64 && (h->cpusubtype & 0xff) == 2) {
            h->cpusubtype = 0;
            struct load_command *lc = (struct load_command*)(d + sizeof(*h));
            for (uint32_t i=0; i<h->ncmds; i++) {
                if (lc->cmd == LC_SEGMENT_64) {
                    struct segment_command_64 *seg = (struct segment_command_64*)lc;
                    if (seg->initprot & VM_PROT_EXECUTE) {
                        uintptr_t addr = (uintptr_t)d + seg->fileoff;
                        for (size_t j=0; j < seg->filesize - 3; j += 4) {
                            uint32_t *p = (uint32_t*)(addr + j);
                            if ((*p & 0xfffff000) == 0xd5032000) *p = 0xd503201f;
                        }
                    }
                }
                lc = (struct load_command*)((uint8_t*)lc + lc->cmdsize);
            }
        }
    } else if (m == FAT_MAGIC || m == FAT_CIGAM) {
        struct fat_header *fh = (struct fat_header*)d;
        uint32_t n = (m == FAT_CIGAM) ? __builtin_bswap32(fh->nfat_arch) : fh->nfat_arch;
        struct fat_arch *as = (struct fat_arch*)(d + 8);
        for (uint32_t i=0; i<n; i++) {
            uint32_t off = (m == FAT_CIGAM) ? __builtin_bswap32(as[i].offset) : as[i].offset;
            uint32_t t = (m == FAT_CIGAM) ? __builtin_bswap32(as[i].cputype) : as[i].cputype;
            uint32_t sbt = (m == FAT_CIGAM) ? __builtin_bswap32(as[i].cpusubtype) : as[i].cpusubtype;
            if (t == CPU_TYPE_ARM64 && (sbt & 0xff) == 2) {
                depacify(d + off, s - off);
                as[i].cpusubtype = (m == FAT_CIGAM) ? __builtin_bswap32(0) : 0;
            }
        }
    }
}

static bool strip_code_signature_thin(uint8_t *data, size_t size) {
    if (*(uint32_t *)data != MH_MAGIC_64)
        return true;

    struct mach_header_64 *header = (struct mach_header_64 *)data;
    uint8_t *src = (uint8_t *)(data + sizeof(*header));
    uint8_t *dst = src;
    uint32_t new_ncmds = 0;
    uint32_t new_sizeofcmds = 0;
    uint32_t freed = 0;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *lc = (struct load_command *)src;
        uint32_t cmdsize = lc->cmdsize;

        if (lc->cmd == LC_CODE_SIGNATURE) {
            freed += cmdsize;
        } else {
            if (dst != src)
                memmove(dst, src, cmdsize);
            dst += cmdsize;
            new_ncmds++;
            new_sizeofcmds += cmdsize;
        }
        src += cmdsize;
    }

    if (freed > 0) {
        memset(data + sizeof(*header) + new_sizeofcmds, 0, freed);
        header->ncmds = new_ncmds;
        header->sizeofcmds = new_sizeofcmds;
    }

    (void)size;
    return true;
}

static bool strip_code_signature_file(const char *path) {
    int fd = open(path, O_RDWR);
    if (fd < 0) {
        return false;
    }

    struct stat st;
    if (fstat(fd, &st) != 0) {
        close(fd);
        return false;
    }

    uint8_t *data = (uint8_t *)mmap(NULL, (size_t)st.st_size,
                                    PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) {
        close(fd);
        return false;
    }

    bool ok = true;
    uint32_t magic = *(uint32_t *)data;
    if (magic == MH_MAGIC_64) {
        ok = strip_code_signature_thin(data, (size_t)st.st_size);
    } else if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        struct fat_header *fh = (struct fat_header *)data;
        uint32_t nfat = (magic == FAT_CIGAM) ? __builtin_bswap32(fh->nfat_arch) : fh->nfat_arch;
        struct fat_arch *arches = (struct fat_arch *)(data + sizeof(*fh));
        for (uint32_t i = 0; i < nfat && ok; i++) {
            uint32_t offset = (magic == FAT_CIGAM) ? __builtin_bswap32(arches[i].offset) : arches[i].offset;
            if (*(uint32_t *)(data + offset) == MH_MAGIC_64) {
                ok = strip_code_signature_thin(data + offset, (size_t)st.st_size - offset);
            }
        }
    }

    if (msync(data, (size_t)st.st_size, MS_SYNC) != 0) {
        ok = false;
    }

    munmap(data, (size_t)st.st_size);
    close(fd);
    return ok;
}

static CFDataRef wrap_entitlements_xml(CFDataRef xml_data) {
    CFIndex raw_len = CFDataGetLength(xml_data);
    if (raw_len > (CFIndex)(UINT32_MAX - 8)) {
        return NULL;
    }

    uint32_t total_len = (uint32_t)raw_len + 8;
    uint8_t *blob = (uint8_t *)malloc(total_len);
    if (!blob) {
        return NULL;
    }

    const uint8_t *raw_bytes = CFDataGetBytePtr(xml_data);
    uint32_t magic = CFSwapInt32HostToBig(0xFADE7171);
    uint32_t size_be = CFSwapInt32HostToBig(total_len);
    memcpy(blob, &magic, sizeof(magic));
    memcpy(blob + 4, &size_be, sizeof(size_be));
    memcpy(blob + 8, raw_bytes, (size_t)raw_len);

    CFDataRef ent_blob = CFDataCreate(kCFAllocatorDefault, blob, total_len);
    free(blob);
    return ent_blob;
}

static CFDataRef load_entitlements_from_code(const char *code_path) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault,
        (const UInt8 *)code_path,
        strlen(code_path),
        false);
    if (!url) {
        return NULL;
    }

    SecStaticCodeRef static_code = NULL;
    OSStatus status = SecStaticCodeCreateWithPath(url, 0, &static_code);
    CFRelease(url);
    if (status != errSecSuccess) {
        return NULL;
    }

    CFDictionaryRef info_raw = NULL;
    status = SecCodeCopySigningInformation(static_code, kSecCSSigningInformation, &info_raw);
    CFRelease(static_code);
    if (status != errSecSuccess || !info_raw) {
        return NULL;
    }

    CFDataRef entitlements = (CFDataRef)CFDictionaryGetValue(info_raw, kSecCodeInfoEntitlements);
    if (entitlements && CFGetTypeID(entitlements) == CFDataGetTypeID()) {
        if (CFDataGetLength(entitlements) == 0) {
            CFRelease(info_raw);
            return NULL;
        }
        CFRetain(entitlements);
        CFRelease(info_raw);
        return (CFDataRef)entitlements;
    }

    CFDictionaryRef entitlements_dict =
        (CFDictionaryRef)CFDictionaryGetValue(info_raw, kSecCodeInfoEntitlementsDict);
    CFRelease(info_raw);
    if (!entitlements_dict || CFGetTypeID(entitlements_dict) != CFDictionaryGetTypeID()) {
        return NULL;
    }

    CFErrorRef plist_error = NULL;
    CFDataRef xml_data = CFPropertyListCreateData(kCFAllocatorDefault,
                                                  entitlements_dict,
                                                  kCFPropertyListXMLFormat_v1_0,
                                                  0,
                                                  &plist_error);
    if (!xml_data) {
        if (plist_error) CFRelease(plist_error);
        return NULL;
    }

    CFDataRef ent_blob = wrap_entitlements_xml(xml_data);
    CFRelease(xml_data);
    return ent_blob;
}

static bool sign_file(const char *path, CFDataRef entitlements_blob) {
    CFMutableDictionaryRef params = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (!params) {
        return false;
    }

    CFDictionaryAddValue(params, kSecCodeSignerIdentity, kCFNull);

    if (entitlements_blob) {
        CFDictionaryAddValue(params, kSecCodeSignerEntitlements, entitlements_blob);
    }

    int digest_value = kSecCodeSignatureHashSHA256;
    CFNumberRef digest_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &digest_value);
    if (!digest_number) {
        CFRelease(params);
        return false;
    }
    const void *digests[] = { digest_number };
    CFArrayRef digest_array = CFArrayCreate(kCFAllocatorDefault, digests, 1, &kCFTypeArrayCallBacks);
    CFRelease(digest_number);
    if (!digest_array) {
        CFRelease(params);
        return false;
    }
    CFDictionaryAddValue(params, kSecCodeSignerDigestAlgorithm, digest_array);
    CFRelease(digest_array);

    SecCodeSignerRef signer = NULL;
    OSStatus status = SecCodeSignerCreate(params, kSecCSDefaultFlags, &signer);
    CFRelease(params);
    if (status != errSecSuccess) {
        return false;
    }

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault,
        (const UInt8 *)path,
        strlen(path),
        false);
    if (!url) {
        CFRelease(signer);
        return false;
    }

    SecStaticCodeRef static_code = NULL;
    status = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &static_code);
    CFRelease(url);
    if (status != errSecSuccess) {
        CFRelease(signer);
        return false;
    }

    CFErrorRef error = NULL;
    status = SecCodeSignerAddSignatureWithErrors(signer, static_code, kSecCSDefaultFlags, &error);
    CFRelease(signer);
    CFRelease(static_code);
    if (error) CFRelease(error);

    return status == errSecSuccess;
}

static bool resign_executable(const char *tmp_path, const char *original_path) {
    if (!strip_code_signature_file(tmp_path)) {
        fprintf(stderr, "[bootstrap] failed to strip code signature\n");
        return false;
    }

    CFDataRef entitlements = load_entitlements_from_code(original_path);
    bool ok = sign_file(tmp_path, entitlements);
    if (entitlements) CFRelease(entitlements);

    if (!ok) {
        fprintf(stderr, "[bootstrap] failed to resign executable\n");
        return false;
    }

    return true;
}

static bool depacify_file_in_place(const char *file_path) {
    int fd = open(file_path, O_RDWR);
    if (fd < 0) {
        return false;
    }

    struct stat st;
    if (fstat(fd, &st) != 0) {
        close(fd);
        return false;
    }

    size_t size = (size_t)st.st_size;
    uint8_t *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) {
        close(fd);
        return false;
    }

    depacify(data, size);

    if (msync(data, size, MS_SYNC) != 0) {
        munmap(data, size);
        close(fd);
        return false;
    }

    if (fsync(fd) != 0) {
        munmap(data, size);
        close(fd);
        return false;
    }

    munmap(data, size);
    close(fd);
    return true;
}

static bool depacify_executable(const char *executable_path, char *tmp_path, size_t tmp_path_size) {
    int fd = open(executable_path, O_RDONLY);
    if (fd < 0) {
        return false;
    }

    struct stat st;
    if (fstat(fd, &st) != 0) {
        close(fd);
        return false;
    }

    size_t size = (size_t) st.st_size;
    uint8_t *data = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (data == MAP_FAILED) {
        close(fd);
        return false;
    }

    char tmp_template[] = "/tmp/applaunch-XXXXXX";
    int tmp_fd = mkstemp(tmp_template);
    if (tmp_fd < 0) {
        munmap(data, size);
        close(fd);
        return false;
    }

    if (fchmod(tmp_fd, st.st_mode) != 0) {
        munmap(data, size);
        close(tmp_fd);
        close(fd);
        return false;
    }

    if (ftruncate(tmp_fd, size) != 0) {
        munmap(data, size);
        close(tmp_fd);
        unlink(tmp_template);
        close(fd);
        return false;
    }

    uint8_t *tmp_data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, tmp_fd, 0);
    if (tmp_data == MAP_FAILED) {
        munmap(data, size);
        close(tmp_fd);
        unlink(tmp_template);
        close(fd);
        return false;
    }

    memcpy(tmp_data, data, size);
    munmap(data, size);

    depacify(tmp_data, size);

    if (msync(tmp_data, size, MS_SYNC) != 0) {
        munmap(tmp_data, size);
        close(tmp_fd);
        unlink(tmp_template);
        close(fd);
        return false;
    }

    if (fsync(tmp_fd) != 0) {
        munmap(tmp_data, size);
        close(tmp_fd);
        unlink(tmp_template);
        close(fd);
        return false;
    }

    munmap(tmp_data, size);
    close(tmp_fd);
    close(fd);

    snprintf(tmp_path, tmp_path_size, "%s", tmp_template);
    return true;
}

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

static bool path_is_bundle(const char *path) {
    size_t len = strlen(path);
    if (len > 4 && strcmp(path + len - 4, ".app") == 0) {
        return path_is_directory(path);
    }
    return false;
}

static bool get_bundle_executable_path(const char *bundle_path, char *exec_path, size_t exec_path_size) {
    CFURLRef bundle_url = NULL;
    CFBundleRef bundle = NULL;
    CFURLRef exec_url = NULL;
    bool result = false;

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

    exec_url = CFBundleCopyExecutableURL(bundle);
    if (exec_url == NULL) {
        goto out;
    }

    if (!CFURLGetFileSystemRepresentation(exec_url, true, (UInt8 *)exec_path, (CFIndex)exec_path_size)) {
        goto out;
    }

    result = true;

out:
    if (exec_url) CFRelease(exec_url);
    if (bundle) CFRelease(bundle);
    if (bundle_url) CFRelease(bundle_url);
    return result;
}

static bool copy_dir_recursive(const char *src_path, const char *dst_path);

static bool copy_bundle_to_tmp(const char *bundle_path, char *tmp_path, size_t tmp_path_size) {
    char template_path[PATH_MAX];
    snprintf(template_path, sizeof(template_path), "/tmp/applaunch-XXXXXX");

    char *tmp_dir = mkdtemp(template_path);
    if (!tmp_dir) {
        return false;
    }

    char bundle_name[PATH_MAX];
    const char *base = strrchr(bundle_path, '/');
    if (base) {
        snprintf(bundle_name, sizeof(bundle_name), "%s", base + 1);
    } else {
        snprintf(bundle_name, sizeof(bundle_name), "%s", bundle_path);
    }

    char dst_bundle_path[PATH_MAX];
    snprintf(dst_bundle_path, sizeof(dst_bundle_path), "%s/%s", tmp_dir, bundle_name);

    if (!copy_dir_recursive(bundle_path, dst_bundle_path)) {
        rmdir(tmp_dir);
        return false;
    }

    if (!get_bundle_executable_path(dst_bundle_path, tmp_path, tmp_path_size)) {
        rmdir(tmp_dir);
        return false;
    }

    return true;
}

static bool copy_dir_recursive(const char *src_path, const char *dst_path) {
    DIR *src_dir = opendir(src_path);
    if (!src_dir) return false;

    if (mkdir(dst_path, 0755) != 0) {
        closedir(src_dir);
        return false;
    }

    struct dirent *entry;
    while ((entry = readdir(src_dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }

        char src_sub[PATH_MAX];
        char dst_sub[PATH_MAX];
        snprintf(src_sub, sizeof(src_sub), "%s/%s", src_path, entry->d_name);
        snprintf(dst_sub, sizeof(dst_sub), "%s/%s", dst_path, entry->d_name);

        struct stat st;
        if (lstat(src_sub, &st) != 0) {
            closedir(src_dir);
            return false;
        }

        if (S_ISDIR(st.st_mode)) {
            if (!copy_dir_recursive(src_sub, dst_sub)) {
                closedir(src_dir);
                return false;
            }
        } else if (S_ISREG(st.st_mode)) {
            int src_fd = open(src_sub, O_RDONLY);
            if (src_fd < 0) {
                closedir(src_dir);
                return false;
            }

            int dst_fd = open(dst_sub, O_WRONLY | O_CREAT | O_TRUNC, st.st_mode);
            if (dst_fd < 0) {
                close(src_fd);
                closedir(src_dir);
                return false;
            }

            char buffer[65536];
            while (1) {
                ssize_t nread = read(src_fd, buffer, sizeof(buffer));
                if (nread == 0) break;
                if (nread < 0) {
                    close(src_fd);
                    close(dst_fd);
                    closedir(src_dir);
                    return false;
                }
                ssize_t written = 0;
                while (written < nread) {
                    ssize_t nwrite = write(dst_fd, buffer + written, (size_t)(nread - written));
                    if (nwrite < 0) {
                        close(src_fd);
                        close(dst_fd);
                        closedir(src_dir);
                        return false;
                    }
                    written += nwrite;
                }
            }

            close(src_fd);
            close(dst_fd);
        } else if (S_ISLNK(st.st_mode)) {
            char link_buf[PATH_MAX];
            ssize_t len = readlink(src_sub, link_buf, sizeof(link_buf) - 1);
            if (len < 0) {
                closedir(src_dir);
                return false;
            }
            link_buf[len] = '\0';
            if (symlink(link_buf, dst_sub) != 0) {
                closedir(src_dir);
                return false;
            }
        }
    }

    closedir(src_dir);
    return true;
}

static bool resign_bundle(const char *bundle_path) {
    char exec_path[PATH_MAX];
    if (!get_bundle_executable_path(bundle_path, exec_path, sizeof(exec_path))) {
        return false;
    }
    if (!strip_code_signature_file(exec_path)) {
        return false;
    }
    return sign_file(exec_path, NULL);
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

int     posix_spawnattr_set_uid_np(const posix_spawnattr_t * __restrict, uid_t) __API_AVAILABLE(macos(10.15), ios(13.0), tvos(13.0), watchos(6.0));
int     posix_spawnattr_set_gid_np(const posix_spawnattr_t * __restrict, gid_t) __API_AVAILABLE(macos(10.15), ios(13.0), tvos(13.0), watchos(6.0));
int     posix_spawnattr_set_groups_np(const posix_spawnattr_t * __restrict, int, gid_t * __restrict, uid_t) __API_AVAILABLE(macos(10.15), ios(13.0), tvos(13.0), watchos(6.0));
int     posix_spawnattr_set_login_np(const posix_spawnattr_t * __restrict, const char * __restrict) __API_AVAILABLE(macos(10.15), ios(13.0), tvos(13.0), watchos(6.0));


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

    const char *user_id_str = getenv("USER_ID") ?: "501";
    if (user_id_str != NULL && user_id_str[0] != '\0') {
        char *end = NULL;
        errno = 0;
        unsigned long uid_val = strtoul(user_id_str, &end, 10);
        if (errno == 0 && end != user_id_str && *end == '\0' && uid_val <= UINT32_MAX) {
            uid_t uid = (uid_t)uid_val;
            gid_t gid = 0;

            struct passwd *pw = getpwuid(uid);
            if (pw != NULL) {
                gid = pw->pw_gid;
            }

            rc = posix_spawnattr_set_uid_np(&attrs, uid);
            if (rc == 0) {
                rc = posix_spawnattr_set_gid_np(&attrs, gid);
            }
            if (rc == 0) {
                fprintf(stderr, "[bootstrap] launching as uid=%u gid=%u\n", uid, gid);
            }
        }
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
    bool is_bundle = path_is_bundle(argv[1]);

    if (helper_path == NULL) {
        fprintf(stderr, "Failed to locate AppLaunch helper library\n");
        return 1;
    }

    if (!copy_target_executable_path(argv[1], executable_path, sizeof(executable_path))) {
        fprintf(stderr, "Failed to resolve launch target: %s\n", argv[1]);
        free(helper_path);
        return 1;
    }

    char depacified_path[PATH_MAX];
    depacified_path[0] = '\0';

    if (is_bundle) {
        fprintf(stderr, "[bootstrap] processing bundle: %s\n", argv[1]);
        char bundle_exec_tmp[PATH_MAX];
        if (copy_bundle_to_tmp(argv[1], bundle_exec_tmp, sizeof(bundle_exec_tmp))) {
            char bundle_tmp_path[PATH_MAX];
            snprintf(bundle_tmp_path, sizeof(bundle_tmp_path), "%s", bundle_exec_tmp);
            char *macos_ptr = strstr(bundle_tmp_path, "/Contents/MacOS/");
            if (macos_ptr) {
                *macos_ptr = '\0';
            }
            fprintf(stderr, "[bootstrap] copied bundle to: %s\n", bundle_tmp_path);
            fprintf(stderr, "[bootstrap] depacifying executable: %s\n", bundle_exec_tmp);
            if (depacify_file_in_place(bundle_exec_tmp)) {
                fprintf(stderr, "[bootstrap] resigning bundle: %s\n", bundle_tmp_path);
                if (resign_bundle(bundle_tmp_path)) {
                    fprintf(stderr, "[bootstrap] using depacified bundle\n");
                    snprintf(executable_path, sizeof(executable_path), "%s", bundle_exec_tmp);
                } else {
                    fprintf(stderr, "Warning: failed to resign bundle, continuing anyway\n");
                    snprintf(executable_path, sizeof(executable_path), "%s", bundle_exec_tmp);
                }
            } else {
                fprintf(stderr, "Warning: failed to depacify bundle executable\n");
            }
        } else {
            fprintf(stderr, "Warning: failed to copy bundle to tmp, using original\n");
        }
    } else {
        char original_executable_path[PATH_MAX];
        snprintf(original_executable_path, sizeof(original_executable_path), "%s", executable_path);

        if (depacify_executable(executable_path, depacified_path, sizeof(depacified_path))) {
            fprintf(stderr, "[bootstrap] using depacified: %s\n", depacified_path);
            if (!resign_executable(depacified_path, original_executable_path)) {
                fprintf(stderr, "Warning: failed to resign depacified executable\n");
            }
            snprintf(executable_path, sizeof(executable_path), "%s", depacified_path);
        } else {
            fprintf(stderr, "Warning: failed to depacify executable, continuing anyway\n");
        }
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
