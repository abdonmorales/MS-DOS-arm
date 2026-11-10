/*
 * MS-DOS for AArch64 -- system call ABI shared by the kernel (arm64/dos),
 * the user library (arm64/lib) and every program.
 *
 * THIS FILE IS THE CONTRACT.  Kernel, library and programs are developed
 * against it independently; do not change it without updating all three.
 *
 * ---------------------------------------------------------------------
 * 1. Software interrupts
 * ---------------------------------------------------------------------
 * The 8086 "INT n" instruction becomes "svc #n" executed at EL0:
 *
 *      svc #0x12   memory size        -> x0 = conventional memory in KB
 *      svc #0x20   terminate program  (same as AH=00h)
 *      svc #0x21   DOS function call
 *      svc #0x25   absolute disk read   x0=drive(0=A) x1=buffer x2=count x3=first sector
 *      svc #0x26   absolute disk write  (same registers)
 *                  25h/26h: CF=1 and x0=error on failure (no flags left on stack).
 *
 * Register mapping (all registers are 64 bit, values zero extended):
 *
 *      AX -> x0   (AH = bits 15..8, AL = bits 7..0)
 *      BX -> x1   CX -> x2   DX -> x3   SI -> x4   DI -> x5
 *
 *   - 8-bit halves stay packed exactly as on the 8086 (DH = x3 bits 15..8...).
 *   - Every segment:offset pair collapses into ONE flat 64-bit pointer held
 *     in the register that carried the offset:  DS:DX -> x3, DS:SI -> x4,
 *     ES:DI -> x5, ES:BX / DS:BX -> x1.  There are no segments.
 *   - Carry flag  -> PSTATE.C on return (C set = error, x0 = DOS error code).
 *     Zero flag   -> PSTATE.Z on return (only meaningful for AH=06h input).
 *   - x6..x30 and sp are preserved by every call.  x0..x5 are preserved
 *     unless the function is documented to return something in them.
 *
 * Deviations from the 16-bit register interface (things that were 16-bit
 * limits or segment values):
 *
 *   3Fh/40h read/write   x2 = byte count (full 32 bit), x0 = bytes transferred
 *   42h lseek            x3 = signed 64-bit offset (x2 ignored), returns x0 = new position
 *   48h allocate         x1 = paragraphs (16 bytes each, full 64 bit)
 *                        -> x0 = address of block.  Error: x0=8, x1=largest free (paragraphs)
 *   49h free             x3 = address of block
 *   4Ah setblock         x3 = address of block, x1 = new size in paragraphs
 *                        error: x0=8, x1 = max paragraphs possible
 *   4Bh exec             x3 = ASCIZ path, x1 = struct dos_execblk *, AL=0 only
 *                        (AL=3 "load overlay": x1 = struct dos_ovlblk *)
 *   25h/35h vectors      AL = interrupt number, handler is a flat pointer in x3 (set) / x1 (get)
 *   1Ah/2Fh DTA          x3 (set) / x1 (get)
 *   1Bh/1Ch              AL=sectors/cluster, CX=bytes/sector, DX=clusters, x1 -> media ID byte
 *   31h keep process     AL = return code, x3 = paragraphs to keep (memory is simply not freed)
 *   38h country          x3 -> 32-byte buffer (DOS 2.x layout), x1 = country code returned
 *   47h get cwd          DL = drive (0 = default), x4 -> 64-byte buffer
 *   56h rename           x3 = old ASCIZ, x5 = new ASCIZ
 *
 * Everything else is exactly the DOS 2.x register interface as documented
 * in v2.0/source/SYSCALL.txt with the mapping above.
 *
 * ---------------------------------------------------------------------
 * 2. Ctrl-C (INT 23h) and critical errors (INT 24h)
 * ---------------------------------------------------------------------
 * Vectors 22h/23h/24h are per process; EXEC gives the child default (0)
 * vectors and the parent's are restored when the child exits.
 *
 * Ctrl-C: if the current process' vector 23h is 0 the process is
 * terminated (exit type 1, "^C" echoed).  Otherwise the interrupted DOS
 * call is abandoned and the process resumes at the handler address with
 * x0 = 0x23 and the stack pointer it had when it made the call.  The
 * handler never "returns"; it normally longjmp()s to a main loop.
 *
 * Critical errors are handled inside the kernel ("Abort, Retry, Ignore?").
 * Vector 24h is stored/returned but never called.
 *
 * ---------------------------------------------------------------------
 * 3. Executable format (.COM and .EXE are the same format)
 * ---------------------------------------------------------------------
 * A program is a flat, position independent AArch64 image.  The file is
 * loaded at an arbitrary 16-byte aligned address and entered at offset 0
 * in EL0 with:
 *
 *      x0 = address of the PSP (struct dos_psp, precedes the image)
 *      sp = top of the program's stack (16-byte aligned), inside its block
 *      x1..x30 = 0
 *
 * The image must start with struct dos_exehdr.  Offset 0 is a branch
 * instruction that jumps over the header.  The image is responsible for
 * applying its own R_AARCH64_RELATIVE relocations (crt0 does this).
 * The kernel zero-fills [file_size, mem_size) and reserves stack_size bytes
 * (0 = default 64 KB) above the image, all in one memory block owned by
 * the process:  [ PSP 256 bytes | image | bss | stack ].
 * A file without the magic is rejected with error 11 (bad format).
 */
