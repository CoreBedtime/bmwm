#include "BinaryPatch.h"
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <libkern/OSByteOrder.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

extern const CFStringRef kSecCodeSignerIdentity;
extern const CFStringRef kSecCodeSignerEntitlements;
extern const CFStringRef kSecCodeSignerDigestAlgorithm;
typedef struct __SecCodeSigner *SecCodeSignerRef;
extern OSStatus SecCodeSignerCreate(CFDictionaryRef parameters, SecCSFlags flags, SecCodeSignerRef *signer);
extern OSStatus SecCodeSignerAddSignatureWithErrors(SecCodeSignerRef signer, SecStaticCodeRef code, SecCSFlags flags, CFErrorRef *errors);

#define IS_64_BIT(x) ((x) == MH_MAGIC_64 || (x) == MH_CIGAM_64)
#define IS_LITTLE_ENDIAN(x) ((x) == FAT_CIGAM || (x) == MH_CIGAM_64 || (x) == MH_CIGAM)
#define SWAP32(x, magic) (IS_LITTLE_ENDIAN(magic)? OSSwapInt32(x): (x))
#define SWAP64(x, magic) (IS_LITTLE_ENDIAN(magic)? OSSwapInt64(x): (x))

#define ROUND_UP(x, y) (((x) + (y) - 1) & -(y))

static void *read_load_command(FILE *f, uint32_t cmdsize) {
    void *lc = malloc(cmdsize);
    off_t pos = ftello(f);
    fread(lc, cmdsize, 1, f);
    fseeko(f, pos, SEEK_SET);
    return lc;
}

static bool insert_dylib(FILE *f, size_t header_offset, const char *dylib_path, off_t *slice_size) {
    fseeko(f, header_offset, SEEK_SET);

    struct mach_header mh;
    fread(&mh, sizeof(struct mach_header), 1, f);

    if (mh.magic != MH_MAGIC_64 && mh.magic != MH_CIGAM_64 && mh.magic != MH_MAGIC && mh.magic != MH_CIGAM) {
        return false;
    }

    size_t commands_offset = header_offset + (IS_64_BIT(mh.magic) ? sizeof(struct mach_header_64) : sizeof(struct mach_header));

    fseeko(f, commands_offset, SEEK_SET);
    uint32_t ncmds = SWAP32(mh.ncmds, mh.magic);

    for (int i = 0; i < ncmds; i++) {
        struct load_command lc;
        off_t pos = ftello(f);
        fread(&lc, sizeof(lc), 1, f);
        fseeko(f, pos, SEEK_SET);

        uint32_t cmdsize = SWAP32(lc.cmdsize, mh.magic);
        uint32_t cmd = SWAP32(lc.cmd, mh.magic);

        if (cmd == LC_CODE_SIGNATURE) {
            if (i == ncmds - 1) {
                struct linkedit_data_command *cmd_ptr = (struct linkedit_data_command *)read_load_command(f, cmdsize);
                uint32_t datasize = SWAP32(cmd_ptr->datasize, mh.magic);
                free(cmd_ptr);

                *slice_size -= datasize;
                mh.ncmds = SWAP32(ncmds - 1, mh.magic);
                mh.sizeofcmds = SWAP32(SWAP32(mh.sizeofcmds, mh.magic) - cmdsize, mh.magic);
                ncmds--;
            }
        } else if (cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB) {
            struct dylib_command *dylib_command = (struct dylib_command *)read_load_command(f, cmdsize);
            char *name = &((char *)dylib_command)[SWAP32(dylib_command->dylib.name.offset, mh.magic)];
            if (strcmp(name, dylib_path) == 0) {
                free(dylib_command);
                return true;
            }
            free(dylib_command);
        }
        fseeko(f, cmdsize, SEEK_CUR);
    }

    size_t path_padding = 8;
    size_t dylib_path_len = strlen(dylib_path);
    size_t dylib_path_size = (dylib_path_len & ~(path_padding - 1)) + path_padding;
    uint32_t cmdsize = (uint32_t)(sizeof(struct dylib_command) + dylib_path_size);

    struct dylib_command dylib_command = {
        .cmd = SWAP32(LC_LOAD_DYLIB, mh.magic),
        .cmdsize = SWAP32(cmdsize, mh.magic),
        .dylib = {
            .name = { .offset = SWAP32(sizeof(struct dylib_command), mh.magic) },
            .timestamp = 0,
            .current_version = 0,
            .compatibility_version = 0
        }
    };

    uint32_t sizeofcmds = SWAP32(mh.sizeofcmds, mh.magic);
    fseeko(f, commands_offset + sizeofcmds, SEEK_SET);

    char *dylib_path_padded = calloc(dylib_path_size, 1);
    memcpy(dylib_path_padded, dylib_path, dylib_path_len);

    fwrite(&dylib_command, sizeof(dylib_command), 1, f);
    fwrite(dylib_path_padded, dylib_path_size, 1, f);
    free(dylib_path_padded);

    mh.ncmds = SWAP32(SWAP32(mh.ncmds, mh.magic) + 1, mh.magic);
    sizeofcmds += cmdsize;
    mh.sizeofcmds = SWAP32(sizeofcmds, mh.magic);

    fseeko(f, header_offset, SEEK_SET);
    fwrite(&mh, sizeof(mh), 1, f);

    return true;
}

bool add_load_command(const char *file_path, const char *dylib_path) {
    FILE *f = fopen(file_path, "r+");
    if (!f) return false;

    fseeko(f, 0, SEEK_END);
    off_t file_size = ftello(f);
    rewind(f);

    uint32_t magic;
    fread(&magic, sizeof(uint32_t), 1, f);

    bool success = false;
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        fseeko(f, 0, SEEK_SET);
        struct fat_header fh;
        fread(&fh, sizeof(fh), 1, f);
        uint32_t nfat_arch = SWAP32(fh.nfat_arch, magic);
        struct fat_arch *archs = malloc(sizeof(struct fat_arch) * nfat_arch);
        fread(archs, sizeof(struct fat_arch) * nfat_arch, 1, f);

        for (uint32_t i = 0; i < nfat_arch; i++) {
            off_t offset = SWAP32(archs[i].offset, magic);
            off_t slice_size = SWAP32(archs[i].size, magic);
            if (insert_dylib(f, offset, dylib_path, &slice_size)) {
                archs[i].size = SWAP32((uint32_t)slice_size, magic);
                success = true;
            }
            if (offset + slice_size > file_size) file_size = offset + slice_size;
        }
        rewind(f);
        fwrite(&fh, sizeof(fh), 1, f);
        fwrite(archs, sizeof(struct fat_arch) * nfat_arch, 1, f);
        free(archs);
    } else if (magic == MH_MAGIC_64 || magic == MH_CIGAM_64 || magic == MH_MAGIC || magic == MH_CIGAM) {
        if (insert_dylib(f, 0, dylib_path, &file_size)) {
            success = true;
        }
    }

    if (success) {
        fflush(f);
        ftruncate(fileno(f), file_size);
    }
    fclose(f);
    return success;
}

void depacify(uint8_t *d, size_t s) {
    uint32_t m = *(uint32_t*)d;
    if (m == MH_MAGIC_64) {
        struct mach_header_64 *h = (struct mach_header_64*)d;
        if (h->cputype == CPU_TYPE_ARM64 && (h->cpusubtype & 0xff) == 2) {
            h->cpusubtype = 0;
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

bool depacify_file_in_place(const char *file_path) {
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

bool strip_code_signature_file(const char *path) {
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

bool resign_executable(const char *tmp_path, const char *original_path) {
    if (!strip_code_signature_file(tmp_path)) {
        return false;
    }

    CFDataRef entitlements = load_entitlements_from_code(original_path);
    bool ok = sign_file(tmp_path, entitlements);
    if (entitlements) CFRelease(entitlements);

    return ok;
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

bool resign_bundle(const char *bundle_path) {
    char exec_path[1024]; // Using 1024 for simplicity, or we could include limits.h for PATH_MAX
    if (!get_bundle_executable_path(bundle_path, exec_path, sizeof(exec_path))) {
        return false;
    }
    if (!strip_code_signature_file(exec_path)) {
        return false;
    }
    return sign_file(exec_path, NULL);
}
