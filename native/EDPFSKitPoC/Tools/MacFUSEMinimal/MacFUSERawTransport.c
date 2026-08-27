#define FUSE_USE_VERSION 31
#define FUSE_DARWIN_ENABLE_EXTENSIONS 0
#include <fuse3/fuse.h>

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

static int g_backing_fd = -1;
static off_t g_backing_size = 0;

static int raw_getattr(const char *path, struct stat *st, struct fuse_file_info *fi) {
    (void)fi;
    memset(st, 0, sizeof(*st));
    if (strcmp(path, "/") == 0) {
        st->st_mode = S_IFDIR | 0755;
        st->st_nlink = 2;
        st->st_ino = 1;
        return 0;
    }
    if (strcmp(path, "/volume.raw") == 0) {
        st->st_mode = S_IFREG | 0600;
        st->st_nlink = 1;
        st->st_size = g_backing_size;
        st->st_ino = 2;
        return 0;
    }
    return -ENOENT;
}

static int raw_readdir(
    const char *path,
    void *buffer,
    fuse_fill_dir_t filler,
    off_t offset,
    struct fuse_file_info *fi,
    enum fuse_readdir_flags flags
) {
    (void)offset;
    (void)fi;
    (void)flags;
    if (strcmp(path, "/") != 0) return -ENOENT;
    filler(buffer, ".", NULL, 0, FUSE_FILL_DIR_DEFAULTS);
    filler(buffer, "..", NULL, 0, FUSE_FILL_DIR_DEFAULTS);
    filler(buffer, "volume.raw", NULL, 0, FUSE_FILL_DIR_DEFAULTS);
    return 0;
}

static int raw_open(const char *path, struct fuse_file_info *fi) {
    (void)fi;
    return strcmp(path, "/volume.raw") == 0 ? 0 : -ENOENT;
}

static int raw_read(
    const char *path,
    char *buffer,
    size_t size,
    off_t offset,
    struct fuse_file_info *fi
) {
    (void)fi;
    if (strcmp(path, "/volume.raw") != 0) return -ENOENT;
    ssize_t count = pread(g_backing_fd, buffer, size, offset);
    return count < 0 ? -errno : (int)count;
}

static int raw_write(
    const char *path,
    const char *buffer,
    size_t size,
    off_t offset,
    struct fuse_file_info *fi
) {
    (void)fi;
    if (strcmp(path, "/volume.raw") != 0) return -ENOENT;
    ssize_t count = pwrite(g_backing_fd, buffer, size, offset);
    return count < 0 ? -errno : (int)count;
}

static int raw_fsync(const char *path, int datasync, struct fuse_file_info *fi) {
    (void)path;
    (void)datasync;
    (void)fi;
    return fsync(g_backing_fd) == 0 ? 0 : -errno;
}

static int raw_statfs(const char *path, struct statfs *st) {
    (void)path;
    memset(st, 0, sizeof(*st));
    st->f_bsize = 4096;
    st->f_iosize = 1024 * 1024;
    st->f_blocks = (uint64_t)((g_backing_size + 4095) / 4096);
    st->f_bfree = st->f_blocks;
    st->f_bavail = st->f_blocks;
    st->f_files = 2;
    st->f_ffree = 1;
    return 0;
}

static struct fuse_operations g_operations = {
    .getattr = raw_getattr,
    .readdir = raw_readdir,
    .open = raw_open,
    .read = raw_read,
    .write = raw_write,
    .fsync = raw_fsync,
    .statfs = raw_statfs,
};

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <backing> [fuse options] <mountpoint>\n", argv[0]);
        return 64;
    }

    const char *backing_path = argv[1];
    g_backing_fd = open(backing_path, O_RDWR | O_CLOEXEC);
    if (g_backing_fd < 0) {
        perror("open backing");
        return 65;
    }

    struct stat st;
    if (fstat(g_backing_fd, &st) != 0) {
        perror("fstat backing");
        close(g_backing_fd);
        return 66;
    }
    if (!S_ISREG(st.st_mode) || st.st_size <= 0) {
        fprintf(stderr, "backing must be a non-empty regular file\n");
        close(g_backing_fd);
        return 67;
    }
    g_backing_size = st.st_size;

    argv[1] = argv[0];
    int status = fuse_main(argc - 1, argv + 1, &g_operations, NULL);
    if (fsync(g_backing_fd) != 0) perror("fsync backing");
    close(g_backing_fd);
    return status;
}
