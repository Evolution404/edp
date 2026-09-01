#ifndef EDP_RAW_VALIDATION_H
#define EDP_RAW_VALIDATION_H

int edp_open_validated_raw_device(const char *raw_device);
int edp_fd_has_edp_metadata(int fd);

#endif
