/*
 * MS-DOS for AArch64 -- interface between the machine layer (arm64/bios,
 * the IO.SYS / IBMBIO equivalent) and the DOS kernel (arm64/dos, the
 * MSDOS.SYS equivalent).  THIS FILE IS A CONTRACT between the two.
 *
 * Execution model
 *   - The kernel runs at EL1 with the MMU off (flat physical addressing),
 *     on a single kernel stack, never preempted.  Programs run at EL0.
 *   - No FP/SIMD anywhere (everything is built -mgeneral-regs-only).
 *   - On "svc #n" from EL0 the bios saves the complete user context in a
 *     struct trapframe on the kernel stack and calls dos_int().  When
 *     dos_int() returns, the (possibly modified, possibly wholly replaced)
 *     trapframe is restored and execution continues at EL0.  Process
 *     switching (EXEC / EXIT) is done by the kernel simply overwriting *tf.
 */
#ifndef BIOS_H
#define BIOS_H

#include <stdint.h>
#include <stddef.h>

struct trapframe {
    uint64_t x[31];     /* x0..x30 */
    uint64_t sp;        /* SP_EL0 */
    uint64_t pc;        /* ELR_EL1 */
    uint64_t pstate;    /* SPSR_EL1 (bit 29 = C, bit 30 = Z); 0 = EL0t, ints enabled */
};
#define PSTATE_C (1ull << 29)
#define PSTATE_Z (1ull << 30)

/* ================= provided by arm64/dos, called by arm64/bios ======= */

/* Called once after all drivers are initialised.  Must set up DOS, load
 * the shell (A:\COMMAND.COM) and fill *tf with the first EL0 context.
 * On return the bios enters EL0 from *tf. */
void dos_init(struct trapframe *tf);

/* "svc #intno" executed at EL0. */
void dos_int(struct trapframe *tf, unsigned intno);

/* Any other synchronous exception from EL0 (data/instruction abort,
 * undefined instruction, alignment...).  esr/far are the raw registers.
 * The kernel should print a message and terminate the current process. */
void dos_fault(struct trapframe *tf, uint64_t esr, uint64_t far);

/* ================= provided by arm64/bios, called by arm64/dos ======= */

/* --- console (CON): PL011 UART.  Raw bytes, no translation, no echo. -- */
void bios_con_putc(int c);
int  bios_con_getc(void);       /* blocks, returns 0..255 */
int  bios_con_peek(void);       /* next byte without consuming it, -1 if none */

/* --- AUX and PRN: second serial port / printer if the machine has one - */
int  bios_aux_getc(void);       /* blocks; returns 0x1A (EOF) if no device */
void bios_aux_putc(int c);      /* discarded if no device */
void bios_prn_putc(int c);      /* discarded if no device */

/* --- block devices.  Sector size is always 512. ----------------------- */
struct bios_disk {
    uint32_t sectors;           /* total 512-byte sectors */
    uint8_t  removable;
    uint8_t  readonly;
};
int bios_disk_count(void);                      /* units 0..n-1; unit 0 is the boot disk (A:) */
int bios_disk_info(int unit, struct bios_disk *info);   /* 0 = ok */
/* return 0 on success, otherwise a DOS critical error code:
 * 0 write protect, 1 unknown unit, 2 not ready, 4 CRC, 8 sector not found, 12 general failure */
int bios_disk_read (int unit, uint32_t lba, uint32_t count, void *buf);
int bios_disk_write(int unit, uint32_t lba, uint32_t count, const void *buf);

/* --- clock ------------------------------------------------------------- */
struct bios_time {
    uint16_t year;              /* e.g. 2026 */
    uint8_t  month, day;        /* 1..12, 1..31 */
    uint8_t  hour, min, sec, hsec;
};
void     bios_clock_get(struct bios_time *t);
void     bios_clock_set(const struct bios_time *t);   /* kept as an offset if RTC is read only */
uint64_t bios_ticks_ms(void);                         /* monotonic milliseconds since boot */

/* --- memory ------------------------------------------------------------ */
/* RAM available for the DOS arena: [*base, *end), 16-byte aligned, not
 * overlapping the kernel image, its stack, the DTB or a RAM disk. */
void bios_mem_region(uintptr_t *base, uintptr_t *end);
/* Must be called after writing code into memory and before running it. */
void bios_flush_icache(void *start, size_t len);

/* --- misc -------------------------------------------------------------- */
void bios_puts(const char *s);                  /* raw debug output, '\n' -> CRLF */
void bios_halt(void) __attribute__((noreturn)); /* "System halted" */
void bios_reboot(void) __attribute__((noreturn));
void bios_poweroff(void) __attribute__((noreturn)); /* PSCI SYSTEM_OFF (ends QEMU) */

#endif /* BIOS_H */
