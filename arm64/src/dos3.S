// SPDX-License-Identifier: MIT
// Remaining DOS functions: FCB searches, wildcard delete/rename, random
// block I/O and filename parsing (FCB.ASM, FCBIO.ASM, FCBIO2.ASM, PARSE),
// extended FCBs, temporary files (5Ah), TRUENAME (60h) and extended
// open/create (6Ch).
.equ FS_DTA, 0                  // private 280-byte search DTA
.equ FS_PATTERN, 280            // 11-byte FCB pattern, upper case
.equ FS_ATTR, 291
.equ FS_EXT, 292                // caller used an extended FCB
.equ FS_LABEL, 293              // volume-label search state
.equ FS_DRIVE, 294              // drive searched (1 = A:)
.equ FS_NAME, 296               // found name, 11 bytes FCB form
.equ FS_SIZE, 320
.equ FCB_LIST_MAX, 256
.section .text

// ---------------------------------------------------------------------------
// Extended FCBs: FFh, five reserved bytes, attribute, then a standard FCB.
.macro fcbx name, target
\name:
    ldrb w9, [x0]
    cmp w9, #0xff
    b.ne \target
    add x0, x0, #7
    b \target
.endm
fcbx fcbx_open, dos_fcb_open
fcbx fcbx_close, dos_fcb_close
fcbx fcbx_seq_read, dos_fcb_seq_read
fcbx fcbx_seq_write, dos_fcb_seq_write
fcbx fcbx_random_read, dos_fcb_random_read
fcbx fcbx_random_write, dos_fcb_random_write
fcbx fcbx_get_length, dos_fcb_get_length
fcbx fcbx_get_position, dos_fcb_get_position
fcbx fcbx_block_read, dos_fcb_block_read
fcbx fcbx_block_write, dos_fcb_block_write

