// SPDX-License-Identifier: MIT
// Standard 37-byte FCB records survive as data; pointers/calls are AArch64.
// Reserved bytes 24..27 contain a native handle and validation signature.
// FCB calls retain AL-style status in x0, with x1=0 (no carry flag convention).
.section .text
fcb_filename:
    ldrb w1, [x0]
    cmp w1, #1
    b.hi fcb_name_invalid      // standard FCB, default drive or A:
    add x9, x0, #1
    address x10, fcb_path
    mov x11, #0
    mov x12, #8
    mov x13, #0
1:
    ldrb w2, [x9], #1
    cmp w2, #' '
    b.eq fcb_name_padding
    cbnz x13, fcb_name_invalid
    cbz w2, fcb_name_invalid
    strb w2, [x10, x11]
    add x11, x11, #1
    b 2f
fcb_name_padding:
    mov x13, #1
2:
    subs x12, x12, #1
    b.ne 1b
    cbz x11, fcb_name_invalid
    mov x12, #3
    mov x13, #0
    mov x14, #0
3:
    ldrb w2, [x9], #1
    cmp w2, #' '
    b.eq fcb_ext_padding
    cbnz x13, fcb_name_invalid
    cbz w2, fcb_name_invalid
    cbnz x14, 4f
    mov w3, #'.'
    strb w3, [x10, x11]
    add x11, x11, #1
    mov x14, #1
4:
    strb w2, [x10, x11]
    add x11, x11, #1
    b 5f
fcb_ext_padding:
    mov x13, #1
5:
    subs x12, x12, #1
    b.ne 3b
    strb wzr, [x10, x11]
    mov x0, x10
    mov x1, #0
    ret
fcb_name_invalid:
    mov x0, #255
    mov x1, #1
    ret

dos_fcb_open:
    mov x1, #0
    b fcb_open_common
dos_fcb_create:
    mov x1, #1
fcb_open_common:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    bl fcb_filename
    cbnz x1, fcb_open_failure
    cbnz x20, 1f
    mov x1, #2
    bl dos_open
    cbz x1, 2f
    cmp x0, #5
    b.ne fcb_open_failure
    address x0, fcb_path
    mov x1, #0
    bl dos_open
    b 2f
1:
    mov x1, #0
    bl dos_create
