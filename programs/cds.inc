// SPDX-License-Identifier: MIT

// ARM DOS kernel access: this program reads or edits kernel tables (list of
// lists, drive table, block drivers), so it runs at EL1 (ABI.md).
.globl __armdos_kernel_access
.set __armdos_kernel_access, 1
// The kernel's drive table (current directory structure), as 52h publishes
// it at +128 (entries at +136). Used by SUBST, JOIN and ASSIGN, which edit
// it directly as their DOS counterparts edited the CDS. Layout: ABI.md.
.equ DRV_SIZE, 512
.equ DRV_FLAGS, 0
.equ DRV_ROOT, 8
.equ DRV_VOL, 16
.equ DRV_TARGET, 24
.equ DRV_ASSIGN, 32
.equ DRV_RW, 40
.equ DRV_PATH, 64
.equ DRV_CWD, 256
.equ DF_VALID, 1
.equ DF_SUBST, 2
.equ DF_JOINED, 4

// Loads cds_table, cds_count and cds_lastdrive.
cds_init:
    frame
    dos 0x52
    ldr x2, [x0, #128]
    address x9, cds_table
    str x2, [x9]
    ldr x2, [x0, #136]
    address x9, cds_count
    str x2, [x9]
    ldrb w2, [x0, #35]
    cmp x2, #5
    mov x3, #5
    csel x2, x3, x2, lo
    address x9, cds_lastdrive
    str x2, [x9]
    unframe

// x0 = drive (0-based). Returns x0 = its entry.
cds_entry:
    address x9, cds_table
    ldr x9, [x9]
    mov x10, #DRV_SIZE
    madd x0, x0, x10, x9
    ret

// x0 = text. Returns x0 = the drive (0-based) of a "d:" argument, or -1.
// Accepts "d" too when x1 = 1 (ASSIGN's form).
cds_parse_drive:
    ldrb w2, [x0]
    orr w2, w2, #0x20
    sub w2, w2, #'a'
    cmp w2, #26
    b.hs 8f
    ldrb w3, [x0, #1]
    cmp w3, #':'
    b.eq 1f
    cbz x1, 8f
    cbnz w3, 2f
    mov x0, x2
    ret
2:
    cmp w3, #'='
    b.ne 8f
    mov x0, x2
    ret
1:
    mov x0, x2
    ret
8:
    mov x0, #-1
    ret

.section .bss
.balign 8
cds_table: .skip 8
cds_count: .skip 8
cds_lastdrive: .skip 8
.section .text
