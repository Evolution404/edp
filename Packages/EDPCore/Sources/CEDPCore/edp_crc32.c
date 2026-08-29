#include "edp_core.h"

uint32_t edp_crc32_bare(const uint8_t *data, size_t length) {
    if (!data && length != 0) return 0;
    uint32_t crc = 0;
    for (size_t i = 0; i < length; ++i) {
        uint32_t value = (crc ^ data[i]) & 0xffU;
        for (unsigned bit = 0; bit < 8; ++bit) {
            value = (value & 1U) ? (0xedb88320U ^ (value >> 1)) : (value >> 1);
        }
        crc = value ^ (crc >> 8);
    }
    return crc;
}
