#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <ptrauth.h>
#include <stdio.h>
#include <string.h>

#import <AppKit/AppKit.h>

#define IMFB_PATH \
    "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"

#define HID_CURSOR_SYMBOL "__ZL26hid_update_cursor_position7CGPointybb"

#if defined(__arm64__) || defined(__aarch64__)
/* movz x0, #0 ; ret */
static const uint8_t kReturnZeroPatch[] = {
    0x00, 0x00, 0x80, 0xD2, 0xC0, 0x03, 0x5F, 0xD6
};
static const mach_vm_size_t kHookSize = 16;
#elif defined(__x86_64__)
/* xor eax, eax ; ret ; nop padding */
static const uint8_t kReturnZeroPatch[] = {
    0x31, 0xC0, 0xC3, 0x90, 0x90, 0x90, 0x90, 0x90
};
static const mach_vm_size_t kHookSize = 14;
#else
#error "unsupported architecture"
#endif

static const uint64_t kPos99999Bits = 0x40F869F000000000ULL; /* 99999.0 as double */

/* ── IMFB swap no-op state ──────────────────────────────────────────── */

#define PATCH_COUNT 3
static uint8_t saved_originals[PATCH_COUNT][sizeof(kReturnZeroPatch)];
static bool    saved_valid = false;

/* ── HID cursor trampoline state ────────────────────────────────────── */

static uint8_t           hid_saved_bytes[16];
static bool              hid_hook_valid = false;
static mach_vm_address_t hid_hook_page  = 0;
static mach_vm_address_t hid_fn_addr    = 0;

/* ── helpers ────────────────────────────────────────────────────────── */

static int
read_remote(task_t task, mach_vm_address_t addr, void *buf, mach_vm_size_t size, const char *label)
{
    mach_vm_size_t read_size = size;
    kern_return_t kr = mach_vm_read_overwrite(task, addr, size, (mach_vm_address_t)buf, &read_size);
    if (kr != KERN_SUCCESS || read_size != size) {
        fprintf(stderr, "[quartz_handler] mach_vm_read_overwrite(%s) @ 0x%llx: %s\n",
                label, (unsigned long long)addr, mach_error_string(kr));
        return -1;
    }
    return 0;
}

static pid_t
find_server_pid(void)
{
    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0) / sizeof(pid_t);
    pid_t *pids = calloc(n, sizeof(pid_t));
    n = proc_listpids(PROC_ALL_PIDS, 0, pids, n * sizeof(pid_t)) / sizeof(pid_t);

    pid_t result = -1;
    for (int i = 0; i < n; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pids[i], path, sizeof(path)) > 0) {
            if (strcmp(path, "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer") == 0) {
                result = pids[i];
                break;
            }
        }
    }
    free(pids);
    return result;
}

static mach_vm_address_t
resolve_symbol(void *handle, const char *name)
{
    void *sym = dlsym(handle, name);
    if (!sym) {
        fprintf(stderr, "[quartz_handler] dlsym(%s): %s\n", name, dlerror());
        return 0;
    }
#if __has_feature(ptrauth_calls)
    sym = ptrauth_strip(sym, ptrauth_key_function_pointer);
#endif
    return (mach_vm_address_t)(uintptr_t)sym;
}

static int
write_remote_text(task_t task, mach_vm_address_t addr,
                  const uint8_t *patch, mach_vm_size_t patch_size, bool cow)
{
    mach_vm_address_t page = addr & ~((mach_vm_address_t)PAGE_SIZE - 1);
    mach_vm_address_t end = (addr + patch_size + PAGE_SIZE - 1) & ~((mach_vm_address_t)PAGE_SIZE - 1);
    mach_vm_size_t span = end - page;

    vm_prot_t rw_prot = VM_PROT_READ | VM_PROT_WRITE;
    if (cow)
        rw_prot |= VM_PROT_COPY;

    kern_return_t kr = mach_vm_protect(task, page, span, FALSE, rw_prot);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[quartz_handler] mach_vm_protect(rw) @ 0x%llx: %s\n",
                (unsigned long long)addr, mach_error_string(kr));
        return -1;
    }

    kr = mach_vm_write(task, addr, (vm_offset_t)patch, (mach_msg_type_number_t)patch_size);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[quartz_handler] mach_vm_write @ 0x%llx: %s\n",
                (unsigned long long)addr, mach_error_string(kr));
        mach_vm_protect(task, page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
        return -1;
    }

    kr = mach_vm_protect(task, page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[quartz_handler] mach_vm_protect(rx) @ 0x%llx: %s\n",
                (unsigned long long)addr, mach_error_string(kr));
        return -1;
    }

    return 0;
}