// 16h with an extended FCB creates the file with its attribute byte.
fcbx_create:
    ldrb w9, [x0]
    cmp w9, #0xff
    b.ne dos_fcb_create
    frame
    stp x19, x20, [sp, #-16]!
    ldrb w20, [x0, #6]
    add x19, x0, #7
    mov x0, x19
    bl dos_fcb_create
    cbnz x0, 1f
    mov x9, #0x27
    and x20, x20, x9
    cbz x20, 1f
    mov x0, x19
    bl fcb_filename
    mov x1, #1
    mov x2, x20
    bl dos_attributes
    mov x0, #0
1:
    mov x1, #0
    ldp x19, x20, [sp], #16
    unframe

// ---------------------------------------------------------------------------
// x0 = FCB as given by the caller, x1 = search state. Sets the pattern and
// attribute. Returns x0 = standard FCB part, or 0 for an invalid drive.
fcb_search_setup:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x20, x1
    strb wzr, [x20, #FS_ATTR]
    strb wzr, [x20, #FS_EXT]
    strb wzr, [x20, #FS_LABEL]
    ldrb w9, [x0]
    cmp w9, #0xff
    b.ne 1f
    ldrb w9, [x0, #6]
    strb w9, [x20, #FS_ATTR]
    mov w9, #1
    strb w9, [x20, #FS_EXT]
    add x0, x0, #7
1:
    mov x19, x0
    ldrb w0, [x19]
    cmp w0, #26
    b.hi 3f
    cbnz w0, 11f
    adrp x9, current_drive
    ldr x0, [x9, :lo12:current_drive]
    add x0, x0, #1
11:
    strb w0, [x20, #FS_DRIVE]
    bl drive_physical           // a letter that names no drive
    cbnz x1, 3f
    mov x21, #0
2:
    add x9, x19, x21
    ldrb w0, [x9, #1]
    bl nls_upper
    add x9, x20, x21
    strb w0, [x9, #FS_PATTERN]
    add x21, x21, #1
    cmp x21, #11
    b.lo 2b
    mov x0, x19
    b 4f
3:
    mov x0, #0
4:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = ASCII name, x1 = 11-byte destination. Returns x0 = 0 when the name
// has an 8.3 form (FCB calls see only 8.3 names), 1 otherwise.
fcb_name11:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x9, #0
    mov w10, #' '
1:
    strb w10, [x20, x9]
    add x9, x9, #1
    cmp x9, #11
    b.lo 1b
    ldrb w9, [x19]
    cmp w9, #'.'
    b.ne 3f
    strb w9, [x20]              // "." and ".."
    ldrb w10, [x19, #1]
    cbz w10, fcb_name11_ok
    cmp w10, #'.'
    b.ne fcb_name11_bad
    strb w10, [x20, #1]
    ldrb w10, [x19, #2]
    cbz w10, fcb_name11_ok
    b fcb_name11_bad
3:
    mov x21, #0                 // destination index
    mov x22, #8                 // limit of the current part
4:
    ldrb w0, [x19], #1
    cbz w0, fcb_name11_end
    cmp w0, #'.'
    b.ne 5f
    cmp x22, #11
    b.eq fcb_name11_bad         // second dot
    cbz x21, fcb_name11_bad
    mov x21, #8
    mov x22, #11
    b 4b
5:
    cmp w0, #' '
    b.ls fcb_name11_bad
    address x9, fcb_bad_chars
6:
    ldrb w10, [x9], #1
    cbz w10, 7f
    cmp w10, w0
    b.eq fcb_name11_bad
    b 6b
7:
    cmp x21, x22
    b.hs fcb_name11_bad
    bl nls_upper
    strb w0, [x20, x21]
    add x21, x21, #1
    b 4b
fcb_name11_end:
    cbz x21, fcb_name11_bad
fcb_name11_ok:
    mov x0, #0
    b 8f
fcb_name11_bad:
    mov x0, #1
8:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// The same, as "d:NAME.EXT" with the drive of the last fcb_collect.
fcb_name_ascii_drive:
    address x9, fcb_collect_state
    ldrb w9, [x9, #FS_DRIVE]
    add w9, w9, #('A' - 1)
    strb w9, [x1], #1
    mov w9, #':'
    strb w9, [x1], #1
    b fcb_name_ascii

// x0 = 11-byte FCB name, x1 = destination. Writes "NAME.EXT".
fcb_name_ascii:
    mov x9, #0
1:
    ldrb w10, [x0, x9]
    cmp w10, #' '
    b.eq 2f
    strb w10, [x1], #1
    add x9, x9, #1
    cmp x9, #8
    b.lo 1b
2:
    ldrb w10, [x0, #8]
    cmp w10, #' '
    b.eq 4f
    mov w10, #'.'
    strb w10, [x1], #1
    mov x9, #8
3:
    ldrb w10, [x0, x9]
    cmp w10, #' '
    b.eq 4f
    strb w10, [x1], #1
    add x9, x9, #1
    cmp x9, #11
    b.lo 3b
4:
    strb wzr, [x1]
    ret

// x0 = state, x1 = 1 first / 0 next. Searches the current directory.
// Returns x0 = 0 with FS_NAME and the private DTA filled, 1 when exhausted.
fcb_search_core:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    ldrb w9, [x19, #FS_ATTR]
    tbnz w9, #3, fcb_search_label
    address x9, current_dta
    ldr x21, [x9]
    address x9, current_dta_capacity
    ldr x22, [x9]
    mov x0, x19
    mov x1, #FS_PATTERN
    bl dos_set_dta
    cbz x20, 1f
    address x0, fcb_search_path // "d:*.*"
    ldrb w9, [x19, #FS_DRIVE]
    add w9, w9, #('A' - 1)
    strb w9, [x0]
    ldrb w1, [x19, #FS_ATTR]
    mov x9, #0x16               // hidden, system, directory
    and x1, x1, x9
    bl dos_find_first
    b 2f
1:
    bl dos_find_next
2:
    cbnz x1, fcb_search_none
    add x0, x19, #24
    add x1, x19, #FS_NAME
    bl fcb_name11
    cbnz x0, 1b
    mov x9, #0
3:
    add x10, x19, x9
    ldrb w11, [x10, #FS_PATTERN]
    ldrb w12, [x10, #FS_NAME]
    cmp w11, #'?'
    b.eq 4f
    cmp w11, w12
    b.ne 1b
4:
    add x9, x9, #1
    cmp x9, #11
    b.lo 3b
    mov x20, #0
    b fcb_search_restore
fcb_search_none:
    mov x20, #1
fcb_search_restore:
    mov x0, x21
    mov x1, x22
    bl dos_set_dta
    mov x0, x20
    b fcb_search_return
// Attribute 8: the volume label, from the boot record.
fcb_search_label:
    cbz x20, 5f
    ldrb w9, [x19, #FS_LABEL]
    cbnz w9, 5f
    mov w9, #1
    strb w9, [x19, #FS_LABEL]
    ldrb w0, [x19, #FS_DRIVE]   // that drive's volume
    bl disk_check_drive
    cbnz x1, 5f
    adrp x9, fat_mounted
    ldr x9, [x9, :lo12:fat_mounted]
    cbz x9, 5f
    address x0, fat_boot_copy
    add x0, x0, #43
    ldv x9, fat_type
    cmp x9, #32
    b.ne 6f
    add x0, x0, #28
6:
    address x1, fcb_no_name
    mov x9, #0
7:
    ldrb w10, [x0, x9]
    ldrb w11, [x1, x9]
    cmp w10, w11
    b.ne 8f
    add x9, x9, #1
    cmp x9, #11
    b.lo 7b
    b 5f                        // "NO NAME": no label
8:
    add x1, x19, #FS_NAME
    mov x2, #11
    bl copy_bytes
    mov x9, #8
    str x9, [x19]               // DTA attributes
    str xzr, [x19, #8]
    str wzr, [x19, #16]
    mov x0, #0
    b fcb_search_return
5:
    mov x0, #1
fcb_search_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = state. Writes the found entry to the caller's DTA as an unopened
// FCB (extended when the search used one). Returns x0 = AL.
fcb_search_emit:
    address x9, current_dta_capacity
    ldr x9, [x9]
    ldrb w10, [x0, #FS_EXT]
    mov x11, #33
    cbz w10, 1f
    mov x11, #40
1:
    cmp x9, x11
    b.lo 3f
    address x9, current_dta
    ldr x9, [x9]
    cbz w10, 2f
    mov w11, #0xff
    strb w11, [x9]
    str wzr, [x9, #1]
    strb wzr, [x9, #5]
    ldrb w11, [x0, #FS_ATTR]
    strb w11, [x9, #6]
    add x9, x9, #7
2:
    ldrb w11, [x0, #FS_DRIVE]
    strb w11, [x9]
    mov x12, #0
4:
    add x13, x0, x12
    ldrb w11, [x13, #FS_NAME]
    add x13, x9, x12
    strb w11, [x13, #1]
    add x12, x12, #1
    cmp x12, #11
    b.lo 4b
    ldr x11, [x0]
    strb w11, [x9, #12]
    mov x12, #13
5:
    strb wzr, [x9, x12]
    add x12, x12, #1
    cmp x12, #23
    b.lo 5b
    ldrh w11, [x0, #16]         // time
    strb w11, [x9, #23]
    lsr w11, w11, #8
    strb w11, [x9, #24]
    ldrh w11, [x0, #18]         // date
    strb w11, [x9, #25]
    lsr w11, w11, #8
    strb w11, [x9, #26]
    strb wzr, [x9, #27]
    strb wzr, [x9, #28]
    ldr x11, [x0, #8]
    strb w11, [x9, #29]
    lsr x11, x11, #8
    strb w11, [x9, #30]
    lsr x11, x11, #8
    strb w11, [x9, #31]
    lsr x11, x11, #8
    strb w11, [x9, #32]
    mov x0, #0
    ret
3:
    mov x0, #255
    ret

// 11h: x0 = FCB (standard or extended) with a pattern ('?' wildcards).
dos_fcb_find_first:
    frame
    address x1, fcb_find_state
    bl fcb_search_setup
    cbz x0, 1f
    address x0, fcb_find_state
    mov x1, #1
    bl fcb_search_core
    cbnz x0, 1f
    address x0, fcb_find_state
    bl fcb_search_emit
    b 2f
1:
    mov x0, #255
2:
    mov x1, #0
    unframe
// 12h: continues the last 11h search.
dos_fcb_find_next:
    frame
    address x0, fcb_find_state
    mov x1, #0
    bl fcb_search_core
    cbnz x0, 1f
    address x0, fcb_find_state
    bl fcb_search_emit
    b 2f
1:
    mov x0, #255
2:
    mov x1, #0
    unframe

// x0 = caller's FCB. Collects matching file names (FCB form) into
// fcb_list. Returns x0 = standard FCB part (0 if invalid), x1 = count.
fcb_collect:
    frame
    stp x19, x20, [sp, #-16]!
    address x1, fcb_collect_state
    bl fcb_search_setup
    mov x19, x0
    mov x20, #0
    cbz x19, 3f
    mov x1, #1
1:
    address x0, fcb_collect_state
    bl fcb_search_core
    cbnz x0, 3f
    address x9, fcb_collect_state
    ldr x10, [x9]
    tst x10, #0x18              // never directories or the label
    b.ne 2f
    cmp x20, #FCB_LIST_MAX
    b.hs 3f
    add x0, x9, #FS_NAME
    address x1, fcb_list
    mov x2, #11
    madd x1, x20, x2, x1
    bl copy_bytes
    add x20, x20, #1
2:
    mov x1, #0
    b 1b
3:
    mov x0, x19
    mov x1, x20
    ldp x19, x20, [sp], #16
    unframe

// 13h: delete every file matching the FCB name. AL=0 if any was deleted.
dos_fcb_delete_wild:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    bl fcb_collect
    mov x19, x1
    mov x20, #0
    mov x21, #0                 // deleted
1:
    cmp x20, x19
    b.hs 2f
    address x0, fcb_list
    mov x2, #11
    madd x0, x20, x2, x0
    address x1, fcb_ascii_old
    bl fcb_name_ascii_drive     // on the drive the FCB named
    address x0, fcb_ascii_old
    bl dos_delete
    cbnz x1, 3f
    add x21, x21, #1
3:
    add x20, x20, #1
    b 1b
2:
    cmp x21, #0
    mov x0, #255
    csel x0, x0, xzr, eq
    mov x1, #0
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// 17h: FCB bytes 1-11 old name (wildcards allowed), 17-27 new name; a '?'
// in the new name keeps the old character. AL=0 if all renames succeeded.
dos_fcb_rename:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    bl fcb_collect
    mov x22, x0
    mov x19, x1
    mov x20, #0
    mov x23, #0                 // failures
    cbz x22, 4f
    cbz x19, 4f
1:
    cmp x20, x19
    b.hs 5f
    address x24, fcb_list
    mov x2, #11
    madd x24, x20, x2, x24
    address x10, fcb_new_name
    mov x9, #0
2:
    add x11, x22, x9
    ldrb w0, [x11, #17]
    cmp w0, #'?'
    b.ne 3f
    ldrb w0, [x24, x9]
    b 31f
3:
    str x9, [sp, #-16]!
    bl nls_upper
    ldr x9, [sp], #16
    address x10, fcb_new_name
31:
    strb w0, [x10, x9]
    add x9, x9, #1
    cmp x9, #11
    b.lo 2b
    mov x0, x24
    address x1, fcb_ascii_old
    bl fcb_name_ascii_drive
    address x0, fcb_new_name
    address x1, fcb_ascii_new
    bl fcb_name_ascii_drive
    address x0, fcb_ascii_old
    address x1, fcb_ascii_new
    bl dos_rename
    cbz x1, 6f
    add x23, x23, #1
6:
    add x20, x20, #1
    b 1b
4:
    mov x0, #255
    b 7f
5:
    cmp x23, #0
    mov x0, #255
    csel x0, xzr, x0, eq
7:
    mov x1, #0
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// ---------------------------------------------------------------------------
// 27h / 28h: x0 = open FCB, x1 = record count. Random block transfer at the
// random record through the DTA; the random record advances. Returns x0 = AL
// (0 done, 1 EOF / disk full, 2 DTA too small, 3 partial record) and x2 =
// records transferred. 28h with x1 = 0 sets the file size to the random
// record position.
dos_fcb_block_read:
    mov x2, #0
    b fcb_block_io
dos_fcb_block_write:
    mov x2, #1
fcb_block_io:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x21, x2
    ldrh w22, [x19, #14]        // record size
    cbz x22, fcb_block_invalid
    ldr w23, [x19, #33]         // random record
    cmp x22, #64                // records of 64 bytes or more use only
    b.lo 1f                     // three bytes of it (FCBIO2.ASM)
    and w23, w23, #0xffffff
1:
    mov x0, x19
    bl fcb_handle
    mov x24, x0
    mul x25, x23, x22           // byte position
    cbz x21, 1f
    cbnz x20, 1f
    // 28h with CX=0: truncate or extend.
    mov x0, x24
    bl file_handle
    cbz x0, fcb_block_invalid
    mov x1, x25
    bl resize_file
    cbnz x0, fcb_block_invalid
    str w25, [x19, #16]
    mov x26, #0
    mov x0, #0
    b fcb_block_return
1:
    mul x26, x20, x22           // bytes requested
    address x9, current_dta_capacity
    ldr x9, [x9]
    cmp x26, x9
    b.hi fcb_block_dta
    mov x0, x24
    mov x1, x25
    mov x2, #0
    bl dos_seek
    cbnz x1, fcb_block_invalid
    address x1, current_dta
    ldr x1, [x1]
    mov x0, x24
    mov x2, x26
    cbnz x21, 2f
    bl dos_read
    b 3f
2:
    bl dos_write
3:
    cbnz x1, fcb_block_invalid
    mov x9, x0                  // bytes moved
    udiv x10, x9, x22           // whole records
    msub x11, x10, x22, x9      // partial bytes
    cbnz x21, fcb_block_wrote
    mov x0, #0
    cbz x11, 5f
    // Partial record: zero-fill its remainder in the DTA.
    address x12, current_dta
    ldr x12, [x12]
    add x13, x10, #1
    mul x13, x13, x22
4:
    cmp x9, x13
    b.hs 41f
    strb wzr, [x12, x9]
    add x9, x9, #1
    b 4b
41:
    add x10, x10, #1
    mov x0, #3
    b fcb_block_advance
5:
    cmp x9, x26
    b.hs fcb_block_advance
    mov x0, #1
    b fcb_block_advance
fcb_block_wrote:
    cmp x9, x26
    cset x0, lo                 // short write: disk full
    add x12, x25, x9
    ldr w13, [x19, #16]
    cmp x12, x13
    csel x12, x12, x13, hi
    str w12, [x19, #16]
fcb_block_advance:
    mov x26, x10
    add x23, x23, x10
    strh w23, [x19, #33]
    lsr w9, w23, #16
    strb w9, [x19, #35]
    cmp x22, #64
    b.hs 1f
    lsr w9, w23, #24
    strb w9, [x19, #36]
1:
    lsr x9, x23, #7
    strh w9, [x19, #12]
    and x9, x23, #127
    strb w9, [x19, #32]
    b fcb_block_return
fcb_block_dta:
    mov x26, #0
    mov x0, #2
    b fcb_block_return
fcb_block_invalid:
    mov x26, #0
    mov x0, #255
fcb_block_return:
    mov x2, x26
    mov x1, #0
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// ---------------------------------------------------------------------------
// 29h: x0 = string, x1 = FCB, x2 = control (bit 0 skip leading separators,
// bit 1 keep drive, bit 2 keep name, bit 3 keep extension when absent).
// Returns x0 = AL (0 no wildcards, 1 wildcards, FFh invalid drive) and
// x2 = first character after the parsed name.
dos_parse_filename:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, #0                 // wildcard seen
    mov x23, #0                 // invalid drive
    tbnz x21, #1, 1f
    strb wzr, [x20]
1:
    tbnz x21, #2, 2f
    add x0, x20, #1
    mov x1, #8
    bl parse_blank
2:
    tbnz x21, #3, 3f
    add x0, x20, #9
    mov x1, #3
    bl parse_blank
3:
    bl parse_skip_white
    tbz x21, #0, 5f
    ldrb w9, [x19]
    address x10, parse_separators
4:
    ldrb w11, [x10], #1
    cbz w11, 5f
    cmp w11, w9
    b.ne 4b
    add x19, x19, #1
    bl parse_skip_white
5:
    ldrb w9, [x19, #1]
    cmp w9, #':'
    b.ne 6f
    ldrb w0, [x19]
    bl nls_upper
    sub w0, w0, #'A' - 1
    cmp w0, #26
    b.hi parse_bad_drive
    cbz w0, parse_bad_drive
    strb w0, [x20]
    bl drive_physical           // AL=FFh for a letter that names no drive
    cbz x1, 51f
    mov x23, #1
51:
    add x19, x19, #2
    b 6f
parse_bad_drive:
    mov x23, #1
    add x19, x19, #2
6:
    add x0, x20, #1
    mov x1, #8
    bl parse_field
    ldrb w9, [x19]
    cmp w9, #'.'
    b.ne 7f
    add x19, x19, #1
    add x0, x20, #9
    mov x1, #3
    bl parse_field
    cbnz x0, 7f
    add x0, x20, #9             // "NAME." has a blank extension
    mov x1, #3
    bl parse_blank
7:
    mov x0, x22
    cbz x23, 8f
    mov x0, #255
8:
    mov x2, x19
    mov x1, #0
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe
parse_skip_white:
    ldrb w9, [x19]
    cmp w9, #' '
    b.eq 1f
    cmp w9, #9
    b.ne 2f
1:
    add x19, x19, #1
    b parse_skip_white
2:
    ret
// x0 = field, x1 = width: fill with blanks.
parse_blank:
    mov w9, #' '
1:
    strb w9, [x0], #1
    subs x1, x1, #1
    b.ne 1b
    ret
// x0 = field, x1 = width. Copies name characters from x19 (advancing it);
// '*' fills the rest with '?'. Returns x0 = characters taken (0 = absent).
parse_field:
    frame
    stp x24, x25, [sp, #-16]!
    stp x26, x27, [sp, #-16]!
    mov x24, x0
    mov x25, x1
    mov x26, #0                 // characters stored
    mov x27, #0                 // anything parsed
1:
    ldrb w0, [x19]
    bl parse_is_terminator
    cbnz x9, 4f
    ldrb w0, [x19]
    add x19, x19, #1
    mov x27, #1
    cmp w0, #'*'
    b.ne 2f
    mov x22, #1
    mov w10, #'?'
11:
    cmp x26, x25
    b.hs 1b
    strb w10, [x24, x26]
    add x26, x26, #1
    b 11b
2:
    cmp w0, #'?'
    b.ne 3f
    mov x22, #1
3:
    cmp x26, x25
    b.hs 1b                     // extra characters are skipped
    bl nls_upper
    strb w0, [x24, x26]
    add x26, x26, #1
    b 1b
4:
    cbz x27, 6f
    mov w10, #' '
5:
    cmp x26, x25
    b.hs 6f
    strb w10, [x24, x26]
    add x26, x26, #1
    b 5b
6:
    mov x0, x27
    ldp x26, x27, [sp], #16
    ldp x24, x25, [sp], #16
    unframe
// w0 = character. x9 = 1 if it ends a name field.
parse_is_terminator:
    mov x9, #1
    cmp w0, #' '
    b.ls 2f
    address x10, parse_terminators
1:
    ldrb w11, [x10], #1
    cbz w11, 3f
    cmp w11, w0
    b.eq 2f
    b 1b
3:
    mov x9, #0
2:
    ret

// ---------------------------------------------------------------------------
// 5Ah: x0 = directory path buffer (room for 13 more bytes), x1 = attributes.
// Appends a unique name and creates the file. Returns x0 = handle.
dos_create_temp:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x21, x0
1:
    ldrb w9, [x21]
    cbz w9, 2f
    add x21, x21, #1
    b 1b
2:
    cmp x21, x19
    b.eq 3f
    ldurb w9, [x21, #-1]
    cmp w9, #'\\'
    b.eq 3f
    cmp w9, #'/'
    b.eq 3f
    cmp w9, #':'
    b.eq 3f
    mov w9, #'\\'
    strb w9, [x21], #1
3:
    mov x22, #64                // attempts
    address x9, dos_temp_seed
    ldr x10, [x9]
    cbnz x10, 4f
    bl dos_get_time
    lsl x10, x0, #24
    orr x10, x10, x2, lsl #16
    orr x10, x10, x3, lsl #8
    orr x10, x10, x4
    address x9, dos_temp_seed
    str x10, [x9]
4:
    address x9, dos_temp_seed
    ldr x10, [x9]
    mov x11, #0x4e6d
    movk x11, #0x41c6, lsl #16  // 1103515245
    mul x10, x10, x11
    mov x12, #12345
    add x10, x10, x12
    and x10, x10, #0xffffffff
    str x10, [x9]
    mov x11, #28
5:
    lsr x12, x10, x11
    and x12, x12, #15
    cmp x12, #10
    add x13, x12, #'0'
    add x14, x12, #('A' - 10)
    csel x12, x13, x14, lo
    strb w12, [x21], #1
    subs x11, x11, #4
    b.pl 5b
    strb wzr, [x21]
    sub x21, x21, #8
    mov x0, x19
    mov x1, x20
    bl dos_create_new
    cbz x1, 6f
    cmp x0, #80
    b.ne 6f
    subs x22, x22, #1
    b.ne 4b
6:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// 60h: x0 = path, x1 = 128-byte destination. Stores the canonical name
// "A:\DIR\FILE" in upper case ("A:/NUL" for devices). Returns x0 = x1.
dos_truename:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    bl dev_lookup
    cbz x0, 1f
    ldr x0, [x0, #DEV_NAME]
    mov w9, #'A'
    strb w9, [x20]
    mov w9, #':'
    strb w9, [x20, #1]
    mov w9, #'/'
    strb w9, [x20, #2]
    add x1, x20, #3
    bl copy_cstring
    b 3f
1:
    mov x0, x19
    address x1, truename_buffer
    bl canonicalize_path
    cbnz x1, 4f
    ldv x9, canonical_drive     // the physical drive, after SUBST and JOIN
    add w9, w9, #'A'
    strb w9, [x20]
    mov w9, #':'
    strb w9, [x20, #1]
    address x19, truename_buffer
    add x9, x20, #2
    mov x12, #125
2:
    ldrb w0, [x19], #1
    str x9, [sp, #-16]!
    bl nls_upper
    ldr x9, [sp], #16
    strb w0, [x9], #1
    cbz w0, 3f
    subs x12, x12, #1
    b.ne 2b
    strb wzr, [x9]
3:
    mov x0, x20
    mov x1, #0
4:
    ldp x19, x20, [sp], #16
    unframe

// 6Ch: x0 = path, x1 = open mode (3Dh byte; bits 13-14 accepted),
// x2 = attributes for creation, x3 = action: low nibble if the file exists
// (0 fail, 1 open, 2 replace), high nibble if not (0 fail, 1 create).
// Returns x0 = handle, x2 = 1 opened, 2 created, 3 replaced.
dos_extended_open:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    and x20, x1, #0xff
    mov x21, x2
    mov x22, x3
    tst x22, #~0xff
    b.ne xopen_invalid
    and x9, x22, #15
    cmp x9, #2
    b.hi xopen_invalid
    lsr x10, x22, #4
    cmp x10, #1
    b.hi xopen_invalid
    orr x9, x9, x10
    cbz x9, xopen_invalid
    mov x0, x19
    mov x1, x20
    bl dos_open
    cbnz x1, xopen_missing
    and x9, x22, #15
    cbz x9, xopen_exists
    mov x2, #1
    cmp x9, #1
    b.eq xopen_done
    // Replace: truncate through the new handle.
    mov x21, x0
    and x9, x20, #7
    cbz x9, xopen_close_denied
    bl file_handle
    mov x1, #0
    bl resize_file
    cbnz x0, xopen_close_denied
    mov x0, x21
    mov x2, #3
    b xopen_done
xopen_missing:
    cmp x0, #2
    b.ne xopen_error
    lsr x9, x22, #4
    cbz x9, xopen_error
    mov x0, x19
    mov x1, x21
    mov x2, x20                 // the caller's access and sharing mode
    bl dos_create_mode
    cbnz x1, xopen_return
    mov x2, #2
xopen_done:
    mov x1, #0
    b xopen_return
xopen_exists:
    bl dos_close
    mov x0, #80
    b xopen_error
xopen_close_denied:
    mov x0, x21
    bl dos_close
    mov x0, #5
    b xopen_error
xopen_invalid:
    mov x0, #1
xopen_error:
    mov x1, #1
xopen_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

.section .data
fcb_search_path: .asciz "A:*.*"
.section .rodata
fcb_no_name: .ascii "NO NAME    "
fcb_bad_chars: .asciz "\"*+,/:;<=>?[\\]|"
parse_separators: .asciz ":.;,=+"
parse_terminators: .asciz ".\"/\\[]:|<>+=;,"

.section .bss
.balign 16
fcb_find_state: .skip FS_SIZE
fcb_collect_state: .skip FS_SIZE
fcb_list: .skip 11 * FCB_LIST_MAX
fcb_new_name: .skip 16
fcb_ascii_old: .skip 16
fcb_ascii_new: .skip 16
truename_buffer: .skip 256
.balign 8
dos_temp_seed: .skip 8
