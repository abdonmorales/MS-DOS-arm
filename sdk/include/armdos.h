/* SPDX-License-Identifier: MIT */
/*
 * armdos.h - the ARM DOS native program ABI (ABI.md) as C.
 *
 * Every DOS service is one indirect call: w8 = function number, arguments in
 * x0..x5, results in x0/x2/x3/x4/x5, and x1 = 0 for success or x1 = 1 for an
 * error with the DOS error code in x0. The kernel may clobber x0-x18, the
 * flags and the AAPCS64 caller-saved vector registers, so armdos_call() names
 * all of them as clobbers and the compiler keeps live values in x19-x28.
 *
 * The typed wrappers below return a non-negative result on success and the
 * negated DOS error code on failure (for example -2 = file not found), unless
 * their comment says otherwise. The C library maps those codes to errno.
 */
#ifndef ARMDOS_H
#define ARMDOS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Program entry descriptor (x0 at the entry point) ------------------ */

#define ARMDOS_SIGNATURE   "ARMDOS64"
#define ARMDOS_SIGNATURE_U64 0x3436534f444d5241ull   /* "ARMDOS64", LE */
#define ARMDOS_ABI_VERSION 1                         /* descriptor +8 */

typedef struct armdos_descriptor {
    char     signature[8];      /*  0: "ARMDOS64" */
    uint64_t version;           /*  8: 1 */
    uint64_t size;              /* 16: 64 */
    void    *service;           /* 24: AAPCS64 DOS service entry */
    const char *command_tail;   /* 32: NUL-terminated command tail */
    const char *environment;    /* 40: NAME=value\0 ... \0\0 */
    const char *current_dir;    /* 48: the runtime's current directory */
    uint64_t process_id;        /* 56: image load address (owner id) */
} armdos_descriptor;

_Static_assert(sizeof(armdos_descriptor) == 64, "descriptor is 64 bytes");

/* Saved by crt0 from the descriptor before main() runs. */
extern void *__armdos_service;
extern const armdos_descriptor *__armdos_descriptor;

/* ---- The single service-call primitive -------------------------------- */

typedef struct armdos_regs {
    uint64_t x0, x1, x2, x3, x4, x5;
} armdos_regs;

/* Vector registers v0-v7 and v16-v31 are caller-saved in AAPCS64 and the
 * ABI allows the kernel to clobber them. With -mgeneral-regs-only the
 * compiler holds nothing there (and refuses to name them), so they are only
 * listed when floating point is enabled. */
#ifdef __ARM_FP
#define ARMDOS_VCLOBBERS , "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", \
    "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23", \
    "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31"
#else
#define ARMDOS_VCLOBBERS
#endif

/* Calls DOS function fn with r->x0..x5 as arguments; on return r holds
 * x0..x5 as the kernel left them. */
static inline __attribute__((always_inline))
void armdos_call(unsigned fn, armdos_regs *r)
{
    register uint64_t x0 __asm__("x0") = r->x0;
    register uint64_t x1 __asm__("x1") = r->x1;
    register uint64_t x2 __asm__("x2") = r->x2;
    register uint64_t x3 __asm__("x3") = r->x3;
    register uint64_t x4 __asm__("x4") = r->x4;
    register uint64_t x5 __asm__("x5") = r->x5;
    register uint64_t x8 __asm__("x8") = fn;
    void *service = __armdos_service;
    __asm__ volatile("blr %[svc]"
        : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3), "+r"(x4), "+r"(x5), "+r"(x8)
        : [svc] "r"(service)
        : "x6", "x7", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
          "x16", "x17", "x18", "x30", "cc", "memory" ARMDOS_VCLOBBERS);
    r->x0 = x0; r->x1 = x1; r->x2 = x2; r->x3 = x3; r->x4 = x4; r->x5 = x5;
}

/* Convenience: up to four arguments, returns the full register set. */
static inline __attribute__((always_inline))
armdos_regs armdos_call4(unsigned fn, uint64_t a0, uint64_t a1, uint64_t a2,
                         uint64_t a3)
{
    armdos_regs r = { a0, a1, a2, a3, 0, 0 };
    armdos_call(fn, &r);
    return r;
}

/* x1 == 1 means failure with the DOS error code in x0. */
#define ARMDOS_FAILED(r) ((r).x1 == 1)
/* The usual "value or -error" result (a function, so a call passed as its
 * argument runs once). */
static inline long ARMDOS_RESULT(armdos_regs r)
{ return r.x1 == 1 ? -(long)r.x0 : (long)r.x0; }