#ifndef DOS_ABI_H
#define DOS_ABI_H

#include <stdint.h>

#define DOS_INT_MEMSIZE   0x12
#define DOS_INT_TERMINATE 0x20
#define DOS_INT_DOS       0x21
#define DOS_INT_ABSREAD   0x25
#define DOS_INT_ABSWRITE  0x26

#define DOS_VERSION_MAJOR 2
#define DOS_VERSION_MINOR 11

/* ---- executable header -------------------------------------------- */
#define DOS_EXE_MAGIC 0x34364144u       /* "DA64" little endian at offset 4 */

struct dos_exehdr {
    uint32_t branch;        /* 0x00  "b _start" */
    uint32_t magic;         /* 0x04  DOS_EXE_MAGIC */
    uint32_t file_size;     /* 0x08  bytes of image present in the file */
    uint32_t mem_size;      /* 0x0C  image + bss, >= file_size */
    uint32_t stack_size;    /* 0x10  0 = default (64 KB) */
    uint32_t flags;         /* 0x14  reserved, 0 */
    uint64_t reserved;      /* 0x18 */
};                          /* 32 bytes */

/* ---- Program Segment Prefix ---------------------------------------- */
#define DOS_PSP_SIZE  256
#define DOS_PSP_MAGIC 0x50535041u       /* "APSP" */
#define DOS_JFT_SIZE  20

struct dos_psp {
    uint32_t int20;             /* 0x00  "svc #0x20" instruction */
    uint32_t magic;             /* 0x04  DOS_PSP_MAGIC */
    uint64_t mem_top;           /* 0x08  first byte past the program's block */
    uint64_t parent_psp;        /* 0x10  0 for the first process */
    uint64_t env;               /* 0x18  environment: ASCIZ strings, empty string ends */
    uint64_t vec22;             /* 0x20  saved terminate address */
    uint64_t vec23;             /* 0x28  saved Ctrl-C handler */
    uint64_t vec24;             /* 0x30  saved critical error handler */
    uint8_t  jft[DOS_JFT_SIZE]; /* 0x38  job file table, 0xFF = closed */
    uint8_t  pad0[0x5C - 0x4C];
    uint8_t  fcb1[16];          /* 0x5C  unopened FCB from 1st argument */
    uint8_t  fcb2[16];          /* 0x6C  unopened FCB from 2nd argument */
    uint8_t  pad1[4];
    uint8_t  cmdlen;            /* 0x80  length of command tail (excl. CR) */
    char     cmdtail[127];      /* 0x81  command tail, CR terminated */
};
_Static_assert(sizeof(struct dos_psp) == DOS_PSP_SIZE, "PSP size");

