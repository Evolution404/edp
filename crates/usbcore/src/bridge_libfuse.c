#define FUSE_USE_VERSION 26
#include <fuse.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

#define EDP_VIRTUAL_PATH "/volume.raw"
#define EDP_REQUEST_BYTES (1024 * 1024)

extern int64_t edp_bridge_read(void *ctx, uint64_t offset, void *buf, size_t size);
extern int64_t edp_bridge_write(void *ctx, uint64_t offset, const void *buf, size_t size);
extern int edp_bridge_sync(void *ctx);

/* One bridge process serves exactly one EDP volume, so a process-global context
 * is simpler and more robust than fuse_get_context()->private_data. FSKit does
 * not provide normal caller context information to FUSE servers. */
static void *g_ctx = NULL;
static uint64_t g_size = 0;
static int g_readonly = 0;

static int edp_getattr(const char *path, struct stat *st) {
    memset(st, 0, sizeof(*st));
    st->st_uid = getuid();
    st->st_gid = getgid();
    st->st_blksize = EDP_REQUEST_BYTES;

    if (strcmp(path, "/") == 0) {
        st->st_mode = S_IFDIR | 0700;
        st->st_nlink = 2;
        return 0;
    }
    if (strcmp(path, EDP_VIRTUAL_PATH) == 0) {
        st->st_mode = S_IFREG | (g_readonly ? 0400 : 0600);
        st->st_nlink = 1;
        st->st_size = (off_t)g_size;
        st->st_blocks = (blkcnt_t)((g_size + 511) / 512);
        return 0;
    }
    return -ENOENT;
}

static int edp_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                       off_t offset, struct fuse_file_info *fi) {
    (void)offset;
    (void)fi;
    if (strcmp(path, "/") != 0) {
        return -ENOTDIR;
    }
    filler(buf, ".", NULL, 0);
    filler(buf, "..", NULL, 0);
    filler(buf, "volume.raw", NULL, 0);
    return 0;
}

static int edp_open(const char *path, struct fuse_file_info *fi) {
    if (strcmp(path, EDP_VIRTUAL_PATH) != 0) {
        return -ENOENT;
    }
    if ((fi->flags & O_TRUNC) != 0) {
        return -EPERM;
    }
    /* FSKit currently opens files read/write even for logical read-only access.
     * Accept the open and enforce read-only semantics in write/truncate. */
    return 0;
}

static int edp_read(const char *path, char *buf, size_t size, off_t offset,
                    struct fuse_file_info *fi) {
    (void)fi;
    if (strcmp(path, EDP_VIRTUAL_PATH) != 0) {
        return -ENOENT;
    }
    if (offset < 0) {
        return -EINVAL;
    }
    int64_t rc = edp_bridge_read(g_ctx, (uint64_t)offset, buf, size);
    if (rc < 0) {
        return (int)rc;
    }
    return (int)rc;
}

static int edp_write(const char *path, const char *buf, size_t size, off_t offset,
                     struct fuse_file_info *fi) {
    (void)fi;
    if (strcmp(path, EDP_VIRTUAL_PATH) != 0) {
        return -ENOENT;
    }
    if (g_readonly) {
        return -EROFS;
    }
    if (offset < 0) {
        return -EINVAL;
    }
    int64_t rc = edp_bridge_write(g_ctx, (uint64_t)offset, buf, size);
    if (rc < 0) {
        return (int)rc;
    }
    return (int)rc;
}

static int edp_truncate(const char *path, off_t size) {
    if (strcmp(path, EDP_VIRTUAL_PATH) != 0) {
        return -ENOENT;
    }
    if (g_readonly) {
        return -EROFS;
    }
    return ((uint64_t)size == g_size) ? 0 : -EPERM;
}

static int edp_ftruncate(const char *path, off_t size, struct fuse_file_info *fi) {
    (void)fi;
    return edp_truncate(path, size);
}

static int edp_flush(const char *path, struct fuse_file_info *fi) {
    (void)fi;
    if (strcmp(path, EDP_VIRTUAL_PATH) != 0) {
        return -ENOENT;
    }
    return edp_bridge_sync(g_ctx);
}

static int edp_fsync(const char *path, int datasync, struct fuse_file_info *fi) {
    (void)datasync;
    return edp_flush(path, fi);
}

static int edp_statfs(const char *path, struct statvfs *st) {
    (void)path;
    memset(st, 0, sizeof(*st));
    st->f_bsize = 4096;
    st->f_frsize = 4096;
    st->f_blocks = (fsblkcnt_t)((g_size + 4095) / 4096);
    st->f_bfree = 0;
    st->f_bavail = 0;
    st->f_files = 2;
    st->f_ffree = 0;
    st->f_favail = 0;
    st->f_namemax = 255;
    return 0;
}

int edp_fuse_run(void *ctx, const char *mountpoint, uint64_t size, int readonly) {
    g_ctx = ctx;
    g_size = size;
    g_readonly = readonly;

    struct fuse_operations ops;
    memset(&ops, 0, sizeof(ops));
    ops.getattr = edp_getattr;
    ops.readdir = edp_readdir;
    ops.open = edp_open;
    ops.read = edp_read;
    ops.write = edp_write;
    ops.truncate = edp_truncate;
    ops.ftruncate = edp_ftruncate;
    ops.flush = edp_flush;
    ops.fsync = edp_fsync;
    ops.statfs = edp_statfs;

    /* On macOS 15.x, macFUSE automatically selects the local FSKit module.
     * Do not force the experimental `local` option. Match the known-good
     * macFUSE 5.3.3 / macOS 15.7 path and make the mount owner explicit. */
    char options[512];
    snprintf(options, sizeof(options),
             "backend=fskit,uid=%u,gid=%u,nobrowse,noappledouble,volname=EDP Raw Bridge",
             (unsigned)getuid(), (unsigned)getgid());

    char *argv[] = {
        (char *)"edp-usb-bridge",
        (char *)"-f",
        (char *)"-o",
        options,
        (char *)mountpoint,
        NULL,
    };
    int argc = 5;
    return fuse_main(argc, argv, &ops, NULL);
}
