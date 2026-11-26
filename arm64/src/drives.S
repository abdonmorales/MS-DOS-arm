// SPDX-License-Identifier: MIT
// Drive letters: the current directory structure (CDS) of v4.0/src/DOS.
// Each letter has flags, its root object and FAT volume, its own current
// directory, and the SUBST / JOIN / ASSIGN mappings. canonicalize_path
// resolves a DOS path to (canonical_drive, "\PATH") on a physical drive:
//   ASSIGN  d: -> e:            the letter is redirected first;
//   SUBST   e: -> f:\DIR        the logical path is prefixed on drive f:;
//   JOIN    j: -> f:\DIR        f:\DIR\... continues on drive j: (and j:
//                               itself can no longer be named).
.equ DRIVES, 26
.equ DRV_SIZE, 512
.equ DRV_FLAGS, 0
.equ DRV_ROOT, 8                // root object (0: not formatted / no media)
.equ DRV_VOL, 16                // FAT volume slot
.equ DRV_TARGET, 24             // SUBST and JOIN: the physical drive
.equ DRV_ASSIGN, 32             // ASSIGN: target drive + 1 (0: none)
.equ DRV_RW, 40                 // block driver entry (0: the boot disk)
.equ DRV_PATH, 64               // SUBST target path / JOIN host path
.equ DRV_CWD, 256               // logical current directory, "\..."
.equ DF_VALID, 1                // a physical drive
.equ DF_SUBST, 2
.equ DF_JOINED, 4               // joined into another drive's tree
.section .text