/* ---- DOS error codes (subset) ----------------------------------------- */
enum {
    DOSERR_INVALID_FUNCTION = 1,  DOSERR_FILE_NOT_FOUND = 2,
    DOSERR_PATH_NOT_FOUND = 3,    DOSERR_TOO_MANY_OPEN = 4,
    DOSERR_ACCESS_DENIED = 5,     DOSERR_INVALID_HANDLE = 6,
    DOSERR_NO_MEMORY = 8,         DOSERR_INVALID_BLOCK = 9,
    DOSERR_BAD_ENVIRONMENT = 10,  DOSERR_BAD_FORMAT = 11,
    DOSERR_INVALID_ACCESS = 12,   DOSERR_INVALID_DATA = 13,
    DOSERR_INVALID_DRIVE = 15,    DOSERR_CURRENT_DIRECTORY = 16,
    DOSERR_NOT_SAME_DEVICE = 17,  DOSERR_NO_MORE_FILES = 18,
    DOSERR_WRITE_PROTECT = 19,    DOSERR_NOT_READY = 21,
    DOSERR_SHARING = 32,          DOSERR_LOCK = 33,
    DOSERR_DISK_CHANGE = 34,      DOSERR_FILE_EXISTS = 80,
    DOSERR_CANNOT_MAKE = 82,      DOSERR_INVALID_PARAMETER = 87,
};

/* ---- Console (01h 02h 06h 07h 08h 09h 0Ah 0Bh) ------------------------ */

/* 01h: read a key with echo. */
static inline int dos_getche(void)
{ return (int)(armdos_call4(0x01, 0, 0, 0, 0).x0 & 0xff); }

/* 07h: read a key without echo (08h behaves the same here). */
static inline int dos_getch(void)
{ return (int)(armdos_call4(0x07, 0, 0, 0, 0).x0 & 0xff); }

/* 02h: write one character to standard output (no CR/LF translation). */
static inline void dos_putch(int c)
{ armdos_call4(0x02, (uint8_t)c, 0, 0, 0); }

/* 06h with a character: direct output (255 cannot be written this way). */
static inline void dos_direct_out(int c)
{ armdos_call4(0x06, (uint8_t)c, 0, 0, 0); }

/* 06h with 255: poll input. Returns the key, or -1 if none (x2 = 1). */
static inline int dos_direct_in(void)
{
    armdos_regs r = armdos_call4(0x06, 255, 0, 0, 0);
    return r.x2 ? -1 : (int)(r.x0 & 0xff);
}

/* 09h: print until '$' or NUL. */
static inline void dos_print(const char *s)
{ armdos_call4(0x09, (uintptr_t)s, 0, 0, 0); }

/* 0Ah: buffered line input. Set capacity (including the CR) first. */
typedef struct dos_linebuf {
    uint8_t capacity;
    uint8_t count;              /* filled in: characters before the CR */
    char    text[255];
} dos_linebuf;

static inline long dos_read_line(dos_linebuf *buf)
{
    armdos_regs r = armdos_call4(0x0a, (uintptr_t)buf, 0, 0, 0);
    return ARMDOS_FAILED(r) ? -(long)r.x0 : buf->count;
}

/* 0Bh: 1 if a key is waiting, otherwise 0. */
static inline int dos_kbhit(void)
{ return armdos_call4(0x0b, 0, 0, 0, 0).x0 ? 1 : 0; }

/* ---- Drives (0Eh 19h 36h) ---------------------------------------------- */

/* 0Eh: select drive (0 = A:); returns the number of drive letters. */
static inline int dos_set_drive(int drive)
{ return (int)armdos_call4(0x0e, (uint64_t)drive, 0, 0, 0).x0; }

/* 19h: current drive, 0 = A:. */
static inline int dos_get_drive(void)
{ return (int)armdos_call4(0x19, 0, 0, 0, 0).x0; }

typedef struct dos_diskfree {
    uint64_t unit_bytes;        /* bytes per allocation unit */
    uint64_t free_units;
    uint64_t total_units;
} dos_diskfree;

/* 36h: drive 0 = default, 1 = A:. */
static inline long dos_disk_free(int drive, dos_diskfree *out)
{
    armdos_regs r = armdos_call4(0x36, (uint64_t)drive, 0, 0, 0);
    if (ARMDOS_FAILED(r))
        return -(long)r.x0;
    out->unit_bytes = r.x0; out->free_units = r.x2; out->total_units = r.x3;
    return 0;
}

/* ---- Date and time (2Ah-2Dh) ------------------------------------------- */

