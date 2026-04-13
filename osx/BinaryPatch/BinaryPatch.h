#ifndef BINARY_PATCH_H
#define BINARY_PATCH_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void depacify(uint8_t *d, size_t s);
bool depacify_file_in_place(const char *file_path);
bool add_load_command(const char *file_path, const char *dylib_path);
bool strip_code_signature_file(const char *path);
bool resign_executable(const char *tmp_path, const char *original_path);
bool resign_bundle(const char *bundle_path);

#ifdef __cplusplus
}
#endif

#endif // BINARY_PATCH_H
