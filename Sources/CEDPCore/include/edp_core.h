#ifndef EDP_CORE_H
#define EDP_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct edp_sm4_context edp_sm4_context;

/// Create an SM4-ECB context for a 16-byte key. Returns NULL on invalid input/allocation failure.
edp_sm4_context *edp_sm4_create(const uint8_t *key, size_t key_len);

/// Zeroizes and releases a context created by edp_sm4_create().
void edp_sm4_destroy(edp_sm4_context *ctx);

/// Encrypt/decrypt a whole number of 16-byte blocks. Input/output may be the same buffer.
/// Returns 0 on success, -1 on invalid arguments.
int edp_sm4_encrypt(const edp_sm4_context *ctx, const uint8_t *input, uint8_t *output, size_t length);
int edp_sm4_decrypt(const edp_sm4_context *ctx, const uint8_t *input, uint8_t *output, size_t length);

/// Bare reflected CRC32 used by the EDP format: init=0, poly=0xEDB88320, no final xor.
uint32_t edp_crc32_bare(const uint8_t *data, size_t length);

/// Human-readable backend name used by benchmarks/diagnostics.
const char *edp_sm4_backend_name(void);

#ifdef __cplusplus
}
#endif

#endif