/* ── find local symbol by walking loaded dyld images ────────────────── */

static mach_vm_address_t
find_symbol_in_images(const char *sym_name)
{
    uint32_t count = _dyld_image_count();
    for (uint32_t img = 0; img < count; img++) {
        const struct mach_header_64 *hdr =
            (const struct mach_header_64 *)_dyld_get_image_header(img);
        if (!hdr || hdr->magic != MH_MAGIC_64)
            continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(img);
        const uint8_t *cmd = (const uint8_t *)hdr + sizeof(*hdr);

        const struct symtab_command *sc = NULL;
        uint64_t le_vmaddr = 0, le_fileoff = 0;

        for (uint32_t i = 0; i < hdr->ncmds; i++) {
            const struct load_command *lc = (const struct load_command *)cmd;
            if (lc->cmd == LC_SYMTAB)
                sc = (const struct symtab_command *)cmd;
            else if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
                if (strncmp(seg->segname, "__LINKEDIT", 16) == 0) {
                    le_vmaddr = seg->vmaddr + (uint64_t)slide;
                    le_fileoff = seg->fileoff;
                }
            }
            cmd += lc->cmdsize;
        }

        if (!sc || !le_vmaddr || sc->nsyms == 0)
            continue;

        const struct nlist_64 *nl =
            (const struct nlist_64 *)(le_vmaddr + (sc->symoff - le_fileoff));
        const char *strtab =
            (const char *)(le_vmaddr + (sc->stroff - le_fileoff));

        for (uint32_t i = 0; i < sc->nsyms; i++) {
            if ((nl[i].n_type & N_TYPE) != N_SECT)
                continue;
            uint32_t strx = nl[i].n_un.n_strx;
            if (strx == 0)
                continue;
            if (strcmp(strtab + strx, sym_name) == 0)
                return (mach_vm_address_t)(nl[i].n_value + slide);
        }
    }
    return 0;
}

/* ── HID cursor trampoline ──────────────────────────────────────────── */
/*
 * Installs a trampoline on hid_update_cursor_position that forces the
 * CGPoint argument to (-512.0, -512.0) before calling the original.
 *
 * arm64 page layout:
 *
 *   [0x00] Trampoline
 *            [0x00..0x0F]  original 16 bytes from fn_addr
 *            [0x10]        LDR x17, #8
 *            [0x14]        BR  x17
 *            [0x18..0x1F]  <fn_addr + 16>
 *
 *   [0x20] Stub (entry hook jumps here)
 *            [0x20]        LDR  d0, #8   → load -512.0 from [0x40]
 *            [0x24]        FMOV d1, d0
 *            [0x28]        LDR  x17, #8  → load trampoline addr from [0x30]
 *            [0x2C]        BR   x17
 *            [0x30..0x37]  <trampoline addr>
 *            [0x38..0x3F]  (padding)
 *            [0x40..0x47]  -512.0 as double
 *
 *   Entry patch at fn_addr (16 bytes):
 *            LDR x17, #8 ; BR x17 ; <stub addr>
 *
 * x86_64 page layout:
 *
 *   [0x00] Trampoline
 *            [0x00..0x0D]  original 14 bytes
 *            [0x0E]        JMP [RIP+0]
 *            [0x14..0x1B]  <fn_addr + 14>
 *
 *   [0x20] Stub
 *            [0x20]        MOVSD xmm0, [RIP+0x18]  → [0x40]
 *            [0x28]        MOVSD xmm1, [RIP+0x10]  → [0x40]
 *            [0x30]        JMP   [RIP+2]            → [0x38]
 *            [0x38..0x3F]  <trampoline addr>
 *            [0x40..0x47]  -512.0 as double
 *
 *   Entry patch at fn_addr (14 bytes):
 *            JMP [RIP+0] ; <stub addr>
 */