typedef struct dos_date {
    int year, month, day;
    int weekday;                /* Sunday = 0 */
} dos_date;

typedef struct dos_time {
    int hour, minute, second, hundredths;
} dos_time;

static inline void dos_get_date(dos_date *d)
{
    armdos_regs r = armdos_call4(0x2a, 0, 0, 0, 0);
    d->year = (int)r.x0; d->month = (int)r.x2; d->day = (int)r.x3;
    d->weekday = (int)r.x4;
}

static inline long dos_set_date(int year, int month, int day)
{ return ARMDOS_RESULT(armdos_call4(0x2b, (uint64_t)year, (uint64_t)month, (uint64_t)day, 0)); }

static inline void dos_get_time(dos_time *t)
{
    armdos_regs r = armdos_call4(0x2c, 0, 0, 0, 0);
    t->hour = (int)r.x0; t->minute = (int)r.x2; t->second = (int)r.x3;
    t->hundredths = (int)r.x4;
}

static inline long dos_set_time(int hour, int minute, int second, int hundredths)
{
    return ARMDOS_RESULT(armdos_call4(0x2d, (uint64_t)hour, (uint64_t)minute,
                                      (uint64_t)second, (uint64_t)hundredths));
}

/* ---- Version (30h) ---------------------------------------------------- */

/* Returns major | minor << 8 (4.00 -> 0x0004). The minor version comes
 * back in x1, which is why it is always 0 here: x1 is also the flag. */
static inline int dos_version(void)
{
    armdos_regs r = armdos_call4(0x30, 0, 0, 0, 0);
    return (int)((r.x0 & 0xff) | ((r.x1 & 0xff) << 8));
}

/* ---- Directories (39h 3Ah 3Bh 47h) ------------------------------------ */

static inline long dos_mkdir(const char *path)
{
    armdos_regs r = armdos_call4(0x39, (uintptr_t)path, 0, 0, 0);
    return ARMDOS_FAILED(r) ? -(long)r.x0 : 0;
}

static inline long dos_rmdir(const char *path)
{
    armdos_regs r = armdos_call4(0x3a, (uintptr_t)path, 0, 0, 0);
    return ARMDOS_FAILED(r) ? -(long)r.x0 : 0;
}

static inline long dos_chdir(const char *path)
{
    armdos_regs r = armdos_call4(0x3b, (uintptr_t)path, 0, 0, 0);
    return ARMDOS_FAILED(r) ? -(long)r.x0 : 0;
}

/* 47h: drive 0 = default, 1 = A:. Writes the path without the drive or the
 * leading backslash ("" at the root). */
static inline long dos_getcwd(int drive, char *buf, size_t capacity)
{
    armdos_regs r = armdos_call4(0x47, (uintptr_t)buf, capacity, (uint64_t)drive, 0);
    return ARMDOS_FAILED(r) ? -(long)r.x0 : 0;
}

/* ---- File handles (3Ch-43h, 56h, 57h) --------------------------------- */

#define DOS_STDIN  0
#define DOS_STDOUT 1
#define DOS_STDERR 2
#define DOS_STDAUX 3
#define DOS_STDPRN 4

/* Open modes: access in bits 0-2, sharing in bits 4-6, 0x80 not inherited. */
#define DOS_O_RDONLY     0x00
#define DOS_O_WRONLY     0x01
#define DOS_O_RDWR       0x02
#define DOS_SHARE_COMPAT 0x00
#define DOS_DENY_ALL     0x10
#define DOS_DENY_WRITE   0x20
#define DOS_DENY_READ    0x30
#define DOS_DENY_NONE    0x40
#define DOS_NOINHERIT    0x80

/* Attributes. */
#define DOS_A_RDONLY 0x01
#define DOS_A_HIDDEN 0x02
#define DOS_A_SYSTEM 0x04
#define DOS_A_LABEL  0x08
#define DOS_A_DIR    0x10
#define DOS_A_ARCH   0x20

#define DOS_SEEK_SET 0
#define DOS_SEEK_CUR 1
#define DOS_SEEK_END 2

/* 3Ch: create or truncate; returns the handle. */
static inline long dos_create(const char *path, unsigned attributes)
{ return ARMDOS_RESULT(armdos_call4(0x3c, (uintptr_t)path, attributes, 0, 0)); }

/* 3Dh: open an existing file or device; returns the handle. */
static inline long dos_open(const char *path, unsigned mode)
{ return ARMDOS_RESULT(armdos_call4(0x3d, (uintptr_t)path, mode, 0, 0)); }