2:
    cbnz x1, fcb_open_failure
    mov x20, x0
    strh w20, [x19, #24]
    mov w2, #0x4641
    strh w2, [x19, #26]
    strh wzr, [x19, #12]
    mov w2, #128
    strh w2, [x19, #14]
    strb wzr, [x19, #32]
    bl file_handle
    bl get_file_info
    cbnz x0, fcb_open_close_failure
    ldr x2, [x1, #8]
    lsr x3, x2, #32
    cbnz x3, fcb_open_close_failure
    str w2, [x19, #16]
    add x0, x1, #56
    bl pack_efi_time
    strh w0, [x19, #20]
    strh w1, [x19, #22]
    mov x0, #0
    b fcb_open_return
fcb_open_close_failure:
    mov x0, x20
    bl dos_close
    str wzr, [x19, #24]
fcb_open_failure:
    mov x0, #255
fcb_open_return:
    mov x1, #0
    ldp x19, x20, [sp], #16
    unframe

fcb_handle:
    ldrh w2, [x0, #26]
    mov w3, #0x4641
    cmp w2, w3
    b.ne 1f
    ldrh w0, [x0, #24]
    ret
1:
    mov x0, #32
    ret
dos_fcb_close:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
    bl fcb_handle
    bl dos_close
    cbnz x1, 1f
    str wzr, [x19, #24]
1:
    cmp x1, #0
    mov x0, #255
    csel x0, xzr, x0, eq
    mov x1, #0
    ldr x19, [sp], #16
    unframe
dos_fcb_delete:
    frame
    bl fcb_filename
    cbnz x1, 1f
    bl dos_delete
1:
    cmp x1, #0
    mov x0, #255
    csel x0, xzr, x0, eq
    mov x1, #0
    unframe

dos_fcb_seq_read:
    mov x1, #0
    mov x2, #0
    b fcb_record_io
dos_fcb_seq_write:
    mov x1, #1
    mov x2, #0
    b fcb_record_io
dos_fcb_random_read:
    mov x1, #0
    mov x2, #1
    b fcb_record_io
dos_fcb_random_write:
    mov x1, #1
    mov x2, #1
fcb_record_io:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x21, x2
    ldrh w22, [x19, #14]
    cbz x22, fcb_record_invalid
    address x0, current_dta_capacity
    ldr x0, [x0]
    cmp x22, x0
    b.hi fcb_record_dta_error
    cbnz x21, 1f
    ldrh w23, [x19, #12]
    ldrb w2, [x19, #32]
    lsl x23, x23, #7
    add x23, x23, x2
    b 2f
1:
    ldr w23, [x19, #33]
2:
    mov x0, x19
    bl fcb_handle
    mov x24, x0
    mul x1, x23, x22
    mov x2, #0
    bl dos_seek
    cbnz x1, fcb_record_invalid
    address x1, current_dta
    ldr x1, [x1]
    mov x0, x24
    mov x2, x22
    cbnz x20, 3f
    bl dos_read
    b 4f
3:
    bl dos_write
4:
    cbnz x1, fcb_record_invalid
    cbz x0, fcb_record_eof
    mov x24, x0
    cmp x24, x22
    b.eq 6f
    cbnz x20, fcb_record_eof
    // DOS partial-record reads zero-pad the unread remainder in the DTA.
    address x0, current_dta
    ldr x0, [x0]
    mov x2, x24
5:
    cmp x2, x22
    b.hs 6f
    strb wzr, [x0, x2]
    add x2, x2, #1
    b 5b
6:
    cbnz x21, 7f              // random record itself remains intact
    add x23, x23, #1
    lsr x2, x23, #7
    strh w2, [x19, #12]
    and x2, x23, #127
    strb w2, [x19, #32]
7:
    lsr x2, x23, #7
    strh w2, [x19, #12]
    and x2, x23, #127
    strb w2, [x19, #32]
    cbz x20, 8f
    mul x2, x23, x22
    cbz x21, 9f
    add x2, x2, x24
9:
    ldr w3, [x19, #16]
    cmp x2, x3
    csel x2, x2, x3, hi
    str w2, [x19, #16]
8:
    cmp x24, x22
    mov x0, #3
    csel x0, xzr, x0, eq
    b fcb_record_return
fcb_record_eof:
    mov x0, #1
    b fcb_record_return
fcb_record_dta_error:
    mov x0, #2
    b fcb_record_return
fcb_record_invalid:
    mov x0, #255
fcb_record_return:
    mov x1, #0
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe
dos_fcb_get_position:
    ldrh w2, [x0, #12]
    ldrb w3, [x0, #32]
    lsl w2, w2, #7
    add w2, w2, w3
    str w2, [x0, #33]
    mov x0, #0
    mov x1, #0
    ret
dos_fcb_get_length:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    bl fcb_filename
    cbnz x1, 2f
    mov x1, #0
    bl dos_open
    cbnz x1, 2f
    mov x20, x0
    mov x1, #0
    mov x2, #2
    bl dos_seek
    cbnz x1, 1f
    ldrh w2, [x19, #14]
    cbz x2, 1f
    sub x2, x2, #1
    add x0, x0, x2
    add x2, x2, #1
    udiv x0, x0, x2
    str w0, [x19, #33]
    mov x0, x20
    bl dos_close
    mov x0, #0
    b 3f
1:
    mov x0, x20
    bl dos_close
2:
    mov x0, #255
3:
    mov x1, #0
    ldp x19, x20, [sp], #16
    unframe
.section .bss
.balign 16
fcb_path: .skip 16
