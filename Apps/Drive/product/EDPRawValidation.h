#ifndef EDP_RAW_VALIDATION_H
#define EDP_RAW_VALIDATION_H

enum edp_raw_validation_error {
    EDP_RAW_VALIDATION_OK = 0,
    EDP_RAW_VALIDATION_TARGET = 1001,
    EDP_RAW_VALIDATION_PATH_BEFORE = 1002,
    EDP_RAW_VALIDATION_FSTAT = 1003,
    EDP_RAW_VALIDATION_PATH_AFTER = 1004,
    EDP_RAW_VALIDATION_RDEV_CHANGED = 1005,
    EDP_RAW_VALIDATION_MEDIA_CHANGED = 1006,
    EDP_RAW_VALIDATION_METADATA = 1007,
};

int edp_open_validated_raw_device(const char *raw_device);
int edp_open_validated_raw_device_diagnostic(const char *raw_device, int *out_error_code);
int edp_fd_has_edp_metadata(int fd);

#endif