/* 3Eh */
static inline long dos_close(int handle)
{
    armdos_regs r = armdos_call4(0x3e, (uint64_t)handle, 0, 0, 0);
    return ARMDOS_FAILED(r) ? -(long)r.x0 : 0;
}

/* 3Fh: returns bytes read, 0 at end of file. */
static inline long dos_read(int handle, void *buf, size_t count)
{ return ARMDOS_RESULT(armdos_call4(0x3f, (uint64_t)handle, (uintptr_t)buf, count, 0)); }

/* 40h: returns bytes written. count 0 truncates/extends at the position. */
static inline long dos_write(int handle, const void *buf, size_t count)
{ return ARMDOS_RESULT(armdos_call4(0x40, (uint64_t)handle, (uintptr_t)buf, count, 0)); }

/* 41h */
static inline long dos_delete(const char *path)
{
    armdos_regs r = armdos_call4(0x41, (uintptr_t)path, 0, 0, 0);
    return ARMDOS_FAILED(r) ? -(long)r.x0 : 0;
}

/* 42h: returns the new position. */
static inline long dos_seek(int handle, long offset, int origin)
{ return ARMDOS_RESULT(armdos_call4(0x42, (uint64_t)handle, (uint64_t)offset, (uint64_t)origin, 0)); }

/* 43h: get returns the attributes. */
static inline long dos_get_attributes(const char *path)
{ return ARMDOS_RESULT(armdos_call4(0x43, (uintptr_t)path, 0, 0, 0)); }

static inline long dos_set_attributes(const char *path, unsigned attributes)
{
    armdos_regs r = armdos_call4(0x43, (uintptr_t)path, 1, attributes, 0);
    return ARMDOS_FAILED(r) ? -(long)r.x0 : 0;
}

/* 56h: rename or move within a drive. */
static inline long dos_rename(const char *from, const char *to)
{
    armdos_regs r = armdos_call4(0x56, (uintptr_t)from, (uintptr_t)to, 0, 0);
    return ARMDOS_FAILED(r) ? -(long)r.x0 : 0;
}

/* 57h: packed DOS date/time of an open file. */
static inline long dos_get_file_time(int handle, uint16_t *date, uint16_t *time)
{
    armdos_regs r = armdos_call4(0x57, (uint64_t)handle, 0, 0, 0);
    if (ARMDOS_FAILED(r))
        return -(long)r.x0;
    *date = (uint16_t)r.x2; *time = (uint16_t)r.x3;
    return 0;
}

/* ---- IOCTL (44h) basics ----------------------------------------------- */

#define DOS_DEV_ISDEV   0x80    /* handle is a device */
#define DOS_DEV_RAW     0x20
#define DOS_DEV_CLOCK   0x08
#define DOS_DEV_NUL     0x04
#define DOS_DEV_STDOUT  0x02
#define DOS_DEV_STDIN   0x01

/* 44h/00h: device information word (0 for a disk file). */
static inline long dos_ioctl_get_info(int handle)
{ return ARMDOS_RESULT(armdos_call4(0x44, (uint64_t)handle, 0, 0, 0)); }

/* 44h/01h: set device information (only the raw bit 20h changes). */
static inline long dos_ioctl_set_info(int handle, unsigned info)
{
    armdos_regs r = armdos_call4(0x44, (uint64_t)handle, 1, info & 0xff, 0);
    return ARMDOS_FAILED(r) ? -(long)r.x0 : 0;
}

/* 44h/06h, 07h: 1 if ready for input / output. */
static inline long dos_ioctl_ready(int handle, int output)
{
    armdos_regs r = armdos_call4(0x44, (uint64_t)handle, output ? 7 : 6, 0, 0);
    return ARMDOS_FAILED(r) ? -(long)r.x0 : (r.x0 & 0xff) == 0xff;
}

/* 44h, any subfunction: the full register set. */
static inline armdos_regs dos_ioctl(uint64_t handle_or_drive, unsigned sub,
                                    uint64_t x2, uint64_t x3)
{ return armdos_call4(0x44, handle_or_drive, sub, x2, x3); }

/* ---- Find first / next (1Ah 4Eh 4Fh) ---------------------------------- */

/* The flat DTA a search fills (ABI.md, 280 bytes). The kernel tracks each
 * search by the DTA's address, so keep one dos_dta per open search. */
typedef struct dos_dta {
    uint64_t attributes;
    uint64_t size;
    uint16_t time;              /* packed DOS time: h<<11 | m<<5 | s/2 */
    uint16_t date;              /* packed DOS date: (y-1980)<<9 | m<<5 | d */
    uint8_t  reserved[4];
    char     name[256];
} dos_dta;