/* ---- EXEC parameter blocks (AH=4Bh) -------------------------------- */
struct dos_execblk {            /* AL = 0 */
    uint64_t env;               /* environment to copy, 0 = inherit parent's */
    uint64_t cmdtail;           /* -> [len][text...][CR] exactly as stored at PSP:80h */
    uint64_t fcb1;              /* -> 16-byte FCB or 0 */
    uint64_t fcb2;              /* -> 16-byte FCB or 0 */
};
struct dos_ovlblk {             /* AL = 3 */
    uint64_t load_addr;         /* raw file is read here, nothing else is done */
    uint64_t max_size;
};

/* ---- find first / find next DTA (AH=4Eh/4Fh) ------------------------ */
struct dos_dta {
    uint8_t  reserved[21];      /* kernel search state */
    uint8_t  attr;              /* 0x15 */
    uint16_t time;              /* 0x16 */
    uint16_t date;              /* 0x18 */
    uint32_t size;              /* 0x1A */
    char     name[13];          /* 0x1E  "NAME.EXT\0" */
} __attribute__((packed));
_Static_assert(sizeof(struct dos_dta) == 43, "DTA size");

/* ---- FCB (AH=0Fh..17h, 21h..24h, 27h..29h) -- on-disk layout, packed - */
struct dos_fcb {
    uint8_t  drive;             /* 0 = default, 1 = A: */
    char     name[8];
    char     ext[3];
    uint16_t cur_block;
    uint16_t rec_size;
    uint32_t file_size;
    uint16_t date;
    uint16_t time;
    uint8_t  reserved[8];
    uint8_t  cur_rec;
    uint32_t rand_rec;
} __attribute__((packed));
_Static_assert(sizeof(struct dos_fcb) == 37, "FCB size");

/* ---- file attributes ------------------------------------------------ */
#define DOS_ATTR_RDONLY 0x01
#define DOS_ATTR_HIDDEN 0x02
#define DOS_ATTR_SYSTEM 0x04
#define DOS_ATTR_VOLUME 0x08
#define DOS_ATTR_DIR    0x10
#define DOS_ATTR_ARCH   0x20

/* ---- standard handles ----------------------------------------------- */
#define DOS_STDIN  0
#define DOS_STDOUT 1
#define DOS_STDERR 2
#define DOS_STDAUX 3
#define DOS_STDPRN 4

/* ---- IOCTL (AH=44h AL=0) device info bits ---------------------------- */
#define DOS_DEV_ISDEV  0x80
#define DOS_DEV_EOF    0x40     /* files: bit6 = not written; devices: 0 = EOF on input */
#define DOS_DEV_RAW    0x20
#define DOS_DEV_CLOCK  0x08
#define DOS_DEV_NUL    0x04
#define DOS_DEV_STDOUT 0x02
#define DOS_DEV_STDIN  0x01

/* ---- error codes ----------------------------------------------------- */
#define DOS_ERR_BADFUNC     1
#define DOS_ERR_NOFILE      2
#define DOS_ERR_NOPATH      3
#define DOS_ERR_TOOMANY     4
#define DOS_ERR_ACCESS      5
#define DOS_ERR_BADHANDLE   6
#define DOS_ERR_ARENA       7
#define DOS_ERR_NOMEM       8
#define DOS_ERR_BADBLOCK    9
#define DOS_ERR_BADENV      10
#define DOS_ERR_BADFORMAT   11
#define DOS_ERR_BADACCESS   12
#define DOS_ERR_BADDATA     13
#define DOS_ERR_BADDRIVE    15
#define DOS_ERR_CURDIR      16
#define DOS_ERR_NOTSAME     17
#define DOS_ERR_NOMORE      18

/* exit types returned in AH by AH=4Dh */
#define DOS_EXIT_NORMAL 0
#define DOS_EXIT_CTRLC  1
#define DOS_EXIT_CRIT   2
#define DOS_EXIT_TSR    3

/* flag bits as reported to C callers by the library */
#define DOS_CF 0x01
#define DOS_ZF 0x40

#endif /* DOS_ABI_H */
