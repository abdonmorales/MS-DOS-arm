// SPDX-License-Identifier: MIT
// Host stress test for src/fat.S. Built for Linux AArch64 and run under
// qemu-aarch64: firmware services are faked, and the "partition" is a raw
// FAT image file on the host. tools/fat_test.py prepares images with mtools,
// runs this program, then checks the result with fsck.fat and mtools.
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

typedef uint64_t status;
#define ERR(c) (0x8000000000000000ull | (c))
#define NOT_FOUND ERR(14)
#define DENIED ERR(15)
#define TOO_SMALL ERR(5)

typedef struct file file;
struct file {
    uint64_t revision;
    status (*open)(file *, file **, const uint16_t *, uint64_t, uint64_t);
    status (*close)(file *);
    status (*del)(file *);
    status (*read)(file *, uint64_t *, void *);
    status (*write)(file *, uint64_t *, const void *);
    status (*getpos)(file *, uint64_t *);
    status (*setpos)(file *, uint64_t);
    status (*getinfo)(file *, const void *, uint64_t *, void *);
    status (*setinfo)(file *, const void *, uint64_t, void *);
    status (*flush)(file *);
};

struct media { uint32_t id; uint8_t removable, present, logical, ro, caching;
               uint8_t pad[3]; uint32_t block, align; uint64_t last; };
struct blockio { uint64_t revision; struct media *media; void *reset;
    status (*read)(struct blockio *, uint32_t, uint64_t, uint64_t, void *);
    status (*write)(struct blockio *, uint32_t, uint64_t, uint64_t, const void *);
    status (*flush)(struct blockio *); };

extern void *boot_services, *image_handle, *root_directory;
extern const uint8_t file_info_guid[16], loaded_image_guid[16];
status fat_mount(void);
status fat_unmount(void);

static uint8_t *disk;
static uint64_t disk_bytes, reads, writes;
static struct media media = { .id = 7, .present = 1 };
static void check_transfer(const char *what, uint64_t lba, uint64_t n, const void *buf);
static void violation(int code, const char *fmt, ...);
static int fuzz_mode, ro_armed;
// Like firmware: refuse LBAs past the last block before any arithmetic.
static int bad_range(uint64_t lba, uint64_t n) {
    return n % media.block || lba > media.last || n / media.block > media.last + 1 - lba ||
           lba * media.block + n > disk_bytes;
}
static status bio_read(struct blockio *b, uint32_t id, uint64_t lba, uint64_t n, void *buf) {
    (void)b;
    if (id != media.id || bad_range(lba, n)) return ERR(2);
    check_transfer("read", lba, n, buf);
    memcpy(buf, disk + lba * media.block, n); reads++; return 0;
}
static status bio_write(struct blockio *b, uint32_t id, uint64_t lba, uint64_t n, const void *buf) {
    (void)b;
    if (fuzz_mode && ro_armed) violation(96, "write to LBA %llu during a read-only run", (unsigned long long)lba);
    if (fuzz_mode && lba == 0) violation(95, "write to the boot sector");
    if (id != media.id || bad_range(lba, n)) return ERR(2);
    check_transfer("write", lba, n, buf);
    memcpy(disk + lba * media.block, buf, n); writes++; return 0;
}
static status bio_flush(struct blockio *b) { (void)b; return 0; }
static struct blockio bio = { .media = &media, .read = bio_read, .write = bio_write, .flush = bio_flush };
static const uint8_t block_io_guid[16] = {0x21,0x5b,0x4e,0x96,0x59,0x64,0xd2,0x11,
                                          0x8e,0x39,0x00,0xa0,0xc9,0x69,0x72,0x3b};
static const uint8_t fs_info_guid[16] = {0x93,0x6e,0x57,0x09,0x3f,0x6d,0xd2,0x11,
                                         0x8e,0x39,0x00,0xa0,0xc9,0x69,0x72,0x3b};