// After filesystem_init: A: is the boot volume.
drives_init:
    address x9, drive_table
    mov w2, #DF_VALID
    str x2, [x9, #DRV_FLAGS]
    address x2, root_directory
    ldr x2, [x2]
    str x2, [x9, #DRV_ROOT]
    str xzr, [x9, #DRV_VOL]
    mov w2, #'\\'
    strh w2, [x9, #DRV_CWD]
    ret

// x0 = drive (0-based). Returns x0 = its table entry.
drive_entry:
    address x9, drive_table
    mov x10, #DRV_SIZE
    madd x0, x0, x10, x9
    ret

// Returns x0 = the root object of canonical_drive (0 if none).
canonical_root:
    adrp x9, canonical_drive
    ldr x10, [x9, :lo12:canonical_drive]
    address x9, drive_table
    mov x0, #DRV_SIZE
    madd x9, x10, x0, x9
    ldr x0, [x9, #DRV_ROOT]
    ret

// x0 = drive (0-based, after ASSIGN). Makes its FAT volume live.
// Returns x1 = 0, or x1 = 1 with x0 = 15 for an unusable letter.
drive_select:
    frame
    cmp x0, #DRIVES
    b.hs 8f
    bl drive_entry
    ldr x2, [x0, #DRV_FLAGS]
    tbz x2, #0, 8f
    ldr x0, [x0, #DRV_VOL]
    bl fat_vol_select
    mov x1, #0
    unframe
8:
    mov x0, #15
    mov x1, #1
    unframe

// x0 = DOS drive number (0 default, 1 A:, ...). Applies ASSIGN and SUBST
// and returns x0 = the physical drive (0-based) with x1 = 0, or x1 = 1
// with x0 = 15.
drive_physical:
    adrp x9, current_drive
    ldr x9, [x9, :lo12:current_drive]
    subs x0, x0, #1
    csel x0, x9, x0, lo
    cmp x0, #DRIVES
    b.hs 8f
    address x9, drive_table
    mov x10, #DRV_SIZE
    madd x11, x0, x10, x9
    ldr x12, [x11, #DRV_ASSIGN]
    cbz x12, 1f
    sub x0, x12, #1
    madd x11, x0, x10, x9
1:
    ldr x12, [x11, #DRV_FLAGS]
    tbnz x12, #2, 8f            // joined drives cannot be named
    tbz x12, #1, 2f
    ldr x0, [x11, #DRV_TARGET]
    madd x11, x0, x10, x9
    ldr x12, [x11, #DRV_FLAGS]
2:
    tbz x12, #0, 8f
    mov x1, #0
    ret
8:
    mov x0, #15
    mov x1, #1
    ret

// x0 = ASCII path, x1 = 256-byte destination. The canonical result begins
// with '\' and names a path on canonical_drive; canonical_logical_drive and
// canonical_logical hold the drive and path as written (before SUBST and
// JOIN), which is what CHDIR records.
canonicalize_path:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    ldrb w2, [x19]
    cmp w2, #1                  // internal: 01h, drive, canonical path
    b.eq canon_raw
    adrp x21, current_drive
    ldr x21, [x21, :lo12:current_drive]
    cbz w2, 1f
    ldrb w3, [x19, #1]
    cmp w3, #':'
    b.ne 1f
    bic w2, w2, #0x20
    sub w21, w2, #'A'
    cmp w21, #DRIVES
    b.hs canon_bad_drive
    add x19, x19, #2
1:
    mov x0, x21
    bl drive_entry
    ldr x2, [x0, #DRV_ASSIGN]
    cbz x2, 2f
    sub x21, x2, #1
    mov x0, x21
    bl drive_entry
2:
    mov x22, x0
    ldr x2, [x22, #DRV_FLAGS]
    tbnz x2, #2, canon_bad_drive
    tst x2, #(DF_VALID | DF_SUBST)
    b.eq canon_bad_drive
    adrp x9, canonical_logical_drive
    str x21, [x9, :lo12:canonical_logical_drive]
    // The current directory of that drive.
    add x2, x22, #DRV_CWD
    adrp x9, current_drive
    ldr x9, [x9, :lo12:current_drive]
    cmp x9, x21
    b.ne 3f
    address x2, current_directory
3:
    mov x0, x19
    mov x1, x20
    bl canonical_core
    cbnz x1, canon_return
    mov x0, x20
    address x1, canonical_logical
    bl copy_cstring
    // SUBST: the logical path continues under the target directory.
    ldr x2, [x22, #DRV_FLAGS]
    tbz x2, #1, 5f
    ldr x21, [x22, #DRV_TARGET]
    address x0, canonical_temp
    add x1, x22, #DRV_PATH
    mov x2, #0
41:
    ldrb w3, [x1], #1
    cbz w3, 42f
    strb w3, [x0, x2]
    add x2, x2, #1
    b 41b
42:
    mov x1, x20
    ldrb w3, [x1, #1]
    cbnz w3, 43f
    cbnz x2, 44f                // "\" under a directory: just the directory
43:
    ldrb w3, [x1], #1
    cmp x2, #255
    b.hs canon_bad_path
    strb w3, [x0, x2]
    add x2, x2, #1
    cbnz w3, 43b
    b 45f
44:
    strb wzr, [x0, x2]
45:
    address x0, canonical_temp
    mov x1, x20
    bl copy_cstring
5:
    // JOIN: a path inside a join directory continues on the joined drive.
    address x9, drive_table
    mov x10, #0
6:
    mov x11, #DRV_SIZE
    madd x11, x10, x11, x9
    ldr x2, [x11, #DRV_FLAGS]
    tbz x2, #2, 69f
    ldr x2, [x11, #DRV_TARGET]
    cmp x2, x21
    b.ne 69f
    add x3, x11, #DRV_PATH
    mov x4, #0
61:
    ldrb w5, [x3, x4]
    cbz w5, 62f
    ldrb w6, [x20, x4]
    cmp w5, w6
    b.ne 69f
    add x4, x4, #1
    b 61b
62:
    ldrb w6, [x20, x4]
    cbz w6, 63f
    cmp w6, #'\\'
    b.ne 69f
    // Drop the join directory prefix (keep the separator).
    mov x5, #0
621:
    ldrb w6, [x20, x4]
    strb w6, [x20, x5]
    add x4, x4, #1
    add x5, x5, #1
    cbnz w6, 621b
    mov x21, x10
    b 7f
63:
    mov w6, #'\\'
    strh w6, [x20]
    mov x21, x10
    b 7f
69:
    add x10, x10, #1
    cmp x10, #DRIVES
    b.lo 6b
7:
    adrp x9, canonical_drive
    str x21, [x9, :lo12:canonical_drive]
    mov x0, x20
    mov x1, #0
canon_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe
canon_raw:
    ldrb w21, [x19, #1]
    adrp x9, canonical_logical_drive
    str x21, [x9, :lo12:canonical_logical_drive]
    add x0, x19, #2
    mov x1, x20
    address x2, canon_root_path
    bl canonical_core
    cbnz x1, canon_return
    mov x0, x20
    address x1, canonical_logical
    bl copy_cstring
    b 7b
canon_bad_drive:
    mov x0, #15
    mov x1, #1
    b canon_return
canon_bad_path:
    mov x0, #3
    mov x1, #1
    b canon_return

// Returns x0 = the buffer that holds drive x0's current directory.
drive_cwd:
    adrp x9, current_drive
    ldr x9, [x9, :lo12:current_drive]
    cmp x9, x0
    b.ne 1f
    address x0, current_directory
    ret
1:
    address x9, drive_table
    mov x10, #DRV_SIZE
    madd x0, x0, x10, x9
    add x0, x0, #DRV_CWD
    ret

// 19h: returns x0 = the current drive (0 = A:).
dos_get_drive:
    adrp x0, current_drive
    ldr x0, [x0, :lo12:current_drive]
    mov x1, #0
    ret

// 0Eh: x0 = drive (0 = A:). Returns x0 = the number of drive letters
// (LASTDRIVE, or more when block devices need them). An unusable drive
// leaves the current one, as DOS did.
dos_set_drive:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    cmp x19, #DRIVES
    b.hs 3f
    bl drive_entry
    mov x20, x0
    ldr x2, [x20, #DRV_FLAGS]
    tbnz x2, #2, 3f
    tst x2, #(DF_VALID | DF_SUBST)
    b.eq 3f
    adrp x9, current_drive
    ldr x10, [x9, :lo12:current_drive]
    cmp x10, x19
    b.eq 3f
    str x19, [x9, :lo12:current_drive]
    mov x0, x10                 // save the old drive's directory
    bl drive_entry
    add x1, x0, #DRV_CWD
    address x0, current_directory
    bl copy_cstring
    add x0, x20, #DRV_CWD
    address x1, current_directory
    bl copy_cstring
3:
    bl drive_count
    mov x1, #0
    ldp x19, x20, [sp], #16
    unframe

// Returns x0 = the number of drive letters: LASTDRIVE, at least one past
// the highest drive in use.
drive_count:
    address x9, config_lastdrive
    ldr x0, [x9]
    cmp x0, #5
    b.hs 1f
    mov x0, #5
1:
    address x9, drive_table
    mov x10, #0
2:
    ldr x11, [x9, #DRV_FLAGS]
    cbz x11, 3f
    add x12, x10, #1
    cmp x12, x0
    csel x0, x12, x0, hi
3:
    add x9, x9, #DRV_SIZE
    add x10, x10, #1
    cmp x10, #DRIVES
    b.lo 2b
    ret

// Installs a block device driver's unit as the next free drive letter.
// x0 = rw entry, x1 = sector size, x2 = total sectors. Returns x0 = the
// drive (0-based) with x1 = 0, or x1 = 1 when no letter or volume is left.
drive_add_block:
    frame
    stp x19, x20, [sp, #-16]!
    str x21, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x21, x2
    address x9, drive_table
    mov x10, #1
1:
    mov x11, #DRV_SIZE
    madd x11, x10, x11, x9
    ldr x2, [x11, #DRV_FLAGS]
    cbz x2, 2f
    add x10, x10, #1
    cmp x10, #DRIVES
    b.lo 1b
    b 8f
2:
    stp x10, x11, [sp, #-16]!
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bl fat_add_volume
    ldp x10, x11, [sp], #16
    cmn x0, #1
    b.eq 8f
    str x0, [x11, #DRV_VOL]
    mov w3, #DF_VALID
    str x3, [x11, #DRV_FLAGS]
    str x19, [x11, #DRV_RW]
    cmp x1, #0
    csel x2, x2, xzr, eq
    str x2, [x11, #DRV_ROOT]
    mov w3, #'\\'
    strh w3, [x11, #DRV_CWD]
    str x10, [sp, #-16]!
    mov x0, #0                  // the boot volume stays live by default
    bl fat_vol_select
    ldr x0, [sp], #16
    mov x1, #0
    b 9f
8:
    mov x1, #1
9:
    ldr x21, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// Returns x0 = the first free drive letter (0-based), or 26.
drive_next_free:
    address x9, drive_table
    mov x0, #1
1:
    mov x10, #DRV_SIZE
    madd x10, x0, x10, x9
    ldr x11, [x10, #DRV_FLAGS]
    cbz x11, 2f
    add x0, x0, #1
    cmp x0, #DRIVES
    b.lo 1b
2:
    ret

// x0 = physical drive: re-reads its boot record (after FORMAT, or when a
// disk reset finds it unformatted). Returns x1 = 0 when it holds a FAT.
drive_remount:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    bl drive_select
    cbnz x1, 9f
    bl fat_remount
    mov x20, x0
    mov x0, x19
    bl drive_entry
    mov x2, #0
    cbnz x20, 1f
    adrp x2, fat_root_obj
    ldr x2, [x2, :lo12:fat_root_obj]
1:
    str x2, [x0, #DRV_ROOT]
    cmp x20, #0
    cset x1, ne
    mov x0, #21
9:
    ldp x19, x20, [sp], #16
    unframe

.section .rodata
canon_root_path: .asciz "\\"
.section .bss
.balign 16
drive_table: .skip DRIVES * DRV_SIZE
current_drive: .skip 8
canonical_drive: .skip 8
canonical_logical_drive: .skip 8
canonical_logical: .skip 256
canonical_temp: .skip 512
.section .text
