// SPDX-License-Identifier: MIT
// File sharing and record locking, built in (SHARE.ASM / LOCK.ASM). DOS
// loaded SHARE as a TSR; here the open-file table is part of the kernel.
//
// Open-file table: one entry per underlying open object, holding its access
// (0 read, 1 write, 2 both), sharing mode (0 compatibility, 1 deny all,
// 2 deny write, 3 deny read, 4 deny none) and canonical path. Compatibility
// mode behaves as deny-none. Locks belong to an object and a process.
.equ SFT_ENTRIES, 64
.equ SFT_PATH, 256
.equ LOCK_ENTRIES, 32
.section .text

// x0 = ASCII path, x1 = access, x2 = sharing mode. Canonicalises the path
// into sft_scratch for sft_register. Returns x1=0, or x1=1 with x0=32.
sft_check:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x1
    mov x20, x2
    address x1, sft_scratch
    strb wzr, [x1]
    bl canonicalize_path
    cbnz x1, sft_check_ok       // the open itself reports the bad path
    mov x21, #0
1:
    address x9, sft_objects
    ldr x9, [x9, x21, lsl #3]
    cbz x9, 4f
    address x0, sft_paths
    add x0, x0, x21, lsl #8
    address x1, sft_scratch
    bl fat_strcasecmp
    cbnz x0, 4f
    address x9, sft_modes
    ldrb w9, [x9, x21]
    and w10, w9, #7             // existing access
    lsr w11, w9, #4             // existing sharing mode
    cmp w11, #1
    b.eq sft_check_violation
    cmp w11, #2
    b.ne 2f
    cbnz x19, sft_check_violation
2:
    cmp w11, #3
    b.ne 3f
    cmp x19, #1
    b.ne sft_check_violation
3:
    cmp x20, #1
    b.eq sft_check_violation
    cmp x20, #2
    b.ne 31f
    cbnz w10, sft_check_violation
31:
    cmp x20, #3
    b.ne 4f
    cmp w10, #1
    b.ne sft_check_violation
4:
    add x21, x21, #1
    cmp x21, #SFT_ENTRIES
    b.lo 1b
sft_check_ok:
    mov x0, #0
    mov x1, #0
    b sft_check_return
sft_check_violation:
    mov x0, #32
    mov x1, #1
sft_check_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = object, x1 = access, x2 = sharing mode (path from sft_check).
// A full table only loses sharing information, never the open.
sft_register:
    frame
    stp x19, x20, [sp, #-16]!
    address x9, sft_objects
    mov x10, #0
    mov x11, #-1
1:
    ldr x12, [x9, x10, lsl #3]
    cmp x12, x0
    b.eq 3f
    cbnz x12, 2f
    cmn x11, #1
    b.ne 2f
    mov x11, x10
2:
    add x10, x10, #1
    cmp x10, #SFT_ENTRIES
    b.lo 1b
    cmn x11, #1
    b.eq 4f
    mov x10, x11
3:
    str x0, [x9, x10, lsl #3]
    orr w1, w1, w2, lsl #4
    address x9, sft_modes
    strb w1, [x9, x10]
    address x0, sft_scratch
    address x1, sft_paths
    add x1, x1, x10, lsl #8
    bl copy_cstring
4:
    ldp x19, x20, [sp], #16
    unframe

// x0 = object being closed for the last time: drop its entry and locks.
sft_release:
    address x9, sft_objects
    mov x10, #0
1:
    ldr x11, [x9, x10, lsl #3]
    cmp x11, x0
    b.ne 2f
    str xzr, [x9, x10, lsl #3]
2:
    add x10, x10, #1
    cmp x10, #SFT_ENTRIES
    b.lo 1b
    address x9, lock_objects
    mov x10, #0
3:
    ldr x11, [x9, x10, lsl #3]
    cmp x11, x0
    b.ne 4f
    str xzr, [x9, x10, lsl #3]
4:
    add x10, x10, #1
    cmp x10, #LOCK_ENTRIES
    b.lo 3b
    ret

// x0 = ASCII path. Returns x0 = 1 when that file is open anywhere.
sft_path_open:
    frame
    stp x19, x20, [sp, #-16]!
    address x1, sft_probe
    bl canonicalize_path
    cbnz x1, 3f
    mov x19, #0
1:
    address x9, sft_objects
    ldr x9, [x9, x19, lsl #3]
    cbz x9, 2f
    address x0, sft_paths
    add x0, x0, x19, lsl #8
    address x1, sft_probe
    bl fat_strcasecmp
    cbz x0, 4f
2:
    add x19, x19, #1
    cmp x19, #SFT_ENTRIES
    b.lo 1b
3:
    mov x0, #0
    b 5f
4:
    mov x0, #1
5:
    ldp x19, x20, [sp], #16
    unframe

// ---------------------------------------------------------------------------
// 5Ch: x0 = 0 lock / 1 unlock, x1 = handle, x2 = offset, x3 = length.
dos_lock:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x21, x2
    adds x22, x2, x3            // end (exclusive)
    b.cs lock_invalid
    cmp x19, #1
    b.hi lock_invalid
    mov x0, x1
    bl file_handle
    cbz x0, lock_bad_handle
    mov x20, x0
    bl dev_id_of
    cmn x0, #1
    b.ne lock_invalid           // devices have no records to lock
    address x9, active_owner
    ldr x9, [x9]
    cbnz x19, lock_unlock
    // Any overlap with an existing region is a lock violation.
    mov x10, #0
    mov x11, #-1
1:
    address x12, lock_objects
    ldr x13, [x12, x10, lsl #3]
    cbnz x13, 2f
    cmn x11, #1
    b.ne 3f
    mov x11, x10
    b 3f
2:
    address x12, lock_starts
    ldr x14, [x12, x10, lsl #3]
    address x12, lock_ends
    ldr x15, [x12, x10, lsl #3]
    cmp x21, x15
    b.hs 3f
    cmp x14, x22
    b.hs 3f
    b lock_violation
3:
    add x10, x10, #1
    cmp x10, #LOCK_ENTRIES
    b.lo 1b
    cmn x11, #1
    b.eq lock_full
    address x12, lock_objects
    str x20, [x12, x11, lsl #3]
    address x12, lock_owners
    str x9, [x12, x11, lsl #3]
    address x12, lock_starts
    str x21, [x12, x11, lsl #3]
    address x12, lock_ends
    str x22, [x12, x11, lsl #3]
    b lock_success
lock_unlock:
    mov x10, #0
4:
    address x12, lock_objects
    ldr x13, [x12, x10, lsl #3]
    cmp x13, x20
    b.ne 5f
    address x12, lock_owners
    ldr x13, [x12, x10, lsl #3]
    cmp x13, x9
    b.ne 5f
    address x12, lock_starts
    ldr x13, [x12, x10, lsl #3]
    cmp x13, x21
    b.ne 5f
    address x12, lock_ends
    ldr x13, [x12, x10, lsl #3]
    cmp x13, x22
    b.ne 5f
    address x12, lock_objects
    str xzr, [x12, x10, lsl #3]
    b lock_success
5:
    add x10, x10, #1
    cmp x10, #LOCK_ENTRIES
    b.lo 4b
lock_violation:
    mov x0, #33
    b lock_error
lock_full:
    mov x0, #36
    b lock_error
lock_bad_handle:
    mov x0, #6
    b lock_error
lock_invalid:
    mov x0, #1
lock_error:
    mov x1, #1
    b lock_return
lock_success:
    mov x0, #0
    mov x1, #0
lock_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = object, x1 = position, x2 = length about to be read or written.
// Returns x0 = 0, or 33 when another handle or process holds a lock there.
lock_check:
    adds x2, x1, x2
    b.cs 3f
    address x9, active_owner
    ldr x9, [x9]
    mov x10, #0
1:
    address x12, lock_objects
    ldr x13, [x12, x10, lsl #3]
    cbz x13, 2f
    address x12, lock_starts
    ldr x14, [x12, x10, lsl #3]
    address x12, lock_ends
    ldr x15, [x12, x10, lsl #3]
    cmp x1, x15
    b.hs 2f
    cmp x14, x2
    b.hs 2f
    cmp x13, x0
    b.ne 4f
    address x12, lock_owners
    ldr x13, [x12, x10, lsl #3]
    cmp x13, x9
    b.ne 4f
2:
    add x10, x10, #1
    cmp x10, #LOCK_ENTRIES
    b.lo 1b
3:
    mov x0, #0
    ret
4:
    mov x0, #33
    ret

// x0 = process owner id: drop its locks when it ends.
lock_release_owner:
    address x9, lock_owners
    address x11, lock_objects
    mov x10, #0
1:
    ldr x12, [x9, x10, lsl #3]
    cmp x12, x0
    b.ne 2f
    str xzr, [x11, x10, lsl #3]
2:
    add x10, x10, #1
    cmp x10, #LOCK_ENTRIES
    b.lo 1b
    ret

.section .bss
.balign 16
sft_objects: .skip 8 * SFT_ENTRIES
sft_modes: .skip SFT_ENTRIES
.balign 16
sft_paths: .skip SFT_PATH * SFT_ENTRIES
sft_scratch: .skip SFT_PATH
sft_probe: .skip SFT_PATH
lock_objects: .skip 8 * LOCK_ENTRIES
lock_owners: .skip 8 * LOCK_ENTRIES
lock_starts: .skip 8 * LOCK_ENTRIES
lock_ends: .skip 8 * LOCK_ENTRIES