_Static_assert(sizeof(dos_dta) == 280, "search DTA is 280 bytes");

/* 1Ah */
static inline void dos_set_dta(void *dta, size_t capacity)
{ armdos_call4(0x1a, (uintptr_t)dta, capacity, 0, 0); }

/* 4Eh: selects dta as the DTA, then searches. attributes selects hidden (2),
 * system (4) and directory (16) entries. Returns 0 or -18 at the end. */
static inline long dos_find_first(const char *pattern, unsigned attributes,
                                  dos_dta *dta)
{
    dos_set_dta(dta, sizeof *dta);
    armdos_regs r = armdos_call4(0x4e, (uintptr_t)pattern, attributes, 0, 0);
    return ARMDOS_FAILED(r) ? -(long)r.x0 : 0;
}

/* 4Fh: continues the search that dta belongs to. */
static inline long dos_find_next(dos_dta *dta)
{
    dos_set_dta(dta, sizeof *dta);
    armdos_regs r = armdos_call4(0x4f, 0, 0, 0, 0);
    return ARMDOS_FAILED(r) ? -(long)r.x0 : 0;
}

/* ---- Memory (48h 49h 4Ah) --------------------------------------------- */

/* 48h: owned block of at least size bytes (64 KiB granules, 16 MiB at most,
 * 64 blocks system wide). NULL on failure. Freed at process exit. */
static inline void *dos_alloc(size_t size)
{
    armdos_regs r = armdos_call4(0x48, size, 0, 0, 0);
    return ARMDOS_FAILED(r) ? (void *)0 : (void *)(uintptr_t)r.x0;
}

static inline long dos_free(void *block)
{
    armdos_regs r = armdos_call4(0x49, (uintptr_t)block, 0, 0, 0);
    return ARMDOS_FAILED(r) ? -(long)r.x0 : 0;
}

/* 4Ah: resize in place within the reserved capacity. On error 8 the
 * capacity is stored in *max (if not NULL). */
static inline long dos_resize(void *block, size_t size, size_t *max)
{
    armdos_regs r = armdos_call4(0x4a, (uintptr_t)block, size, 0, 0);
    if (ARMDOS_FAILED(r)) {
        if (r.x0 == DOSERR_NO_MEMORY && max)
            *max = r.x2;
        return -(long)r.x0;
    }
    return 0;
}

/* ---- Processes (4Bh 4Ch 4Dh) ------------------------------------------ */

/* 4Bh mode 0: load and run path with the given command tail (no leading
 * blank needed). Returns 0 once the child has ended; see dos_child_status. */
static inline long dos_exec(const char *path, const char *tail)
{
    armdos_regs r = armdos_call4(0x4b, (uintptr_t)path, (uintptr_t)(tail ? tail : ""), 0, 0);
    return ARMDOS_FAILED(r) ? -(long)r.x0 : 0;
}

/* 4Ch: terminate with an exit code. */
static inline __attribute__((noreturn)) void dos_exit(int code)
{
    armdos_call4(0x4c, (uint8_t)code, 0, 0, 0);
    __builtin_unreachable();
}

/* 4Dh: exit code in the low byte, termination type in the high byte
 * (0 normal, 1 Ctrl-C, 2 CPU exception, 3 resident). Cleared by reading. */
static inline int dos_child_status(void)
{ return (int)(armdos_call4(0x4d, 0, 0, 0, 0).x0 & 0xffff); }

/* ---- Errors and names (59h 60h) --------------------------------------- */

typedef struct dos_ext_error {
    int code, error_class, action, locus;
} dos_ext_error;

/* 59h: details of the last failing call. Returns the code. */
static inline int dos_get_ext_error(dos_ext_error *e)
{
    armdos_regs r = armdos_call4(0x59, 0, 0, 0, 0);
    if (e) {
        e->code = (int)r.x0; e->error_class = (int)r.x2;
        e->action = (int)r.x3; e->locus = (int)r.x4;
    }
    return (int)r.x0;
}

/* 60h: canonical upper-case name ("A:\DIR\FILE"); buf holds 128 bytes. */
static inline long dos_truename(const char *path, char buf[128])
{
    armdos_regs r = armdos_call4(0x60, (uintptr_t)path, (uintptr_t)buf, 0, 0);
    return ARMDOS_FAILED(r) ? -(long)r.x0 : 0;
}

#ifdef __cplusplus
}
#endif
#endif /* ARMDOS_H */