static struct { uint32_t rev; uint32_t pad; void *parent, *system, *device; } loaded = { .device = (void *)0x1234 };
static status handle_protocol(void *handle, const uint8_t *guid, void **out) {
    if (!memcmp(guid, loaded_image_guid, 16) && handle == (void *)0x99) { *out = &loaded; return 0; }
    if (!memcmp(guid, block_io_guid, 16) && handle == (void *)0x1234) { *out = &bio; return 0; }
    return NOT_FOUND;
}
// Fuzz mode (tools/fuzz_fat.py): every page the driver gets from
// AllocatePages sits between PROT_NONE guard pages, the disk image too, and
// each Block I/O transfer must land inside one such allocation.
static struct { uint8_t *base; uint64_t bytes; } regions[16];
static int nregions;
static void *guarded(uint64_t bytes) {
    uint64_t span = (bytes + 4095) & ~4095ull;
    uint8_t *p = mmap(NULL, span + 2 * 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return NULL;
    if (span && mprotect(p + 4096, span, PROT_READ | PROT_WRITE)) return NULL;
    // Put the end of the buffer right against the upper guard page.
    return p + 4096 + (span - bytes);
}
static void violation(int code, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fprintf(stderr, "VIOLATION: "); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
    va_end(ap); fflush(stderr); _exit(code);
}
static void check_transfer(const char *what, uint64_t lba, uint64_t n, const void *buf) {
    if (!fuzz_mode) return;
    const uint8_t *b = buf;
    for (int i = 0; i < nregions; i++)
        if (b >= regions[i].base && n <= regions[i].bytes && b + n <= regions[i].base + regions[i].bytes)
            return;
    violation(97, "%s of %llu bytes at LBA %llu with buffer %p outside driver memory", what,
              (unsigned long long)n, (unsigned long long)lba, buf);
}
static status allocate_pages(uint64_t type, uint64_t mem, uint64_t pages, uint64_t *addr) {
    (void)type; (void)mem;
    if (fuzz_mode) {
        void *g = guarded(pages * 4096);
        if (!g || nregions == 16) return ERR(9);
        regions[nregions].base = g; regions[nregions++].bytes = pages * 4096;
        *addr = (uint64_t)g; return 0;
    }
    void *p = aligned_alloc(4096, pages * 4096);
    if (!p) return ERR(9);
    *addr = (uint64_t)p; return 0;
}
static int reinstalled;
static status reinstall(void *h, const uint8_t *g, void *a, void *b) {
    (void)g; (void)a; (void)b; reinstalled = h == (void *)0x1234; return 0;
}
static void *services[64];

static int failures;
static void fail(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fprintf(stderr, "FAIL: "); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
    va_end(ap); failures++;
}
#define CHECK(cond, ...) do { if (!(cond)) fail(__VA_ARGS__); } while (0)

static uint16_t *w(const char *s) {
    static uint16_t buf[4][300]; static int k; uint16_t *o = buf[k++ & 3];
    size_t i = 0; for (; s[i]; i++) o[i] = (uint8_t)s[i]; o[i] = 0; return o;
}
static file *root(void) { return (file *)root_directory; }
static status op(const char *path, uint64_t mode, uint64_t attr, file **out) {
    return root()->open(root(), out, w(path), mode, attr);
}
#define RD 1ull
#define RW 3ull
#define CR 0x8000000000000003ull

static uint8_t info[2048];
static status get_info(file *f) { uint64_t n = sizeof info; return f->getinfo(f, file_info_guid, &n, info); }
static uint64_t info_size(void) { return *(uint64_t *)(info + 8); }
static uint64_t info_attr(void) { return *(uint64_t *)(info + 72); }
static void info_name(char *out) { uint16_t *n = (uint16_t *)(info + 80); int i = 0; while ((out[i] = (char)n[i])) i++; }

static uint8_t pattern(uint64_t seed, uint64_t i) { return (uint8_t)((i * 131 + seed * 7 + (i >> 9)) ^ (i >> 3)); }

static void write_all(const char *path, const void *data, uint64_t n, uint64_t chunk) {
    file *f; status s = op(path, CR, 0, &f);
    if (s) { fail("create %s: %llx", path, (unsigned long long)s); return; }
    const uint8_t *p = data;
    for (uint64_t off = 0; off < n;) {
        uint64_t c = n - off < chunk ? n - off : chunk;
        uint64_t m = c; s = f->write(f, &m, p + off);
        if (s || m != c) { fail("write %s at %llu: %llx", path, (unsigned long long)off, (unsigned long long)s); break; }
        off += c;
    }
    f->close(f);
}
static uint8_t *read_all(const char *path, uint64_t *n) {
    file *f; status s = op(path, RD, 0, &f);
    if (s) { fail("open %s: %llx", path, (unsigned long long)s); *n = 0; return NULL; }
    get_info(f); uint64_t size = info_size();
    uint8_t *buf = malloc(size + 1); uint64_t got = 0;
    while (1) {
        uint64_t m = 777; s = f->read(f, &m, buf + got);
        if (s) { fail("read %s: %llx", path, (unsigned long long)s); break; }
        if (!m) break;
        got += m;
        if (got > size) { fail("read past size %s", path); break; }
    }
    CHECK(got == size, "short read %s %llu/%llu", path, (unsigned long long)got, (unsigned long long)size);
    f->close(f); *n = got; return buf;
}
static void expect_file(const char *path, const void *data, uint64_t n) {
    uint64_t got; uint8_t *b = read_all(path, &got);
    if (!b) return;
    if (data) CHECK(got == n && !memcmp(b, data, n), "content mismatch %s (%llu vs %llu)", path,
          (unsigned long long)got, (unsigned long long)n);
    free(b);
}
static int list_dir(const char *path, char names[][64], int max) {
    file *d; if (op(path, RD, 0, &d)) { fail("open dir %s", path); return 0; }
    int k = 0;
    while (1) {
        uint64_t n = 40; status s = d->read(d, &n, info);
        if (s == TOO_SMALL) { CHECK(n > 80, "too-small size"); n = sizeof info; s = d->read(d, &n, info); }
        if (s) { fail("dir read %s: %llx", path, (unsigned long long)s); break; }
        if (!n) break;
        if (k < max) info_name(names[k]);
        k++;
    }
    d->close(d); return k;
}
static int in_list(char names[][64], int n, const char *x) {
    for (int i = 0; i < n; i++)
        if (!strcmp(names[i], x)) return 1;
    return 0;
}
static status rename_to(const char *from, const char *to) {
    file *f; status s = op(from, RW, 0, &f); if (s) return s;
    get_info(f);
    uint16_t *n = (uint16_t *)(info + 80); size_t i = 0;
    for (; to[i]; i++) n[i] = (uint8_t)to[i];
    n[i] = 0;
    *(uint64_t *)info = 80 + (i + 1) * 2;
    s = f->setinfo(f, file_info_guid, *(uint64_t *)info, info);
    f->close(f); return s;
}

// ---------------------------------------------------------------------------
// Fuzz run over a possibly corrupt image. Errors are fine; the harness only
// reports crashes (signals), hangs (the caller's timeout), Block I/O outside
// the driver's memory or the disk, and writes during a read-only run. Work is
// capped so a valid but large tree cannot look like a hang.
static int fz_entries, fz_dirs, fz_files;
static uint64_t fz_bytes;
static uint8_t fz_buf[70000];
static uint16_t fz_wpath[600];
static uint16_t *fz_w(const char *s) {
    size_t i = 0; for (; s[i] && i < 599; i++) fz_wpath[i] = (uint8_t)s[i];
    fz_wpath[i] = 0; return fz_wpath;
}
static status fz_open(file *dir, const char *path, uint64_t mode, uint64_t attr, file **out) {
    *out = NULL;
    status s = dir->open(dir, out, fz_w(path), mode, attr);
    if (s) *out = NULL;
    return s;
}
static void fz_close(file *f) { if (f) f->close(f); }
// Read a file in uneven chunks, seek around, query its info.
static void fz_read_file(file *f) {
    uint64_t n = sizeof info; f->getinfo(f, file_info_guid, &n, info);
    static const uint64_t chunks[] = {1, 511, 512, 4096, 7777, 65536};
    uint64_t total = 0;
    for (int i = 0; total < 200000 && fz_bytes < 4000000; i++) {
        uint64_t m = chunks[i % 6];
        status s = f->read(f, &m, fz_buf);
        if (s || !m) break;
        if (m > chunks[i % 6]) violation(94, "read returned %llu bytes for a %llu-byte buffer",
                                         (unsigned long long)m, (unsigned long long)chunks[i % 6]);
        total += m; fz_bytes += m;
    }
    uint64_t pos;
    f->setpos(f, 3000); { uint64_t m = 600; f->read(f, &m, fz_buf); }
    f->setpos(f, ~0ull); f->getpos(f, &pos);
    { uint64_t m = 16; f->read(f, &m, fz_buf); }
    f->setpos(f, 0x7ffffff0ull); { uint64_t m = 64; f->read(f, &m, fz_buf); }
}
static void fz_walk(file *dir, const char *path, int depth) {
    if (fz_dirs++ > 150 || depth > 8) return;
    char sub[600];
    for (int k = 0; fz_entries < 3000; k++) {
        uint64_t n = 40;
        status s = dir->read(dir, &n, info);
        if (s == TOO_SMALL) {
            if (n > sizeof info) violation(94, "directory entry claims %llu bytes", (unsigned long long)n);
            n = sizeof info; s = dir->read(dir, &n, info);
        }
        if (s || !n) break;
        if (n > sizeof info) violation(94, "directory read overflow %llu", (unsigned long long)n);
        fz_entries++;
        char name[300]; uint16_t *u = (uint16_t *)(info + 80); int i = 0;
        for (; i < 299 && u[i]; i++) name[i] = (char)u[i];
        name[i] = 0;
        uint64_t attr = info_attr();
        if (!strcmp(name, ".") || !strcmp(name, "..") || !name[0]) continue;
        snprintf(sub, sizeof sub, "%s\\%s", path, name);
        file *f;
        // Alternate between relative opens and absolute paths.
        if (k & 1) fz_open(dir, name, RD, 0, &f); else fz_open(root(), sub, RD, 0, &f);
        if (!f) continue;
        if (attr & 0x10) fz_walk(f, sub, depth + 1);
        else if (fz_files++ < 400) fz_read_file(f);
        fz_close(f);
    }
}
static void fz_write_tests(void) {
    file *f, *g;
    // A new file: write, rewrite, grow, shrink, delete.
    if (!fz_open(root(), "\\FUZZNEW.TXT", CR, 0, &f)) {
        for (uint64_t i = 0; i < 9000; i++) fz_buf[i] = (uint8_t)(i * 7);
        uint64_t m = 9000; f->write(f, &m, fz_buf);
        f->setpos(f, 100); m = 50; f->write(f, &m, fz_buf);
        f->setpos(f, 0); m = 9000; f->read(f, &m, fz_buf);
        uint64_t n = sizeof info;
        if (!f->getinfo(f, file_info_guid, &n, info)) {
            *(uint64_t *)(info + 8) = 20000; f->setinfo(f, file_info_guid, *(uint64_t *)info, info);
            *(uint64_t *)(info + 8) = 10; f->setinfo(f, file_info_guid, *(uint64_t *)info, info);
        }
        f->del(f);
    }
    // A directory with a long-named file, renames, a move, then cleanup.
    if (!fz_open(root(), "\\Fuzz Directory", CR, 0x10, &f)) {
        if (!fz_open(f, "a long file name inside.txt", CR, 0, &g)) {
            uint64_t m = 3000; g->write(g, &m, fz_buf);
            uint64_t n = sizeof info;
            if (!g->getinfo(g, file_info_guid, &n, info)) {
                uint16_t *nm = (uint16_t *)(info + 80); const char *to = "\\moved out.txt"; int i = 0;
                for (; to[i]; i++) nm[i] = (uint8_t)to[i];
                nm[i] = 0; *(uint64_t *)info = 80 + (i + 1) * 2;
                g->setinfo(g, file_info_guid, *(uint64_t *)info, info);
            }
            g->del(g);
        }
        uint64_t n = sizeof info;
        if (!f->getinfo(f, file_info_guid, &n, info)) {
            uint16_t *nm = (uint16_t *)(info + 80); const char *to = "Fuzz Renamed"; int i = 0;
            for (; to[i]; i++) nm[i] = (uint8_t)to[i];
            nm[i] = 0; *(uint64_t *)info = 80 + (i + 1) * 2;
            f->setinfo(f, file_info_guid, *(uint64_t *)info, info);
        }
        f->del(f);
    }
    // Existing objects: the first file and directory the listing finds.
    file *d; if (fz_open(root(), "\\", RD, 0, &d)) return;
    char fname[300] = "", dname[300] = "";
    for (int k = 0; k < 600 && (!fname[0] || !dname[0]); k++) {
        uint64_t n = sizeof info;
        if (d->read(d, &n, info) || !n) break;
        char name[300]; uint16_t *u = (uint16_t *)(info + 80); int i = 0;
        for (; i < 299 && u[i]; i++) name[i] = (char)u[i];
        name[i] = 0;
        if (!strcmp(name, ".") || !strcmp(name, "..") || !name[0] || strchr(name, '\\')) continue;
        if (info_attr() & 0x10) { if (!dname[0]) strcpy(dname, name); }
        else if (!fname[0]) strcpy(fname, name);
    }
    fz_close(d);
    if (dname[0] && !fz_open(root(), dname, RD, 0, &d)) {
        // Create and delete inside an existing (maybe corrupt) directory.
        if (!fz_open(d, "NEWFILE.DAT", CR, 0, &f)) { uint64_t m = 700; f->write(f, &m, fz_buf); f->del(f); }
        if (!fz_open(d, "new sub dir", CR, 0x10, &f)) f->del(f);
        fz_close(d);
    }
    if (fname[0] && !fz_open(root(), fname, RW, 0, &f)) {
        uint64_t n = sizeof info, size = 0;
        if (!f->getinfo(f, file_info_guid, &n, info)) size = info_size();
        f->setpos(f, ~0ull); uint64_t m = 777; f->write(f, &m, fz_buf);
        f->setpos(f, 10); m = 5000; f->write(f, &m, fz_buf);
        n = sizeof info;
        if (!f->getinfo(f, file_info_guid, &n, info)) {
            *(uint64_t *)(info + 8) = size; f->setinfo(f, file_info_guid, *(uint64_t *)info, info);
            uint16_t *nm = (uint16_t *)(info + 80); const char *to = "renamed by fuzz.txt"; int i = 0;
            for (; to[i]; i++) nm[i] = (uint8_t)to[i];
            nm[i] = 0; *(uint64_t *)info = 80 + (i + 1) * 2;
            f->setinfo(f, file_info_guid, *(uint64_t *)info, info);
            if (dname[0]) {    // move it into the directory found above
                char to2[320]; snprintf(to2, sizeof to2, "\\%s\\moved.txt", dname);
                for (i = 0; to2[i]; i++) nm[i] = (uint8_t)to2[i];
                nm[i] = 0; *(uint64_t *)info = 80 + (i + 1) * 2;
                f->setinfo(f, file_info_guid, *(uint64_t *)info, info);
            }
        }
        f->del(f);
    }
    if (dname[0] && !fz_open(root(), dname, RW, 0, &d)) {
        uint64_t n = sizeof info;
        if (!d->getinfo(d, file_info_guid, &n, info)) {    // move a directory below itself
            char to[320]; snprintf(to, sizeof to, "\\%s\\inner", dname);
            uint16_t *nm = (uint16_t *)(info + 80); int i = 0;
            for (; to[i]; i++) nm[i] = (uint8_t)to[i];
            nm[i] = 0; *(uint64_t *)info = 80 + (i + 1) * 2;
            d->setinfo(d, file_info_guid, *(uint64_t *)info, info);
        }
        d->del(d);    // rmdir (refused when not empty)
    }
}
static int fuzz_main(const char *image, int ro) {
    int fd = open(image, O_RDONLY); struct stat st;
    if (fd < 0 || fstat(fd, &st)) { perror(image); return 2; }
    disk_bytes = st.st_size;
    disk = guarded(disk_bytes);
    if (!disk) { perror("mmap"); return 2; }
    for (uint64_t got = 0; got < disk_bytes;) {
        ssize_t r = read(fd, disk + got, disk_bytes - got);
        if (r <= 0) { perror("read"); return 2; }
        got += r;
    }
    close(fd);
    media.last = disk_bytes / media.block ? disk_bytes / media.block - 1 : 0;
    if (disk_bytes < media.block) disk_bytes = 0;    // nothing readable
    services[152 / 8] = (void *)handle_protocol;
    services[40 / 8] = (void *)allocate_pages;
    services[136 / 8] = (void *)reinstall;
    boot_services = services; image_handle = (void *)0x99;
    fuzz_mode = 1;
    status s = fat_mount();
    if (s) { printf("fuzz: mount refused %llx\n", (unsigned long long)s); return 0; }
    ro_armed = ro;
    fz_walk(root(), "", 0);
    uint64_t fsn = 200; root()->getinfo(root(), fs_info_guid, &fsn, info);
    file *f;
    if (!fz_open(root(), "\\NO\\SUCH\\PATH.TXT", RD, 0, &f)) fz_close(f);
    if (!fz_open(root(), "\\..\\..\\.\\", RD, 0, &f)) fz_close(f);
    if (!ro) fz_write_tests();
    root()->flush(root());
    ro_armed = 0;
    fat_unmount();
    printf("fuzz: ok (%d entries, %d dirs, %d files, %llu reads, %llu writes)\n", fz_entries, fz_dirs,
           fz_files, (unsigned long long)reads, (unsigned long long)writes);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 4 && (!strcmp(argv[3], "fuzz") || !strcmp(argv[3], "fuzzro"))) {
        media.block = atoi(argv[2]);
        if (!media.block) return 2;
        return fuzz_main(argv[1], !strcmp(argv[3], "fuzzro"));
    }
    if (argc != 4) { fprintf(stderr, "usage: fat_host IMAGE SECTOR phase1|phase2|shortfat|badcluster\n"); return 2; }
    int fd = open(argv[1], O_RDWR); struct stat st; fstat(fd, &st);
    disk_bytes = st.st_size;
    disk = mmap(NULL, disk_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    media.block = atoi(argv[2]); media.last = disk_bytes / media.block - 1;
    services[152 / 8] = (void *)handle_protocol;
    services[40 / 8] = (void *)allocate_pages;
    services[136 / 8] = (void *)reinstall;
    boot_services = services; image_handle = (void *)0x99;
    status s = fat_mount();
    if (s) { fprintf(stderr, "mount failed %llx\n", (unsigned long long)s); return 1; }

    static uint8_t big[300000], tmp[300000];
    char names[400][64];
    if (!strcmp(argv[3], "phase1")) {
        // Files the host created with mtools, including long names.
        expect_file("\\UPPER.TXT", "upper\r\n", 7);
        expect_file("\\Hello.txt", "hello\r\n", 7);
        expect_file("\\hello.TXT", "hello\r\n", 7);         // case-insensitive
        expect_file("\\A long file name.text", "long\r\n", 6);
        expect_file("\\Sub Dir\\.\\..\\Sub Dir\\inner.dat", NULL, 0) ;
        // Long name aliases are reachable by their short names too.
        file *f; CHECK(op("\\ALONGF~1.TEX", RD, 0, &f) == 0, "short alias lookup"); if (!failures) f->close(f);
        int n = list_dir("\\", names, 400);
        CHECK(in_list(names, n, "A long file name.text") && in_list(names, n, "Hello.txt"), "root listing");
        CHECK(op("\\MISSING.TXT", RD, 0, &f) == NOT_FOUND, "missing not found");
        CHECK(op("\\NOPE\\X.TXT", CR, 0, &f) == NOT_FOUND, "create below missing dir");

        // Large file in odd chunks, then overwrite in the middle and grow past EOF.
        for (uint64_t i = 0; i < sizeof big; i++) big[i] = pattern(1, i);
        write_all("\\BIG.BIN", big, 250000, 4093);
        CHECK(op("\\BIG.BIN", RW, 0, &f) == 0, "reopen big");
        f->setpos(f, 100000); uint64_t m = 5000;
        for (uint64_t i = 0; i < 5000; i++) big[100000 + i] = 0xa5;
        f->write(f, &m, big + 100000);
        f->setpos(f, 280000); m = 20000;
        memset(big + 250000, 0, 30000);
        f->write(f, &m, big + 280000);
        uint64_t pos; f->getpos(f, &pos); CHECK(pos == 300000, "position after write");
        f->setpos(f, ~0ull); f->getpos(f, &pos); CHECK(pos == 300000, "seek to end");
        f->close(f);
        expect_file("\\BIG.BIN", big, 300000);

        // SetInfo size: shrink, then grow (new bytes must read as zero).
        CHECK(op("\\BIG.BIN", RW, 0, &f) == 0, "reopen big 2");
        get_info(f); *(uint64_t *)(info + 8) = 70001;
        CHECK(f->setinfo(f, file_info_guid, *(uint64_t *)info, info) == 0, "shrink");
        get_info(f); *(uint64_t *)(info + 8) = 90000;
        CHECK(f->setinfo(f, file_info_guid, *(uint64_t *)info, info) == 0, "grow");
        f->close(f);
        memcpy(tmp, big, 70001); memset(tmp + 70001, 0, 90000 - 70001);
        expect_file("\\BIG.BIN", tmp, 90000);

        // Many long-named files force the directory across several clusters.
        CHECK(op("\\New Dir", CR, 0x10, &f) == 0, "mkdir"); if (f) f->close(f);
        char path[128], text[64];
        for (int i = 0; i < 150; i++) {
            snprintf(path, sizeof path, "\\New Dir\\file number %03d.txt", i);
            int len = snprintf(text, sizeof text, "content %d\r\n", i);
            write_all(path, text, len, 5);
        }
        n = list_dir("\\New Dir", names, 400);
        CHECK(n == 152, "listing count %d", n);
        CHECK(in_list(names, n, ".") && in_list(names, n, "..") && in_list(names, n, "file number 149.txt"),
              "new dir listing");
        expect_file("\\New Dir\\FILE NUMBER 077.TXT", "content 77\r\n", 12);

        // Exact 8.3 names: lower case kept through the NT flags, no long entry.
        write_all("\\lower.txt", "lc", 2, 2);
        write_all("\\MiXed.TXT", "mx", 2, 2);
        n = list_dir("\\", names, 400);
        CHECK(in_list(names, n, "lower.txt") && in_list(names, n, "MiXed.TXT"), "case preserved");

        // Renames: same directory, case only, across directories, directory move.
        CHECK(rename_to("\\New Dir\\file number 000.txt", "renamed zero.TXT") == 0, "rename");
        CHECK(rename_to("\\UPPER.TXT", "upper.txt") == 0, "case rename");
        CHECK(rename_to("\\New Dir\\file number 001.txt", "\\Sub Dir\\moved.txt") == 0, "move");
        CHECK(rename_to("\\New Dir\\file number 002.txt", "\\Hello.txt") == DENIED, "rename onto existing");
        CHECK(op("\\New Dir\\Child", CR, 0x10, &f) == 0, "mkdir child"); if (f) f->close(f);
        write_all("\\New Dir\\Child\\leaf.txt", "leaf", 4, 4);
        CHECK(rename_to("\\New Dir\\Child", "\\Child Moved") == 0, "move dir");
        CHECK(rename_to("\\Child Moved", "\\Child Moved\\inside") == DENIED, "dir into itself");
        expect_file("\\Child Moved\\..\\Child Moved\\leaf.txt", "leaf", 4);
        expect_file("\\New Dir\\renamed zero.TXT", "content 0\r\n", 11);
        expect_file("\\Sub Dir\\moved.txt", "content 1\r\n", 11);
        n = list_dir("\\", names, 400);
        CHECK(in_list(names, n, "upper.txt") && !in_list(names, n, "UPPER.TXT"), "case rename listing");

        // Deletes, and reuse of the freed slots.
        for (int i = 10; i < 60; i++) {
            snprintf(path, sizeof path, "\\New Dir\\file number %03d.txt", i);
            CHECK(op(path, RW, 0, &f) == 0 && f->del(f) == 0, "delete %d", i);
        }
        write_all("\\New Dir\\after delete with a long name.txt", "after", 5, 5);
        CHECK(op("\\New Dir", RW, 0, &f) == 0 && f->del(f) == 2, "non-empty rmdir refused");

        // Attributes: read-only blocks write opens.
        CHECK(op("\\lower.txt", RD, 0, &f) == 0, "open lower");
        get_info(f); *(uint64_t *)(info + 72) |= 1;
        CHECK(f->setinfo(f, file_info_guid, *(uint64_t *)info, info) == 0, "set ro"); f->close(f);
        CHECK(op("\\lower.txt", RW, 0, &f) == DENIED, "ro denied");
        CHECK(op("\\lower.txt", RD, 0, &f) == 0, "ro read ok");
        get_info(f); CHECK((info_attr() & 0x21) == 0x21, "attr bits %llx", (unsigned long long)info_attr());
        f->close(f);

        // Write to a read-only handle and to a directory fail.
        CHECK(op("\\MiXed.TXT", RD, 0, &f) == 0, "open mx"); { uint64_t k = 1; CHECK(f->write(f, &k, "x") == DENIED, "ro handle write"); } f->close(f);

        // Empty files have no cluster; truncating a file to zero frees all.
        write_all("\\EMPTY.TXT", "", 0, 1);
        expect_file("\\EMPTY.TXT", "", 0);
        CHECK(op("\\Sub Dir\\moved.txt", RW, 0, &f) == 0, "open moved");
        get_info(f); *(uint64_t *)(info + 8) = 0;
        CHECK(f->setinfo(f, file_info_guid, *(uint64_t *)info, info) == 0, "truncate to 0"); f->close(f);
        write_all("\\Sub Dir\\moved.txt", "content 1\r\n", 11, 3);

        // A second handle on a deleted file must not reach the file that
        // reuses its directory slot (and maybe its freed clusters).
        write_all("\\VICTIM.TXT", "victim", 6, 6);
        file *h1 = NULL, *h2 = NULL;
        CHECK(op("\\VICTIM.TXT", RW, 0, &h1) == 0 && op("\\VICTIM.TXT", RW, 0, &h2) == 0,
              "open victim twice");
        if (h1 && h2) {
            CHECK(h1->del(h1) == 0, "delete victim");
            write_all("\\NEWFILE.TXT", "newdata", 7, 7);
            uint64_t k = 5; CHECK(h2->write(h2, &k, "STALE") != 0, "stale handle write refused");
            k = 8; CHECK(h2->read(h2, &k, tmp) != 0, "stale handle read refused");
            CHECK(get_info(h2) != 0, "stale handle getinfo refused");
            h2->close(h2);
            expect_file("\\NEWFILE.TXT", "newdata", 7);
        }
        // A second handle on a renamed or moved file follows it.
        write_all("\\FOLLOW.TXT", "follow", 6, 6);
        CHECK(op("\\FOLLOW.TXT", RD, 0, &h1) == 0, "open follow");
        CHECK(rename_to("\\FOLLOW.TXT", "\\Sub Dir\\followed name.txt") == 0, "move follow");
        write_all("\\TAKESLOT.TXT", "other", 5, 5);
        if (h1) {
            uint64_t k = 6; memset(tmp, 0, 8);
            CHECK(h1->read(h1, &k, tmp) == 0 && k == 6 && !memcmp(tmp, "follow", 6),
                  "moved file read through old handle");
            char nm[64]; CHECK(get_info(h1) == 0, "moved getinfo"); info_name(nm);
            CHECK(!strcmp(nm, "followed name.txt"), "moved name %s", nm);
            h1->close(h1);
        }

        // A long name with characters outside ASCII is shown by its alias,
        // but deleting the file must still remove its long-name entries
        // (fsck.fat afterwards would report them as orphans).
        n = list_dir("\\", names, 400);
        int deleted = 0;
        for (int i = 0; i < n && i < 400; i++) {
            if (strncmp(names[i], "CAF", 3) || !strchr(names[i], '~')) continue;
            char alias[80]; snprintf(alias, sizeof alias, "\\%.70s", names[i]);
            CHECK(op(alias, RW, 0, &f) == 0 && f->del(f) == 0, "delete %s", alias);
            deleted++;
        }
        CHECK(deleted == 1, "non-ASCII long name alias listed %d times", deleted);

        // Volume information.
        uint64_t fsn = 200;
        CHECK(root()->getinfo(root(), fs_info_guid, &fsn, info) == 0, "fs info");
        CHECK(*(uint64_t *)(info + 16) > *(uint64_t *)(info + 24) && *(uint32_t *)(info + 32) >= 512,
              "fs sizes");
    } else if (!strcmp(argv[3], "shortfat")) {
        // The BPB claims more clusters than its FAT can describe:
        // allocation must stop at the FAT's end, not spill into the root.
        file *f; CHECK(op("\\FILL.BIN", CR, 0, &f) == 0, "create fill");
        status full = 0;
        for (int i = 0; f && i < 100 && !full; i++) {    // up to 30 MB: past the FAT's reach
            uint64_t k = sizeof big; full = f->write(f, &k, big);
        }
        CHECK(full == ERR(11), "short FAT fills up with VOLUME_FULL, got %llx",
              (unsigned long long)full);
        if (f) f->close(f);
        expect_file("\\KEEP.TXT", "keep\r\n", 6);
        int n = list_dir("\\", names, 400);
        CHECK(in_list(names, n, "KEEP.TXT"), "root listing after filling a short FAT");
    } else if (!strcmp(argv[3], "badcluster")) {
        // BAD.TXT's directory entry names a first cluster past the volume:
        // every operation must refuse it without writing anywhere.
        file *f; CHECK(op("\\BAD.TXT", RW, 0, &f) == 0, "open bad");
        if (f) {
            uint64_t k = 16; CHECK(f->read(f, &k, tmp) != 0, "read bad refused");
            get_info(f); *(uint64_t *)(info + 8) = 100;
            CHECK(f->setinfo(f, file_info_guid, *(uint64_t *)info, info) != 0, "truncate bad refused");
            f->setpos(f, 5000); k = 4;
            CHECK(f->write(f, &k, "evil") != 0, "write bad refused");
            f->close(f);
        }
        CHECK(op("\\BADDIR\\NEW.TXT", CR, 0, &f) != 0, "create in bad directory refused");
        expect_file("\\KEEP.TXT", "keep\r\n", 6);
    } else {
        // Second boot: everything persisted, and the image is still usable.
        expect_file("\\BIG.BIN", NULL, 0);
        for (uint64_t i = 0; i < 300000; i++) big[i] = pattern(1, i);
        for (uint64_t i = 0; i < 5000; i++) big[100000 + i] = 0xa5;
        memset(big + 70001, 0, 90000 - 70001);
        uint64_t got; uint8_t *b = read_all("\\BIG.BIN", &got);
        CHECK(b && got == 90000 && !memcmp(b, big, got), "BIG.BIN after remount");
        int n = list_dir("\\New Dir", names, 400);
        CHECK(n == 2 + 150 - 1 - 50 + 1, "remount listing %d", n);
        expect_file("\\Child Moved\\leaf.txt", "leaf", 4);
        file *f; CHECK(op("\\lower.txt", RW, 0, &f) == DENIED, "ro persisted");
    }
    fat_unmount();
    CHECK(reinstalled, "block io reinstalled on unmount");
    msync(disk, disk_bytes, MS_SYNC);
    printf("%s: %s (%llu reads, %llu writes)\n", argv[3], failures ? "FAILED" : "ok",
           (unsigned long long)reads, (unsigned long long)writes);
    return failures != 0;
}
