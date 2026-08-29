#ifndef EDPOPEN_FFI_H
#define EDPOPEN_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *edp_core_version(void);
uint32_t edp_core_crc32(const uint8_t *data, size_t len);

char *edp_decode_sector_json(
    uint64_t lba,
    const uint8_t *raw,
    size_t raw_len,
    int32_t has_identity,
    uint32_t crc,
    uint16_t k0,
    const char *vid,
    const char *pid,
    uint64_t size_bytes
);

void edp_string_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif
