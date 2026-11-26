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
static status bio_read(struct blockio *b, uint32_t id, uint64_t lba, uint64_t n, void *buf) {
    (void)b;
    if (id != media.id || n % media.block || (lba * media.block + n) > disk_bytes) return ERR(2);
    memcpy(buf, disk + lba * media.block, n); reads++; return 0;
}
static status bio_write(struct blockio *b, uint32_t id, uint64_t lba, uint64_t n, const void *buf) {
    (void)b;
    if (id != media.id || n % media.block || (lba * media.block + n) > disk_bytes) return ERR(2);
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
static status allocate_pages(uint64_t type, uint64_t mem, uint64_t pages, uint64_t *addr) {
    (void)type; (void)mem;
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

int main(int argc, char **argv) {
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