static int
install_hid_trampoline(task_t task, mach_vm_address_t fn_addr)
{
    if (read_remote(task, fn_addr, hid_saved_bytes, kHookSize, "hid_cursor") != 0)
        return -1;

    mach_vm_address_t buf = 0;
    kern_return_t kr = mach_vm_allocate(task, &buf, PAGE_SIZE, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[quartz_handler] mach_vm_allocate(hid): %s\n", mach_error_string(kr));
        return -1;
    }

    mach_vm_address_t tramp_addr = buf + 0x00;
    mach_vm_address_t stub_addr  = buf + 0x20;
    uint64_t cont_addr = fn_addr + kHookSize;

    uint8_t page[PAGE_SIZE];
    memset(page, 0, sizeof(page));

#if defined(__arm64__) || defined(__aarch64__)
    /* Trampoline: original bytes + LDR x17,#8 ; BR x17 ; <fn+16> */
    memcpy(page + 0x00, hid_saved_bytes, kHookSize);
    uint32_t ldr_x17_8 = 0x58000051u;
    uint32_t br_x17    = 0xD61F0220u;
    memcpy(page + 0x10, &ldr_x17_8, 4);
    memcpy(page + 0x14, &br_x17, 4);
    memcpy(page + 0x18, &cont_addr, 8);

    /* Stub: LDR d0,#8 ; FMOV d1,d0 ; LDR x17,#8 ; BR x17
     *       [tramp_addr] [pad] [-512.0]                       */
    uint32_t ldr_d0_8    = 0x5C000100u; /* LDR d0, PC+32 → [0x40] */
    uint32_t fmov_d1_d0  = 0x1E604001u; /* FMOV d1, d0             */
    uint32_t ldr_x17_8_s = 0x58000051u; /* LDR x17, PC+8 → [0x30] */
    memcpy(page + 0x20, &ldr_d0_8, 4);
    memcpy(page + 0x24, &fmov_d1_d0, 4);
    memcpy(page + 0x28, &ldr_x17_8_s, 4);
    memcpy(page + 0x2C, &br_x17, 4);
    memcpy(page + 0x30, &tramp_addr, 8);
    memcpy(page + 0x40, &kPos99999Bits, 8);

    /* Entry hook */
    uint8_t entry[16];
    memcpy(entry + 0, &ldr_x17_8, 4);
    memcpy(entry + 4, &br_x17, 4);
    memcpy(entry + 8, &stub_addr, 8);

#elif defined(__x86_64__)
    /* Trampoline: original bytes + JMP [RIP+0] + <fn+14> */
    memcpy(page + 0x00, hid_saved_bytes, kHookSize);
    page[0x0E] = 0xFF; page[0x0F] = 0x25;
    page[0x10] = 0x00; page[0x11] = 0x00;
    page[0x12] = 0x00; page[0x13] = 0x00;
    memcpy(page + 0x14, &cont_addr, 8);

    /* Stub: MOVSD xmm0,[RIP+0x18] ; MOVSD xmm1,[RIP+0x10] ; JMP [RIP+2] */
    page[0x20] = 0xF2; page[0x21] = 0x0F; page[0x22] = 0x10; page[0x23] = 0x05;
    page[0x24] = 0x18; page[0x25] = 0x00; page[0x26] = 0x00; page[0x27] = 0x00;
    page[0x28] = 0xF2; page[0x29] = 0x0F; page[0x2A] = 0x10; page[0x2B] = 0x0D;
    page[0x2C] = 0x10; page[0x2D] = 0x00; page[0x2E] = 0x00; page[0x2F] = 0x00;
    page[0x30] = 0xFF; page[0x31] = 0x25;
    page[0x32] = 0x02; page[0x33] = 0x00; page[0x34] = 0x00; page[0x35] = 0x00;
    memcpy(page + 0x38, &tramp_addr, 8);
    memcpy(page + 0x40, &kPos99999Bits, 8);

    /* Entry hook: JMP [RIP+0] + <stub_addr> */
    uint8_t entry[14];
    entry[0] = 0xFF; entry[1] = 0x25;
    entry[2] = 0x00; entry[3] = 0x00;
    entry[4] = 0x00; entry[5] = 0x00;
    memcpy(entry + 6, &stub_addr, 8);
#endif

    /* Write page into remote process and mark RX */
    kr = mach_vm_write(task, buf, (vm_offset_t)page, PAGE_SIZE);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[quartz_handler] mach_vm_write(hid page): %s\n", mach_error_string(kr));
        mach_vm_deallocate(task, buf, PAGE_SIZE);
        return -1;
    }
    kr = mach_vm_protect(task, buf, PAGE_SIZE, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[quartz_handler] mach_vm_protect(hid page rx): %s\n", mach_error_string(kr));
        mach_vm_deallocate(task, buf, PAGE_SIZE);
        return -1;
    }

    /* Patch fn_addr with entry hook (COW for shared cache pages) */
    if (write_remote_text(task, fn_addr, entry, kHookSize, true) != 0) {
        mach_vm_deallocate(task, buf, PAGE_SIZE);
        return -1;
    }

    hid_hook_page = buf;
    hid_fn_addr   = fn_addr;
    hid_hook_valid = true;

    printf("[quartz_handler] hid_cursor trampoline installed @ 0x%llx → stub 0x%llx\n",
           (unsigned long long)fn_addr, (unsigned long long)stub_addr);
    return 0;
}

