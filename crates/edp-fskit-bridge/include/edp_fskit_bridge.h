#ifndef EDP_FSKIT_BRIDGE_H
#define EDP_FSKIT_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    EDP_PROBE_SECTOR_SIZE = 512,
    EDP_PROBE_SERIAL_CAPACITY = 128,
    EDP_PROBE_RECOGNIZED = 1,
    EDP_PROBE_NOT_RECOGNIZED = 0,
    EDP_PROBE_INVALID_ARGUMENT = -1,
    EDP_PROBE_SERIAL_BUFFER_TOO_SMALL = -2,

    EDP_RAW_CALLBACK_OK = 0,
    EDP_RAW_IO_OK = 0,
    EDP_RAW_IO_INVALID_ARGUMENT = -10,
    EDP_RAW_IO_READ_FAILED = -11,
};

/** Opaque Rust RawIo handle backed by caller-provided callbacks. */
typedef struct EDPRawIoHandle EDPRawIoHandle;

/**
 * Exact-read callback used by Rust's edp_core::volume::RawIo adapter.
 *
 * Return EDP_RAW_CALLBACK_OK only after filling all `length` output bytes.
 * The callback may be invoked concurrently. `context` must therefore remain
 * alive and be safe for concurrent reads until every Rust handle that depends
 * on it has been destroyed.
 */
typedef int32_t (*EDPRawReadCallback)(
    void *context,
    uint64_t offset,
    uint8_t *out,
    size_t length
);

/**
 * Create a read-only callback-backed RawIo object.
 *
 * `read_callback` must be non-NULL and `size` must be non-zero. `context` may
 * be NULL if the callback does not require caller state. Returns NULL on invalid
 * arguments.
 */
EDPRawIoHandle *edp_raw_io_create(
    void *context,
    EDPRawReadCallback read_callback,
    uint64_t size
);

/** Destroy a handle returned by edp_raw_io_create. NULL is a no-op. */
void edp_raw_io_destroy(EDPRawIoHandle *handle);

/**
 * Exercise RawIo::pread_exact through the callback-backed handle.
 *
 * This is also the regression primitive used before encrypted-volume handles
 * are layered on top of the same RawIo object.
 */
int32_t edp_raw_io_read_exact(
    const EDPRawIoHandle *handle,
    uint64_t offset,
    uint8_t *out,
    size_t length
);

/**
 * Passwordless conservative EDP probe.
 *
 * lba4 and lba7 must each point to exactly one readable 512-byte sector.
 * serial_out must provide serial_capacity writable bytes. A recognized result
 * writes a NUL-terminated serial string.
 */
int32_t edp_probe_reserved_sectors(
    const uint8_t *lba4,
    const uint8_t *lba7,
    char *serial_out,
    size_t serial_capacity
);

#ifdef __cplusplus
}
#endif

#endif /* EDP_FSKIT_BRIDGE_H */
