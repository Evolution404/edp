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
};

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