static int
remove_hid_trampoline(task_t task)
{
    if (!hid_hook_valid) {
        fprintf(stderr, "[quartz_handler] no hid trampoline to remove\n");
        return -1;
    }

    /* Restore original bytes at fn_addr (page is already COW'd, no need for VM_PROT_COPY) */
    if (write_remote_text(task, hid_fn_addr, hid_saved_bytes, kHookSize, false) != 0)
        return -1;

    /* Free the trampoline page */
    mach_vm_deallocate(task, hid_hook_page, PAGE_SIZE);

    printf("[quartz_handler] hid_cursor trampoline removed @ 0x%llx\n",
           (unsigned long long)hid_fn_addr);

    hid_hook_valid = false;
    hid_hook_page  = 0;
    hid_fn_addr    = 0;
    return 0;
}

/* ── public entry point ─────────────────────────────────────────────── */

void windowserver_HALT(bool cont) {
    pid_t pid = find_server_pid();
    if (pid < 0) {
        fprintf(stderr, "[quartz_handler] WindowServer not found\n");
        return;
    }

    void *handle = dlopen(IMFB_PATH, RTLD_NOW | RTLD_NOLOAD);
    if (!handle)
        handle = dlopen(IMFB_PATH, RTLD_NOW);
    if (!handle) {
        fprintf(stderr, "[quartz_handler] dlopen(IOMobileFramebuffer): %s\n", dlerror());
        return;
    }

    const char *sym_names[] = {
        "IOMobileFramebufferSwapBegin",
        "IOMobileFramebufferSwapSetLayer",
        "IOMobileFramebufferSwapEnd",
    };
    mach_vm_address_t addrs[3];
    for (int i = 0; i < 3; i++) {
        addrs[i] = resolve_symbol(handle, sym_names[i]);
        if (!addrs[i])
            return;
    }

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), (int)pid, &task);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[quartz_handler] task_for_pid(%d): %s\n", pid, mach_error_string(kr));
        return;
    }

    if (cont) {
        /* ── restore ── */
        if (!saved_valid) {
            fprintf(stderr, "[quartz_handler] no saved originals to restore\n");
        } else {
            for (int i = 0; i < PATCH_COUNT; i++) {
                if (write_remote_text(task, addrs[i],
                                      saved_originals[i], sizeof(kReturnZeroPatch),
                                      false) == 0)
                    printf("[quartz_handler] restored %s @ 0x%llx\n",
                           sym_names[i], (unsigned long long)addrs[i]);
            }
            saved_valid = false;
        }

        remove_hid_trampoline(task);

        [NSCursor unhide];

    } else {
        [NSCursor hide];

        /* ── patch IMFB swaps to no-ops ── */
        for (int i = 0; i < PATCH_COUNT; i++) {
            if (read_remote(task, addrs[i], saved_originals[i],
                            sizeof(kReturnZeroPatch), sym_names[i]) != 0) {
                mach_port_deallocate(mach_task_self(), task);
                return;
            }
        }
        saved_valid = true;
        for (int i = 0; i < PATCH_COUNT; i++) {
            if (write_remote_text(task, addrs[i],
                                  kReturnZeroPatch, sizeof(kReturnZeroPatch),
                                  true) == 0)
                printf("[quartz_handler] patched %s @ 0x%llx\n",
                       sym_names[i], (unsigned long long)addrs[i]);
        }

        /* ── install HID cursor trampoline ── */
        mach_vm_address_t hid_addr = find_symbol_in_images(HID_CURSOR_SYMBOL);
        if (!hid_addr)
            fprintf(stderr, "[quartz_handler] %s not found in loaded images\n", HID_CURSOR_SYMBOL);
        else
            install_hid_trampoline(task, hid_addr);
    }

    mach_port_deallocate(mach_task_self(), task);
}
