#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "attrib.h"
#include "endians.h"
#include "inode.h"
#include "layout.h"
#include "logfile.h"
#include "volume.h"

static int write_dirty_restart_page(ntfs_attr *log_na, s64 offset) {
    const u32 page_size = 4096;
    unsigned char *buffer = calloc(1, page_size);
    if (!buffer) {
        return -ENOMEM;
    }

    RESTART_PAGE_HEADER *header = (RESTART_PAGE_HEADER *)buffer;
    header->magic = magic_CHKD;
    header->usa_ofs = const_cpu_to_le16(0);
    header->usa_count = const_cpu_to_le16(0);
    header->chkdsk_lsn = const_cpu_to_sle64(0);
    header->system_page_size = cpu_to_le32(page_size);
    header->log_page_size = cpu_to_le32(page_size);
    header->restart_area_offset = const_cpu_to_le16(sizeof(RESTART_PAGE_HEADER));
    header->minor_ver = const_cpu_to_sle16(1);
    header->major_ver = const_cpu_to_sle16(1);
    header->usn = const_cpu_to_le16(0);

    RESTART_AREA *area = (RESTART_AREA *)(buffer + sizeof(RESTART_PAGE_HEADER));
    area->current_lsn = const_cpu_to_sle64(0);
    area->log_clients = const_cpu_to_le16(1);
    area->client_free_list = LOGFILE_NO_CLIENT;
    area->client_in_use_list = const_cpu_to_le16(0);
    area->flags = const_cpu_to_le16(0);

    u64 file_size = (u64)log_na->data_size;
    u8 file_size_bits = 0;
    for (u64 value = file_size; value; value >>= 1) {
        file_size_bits++;
    }
    if (!file_size_bits || file_size_bits >= 67) {
        free(buffer);
        return -EINVAL;
    }

    area->seq_number_bits = cpu_to_le32(67 - file_size_bits);
    area->client_array_offset = const_cpu_to_le16(sizeof(RESTART_AREA));
    area->restart_area_length = cpu_to_le16(sizeof(RESTART_AREA) + sizeof(LOG_CLIENT_RECORD));
    area->file_size = cpu_to_sle64((s64)file_size);
    area->last_lsn_data_length = const_cpu_to_le32(0);
    area->log_record_header_length = const_cpu_to_le16(LOG_RECORD_HEAD_SZ);
    area->log_page_data_offset = const_cpu_to_le16(0x40);
    area->restart_log_open_count = const_cpu_to_le32(1);
    area->reserved = const_cpu_to_le32(0);

    LOG_CLIENT_RECORD *client = (LOG_CLIENT_RECORD *)((unsigned char *)area + sizeof(RESTART_AREA));
    client->oldest_lsn = const_cpu_to_sle64(0);
    client->client_restart_lsn = const_cpu_to_sle64(0);
    client->prev_client = LOGFILE_NO_CLIENT;
    client->next_client = LOGFILE_NO_CLIENT;
    client->seq_number = const_cpu_to_le16(0);
    client->client_name_length = const_cpu_to_le32(8);
    client->client_name[0] = const_cpu_to_le16('N');
    client->client_name[1] = const_cpu_to_le16('T');
    client->client_name[2] = const_cpu_to_le16('F');
    client->client_name[3] = const_cpu_to_le16('S');

    s64 written = ntfs_attr_pwrite(log_na, offset, page_size, buffer);
    free(buffer);
    if (written != page_size) {
        return -(errno ? errno : EIO);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <clean-ntfs-image>\n", argv[0]);
        return 64;
    }

    ntfs_volume *volume = ntfs_mount(argv[1], 0);
    if (!volume) {
        perror("ntfs_mount");
        return 65;
    }

    int result = 0;
    ntfs_inode *log_inode = ntfs_inode_open(volume, FILE_LogFile);
    if (!log_inode) {
        perror("ntfs_inode_open($LogFile)");
        result = 66;
        goto unmount;
    }

    ntfs_attr *log_data = ntfs_attr_open(log_inode, AT_DATA, AT_UNNAMED, 0);
    if (!log_data) {
        perror("ntfs_attr_open($LogFile::$DATA)");
        result = 67;
        goto close_inode;
    }

    if (log_data->data_size < 8192) {
        fprintf(stderr, "$LogFile is unexpectedly small: %lld\n", (long long)log_data->data_size);
        result = 68;
        goto close_attr;
    }

    int err = write_dirty_restart_page(log_data, 0);
    if (!err) {
        err = write_dirty_restart_page(log_data, 4096);
    }
    if (err) {
        fprintf(stderr, "failed to write synthetic unclean restart pages: %d\n", -err);
        result = 69;
        goto close_attr;
    }

    printf("NTFS_LOGFILE_BYTES=%lld\n", (long long)log_data->data_size);
    printf("RESULT=NTFS_UNCLEAN_LOGFILE_FIXTURE_WRITTEN\n");

close_attr:
    ntfs_attr_close(log_data);
close_inode:
    if (ntfs_inode_close(log_inode) && !result) {
        result = 71;
    }
unmount:
    if (ntfs_umount(volume, 0) && !result) {
        result = 72;
    }
    return result;
}
