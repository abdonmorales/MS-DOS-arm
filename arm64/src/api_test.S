// SPDX-License-Identifier: MIT
// Integration checks executed inside the AArch64 runtime, against real FAT.
// A reserved directory is created only after verifying it does not exist.
.macro check_ok
    cbnz x1, api_test_failed
.endm
.macro test_step name
    address x9, api_test_stage
    address x10, \name
    str x10, [x9]
.endm
.section .text
api_selftest:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    test_step api_stage_disk_info
    mov x0, #0
    bl dos_free_space
    check_ok
    cbz x0, api_test_failed
    cmp x2, x3
    b.hi api_test_failed
    bl dos_get_drive
    check_ok
    cbnz x0, api_test_failed
    mov x0, #0
    bl dos_set_drive
    check_ok
    cmp x0, #1
    b.ne api_test_failed
    mov x0, #1
    bl dos_set_drive
    cmp x1, #1
    b.ne api_test_failed
    cmp x0, #15
    b.ne api_test_failed
    test_step api_stage_clock
    bl clock_selftest
    cbnz x0, api_test_failed
    test_step api_stage_fcb
    bl fcb_selftest
    cbnz x0, api_test_failed
    test_step api_stage_memory
    mov x0, #32
    bl dos_allocate
    check_ok
    mov x19, x0
    mov x2, #0x1234
    str x2, [x19]
    mov x1, #128
    bl dos_resize
    check_ok
    cmp x0, x19
    b.ne api_test_failed
    ldr x2, [x19]
    mov x3, #0x1234
    cmp x2, x3
    b.ne api_test_failed
    mov x0, x19
    mov x1, #65536
    add x1, x1, #1
    bl dos_resize
    cmp x1, #1
    b.ne api_test_failed
    cmp x0, #8
    b.ne api_test_failed
    cmp x2, #65536
    b.ne api_test_failed
    add x0, x19, #1
    bl dos_free
    cmp x1, #1
    b.ne api_test_failed
    cmp x0, #9
    b.ne api_test_failed
    mov x0, x19
    bl dos_free
    check_ok
    mov x0, x19
    bl dos_free
    cmp x1, #1
    b.ne api_test_failed
    cmp x0, #9
    b.ne api_test_failed
    test_step api_stage_process
    address x0, test_filename
    mov x1, #0
    bl dos_open
    check_ok
    mov x19, x0
    address x0, api_program
    address x1, api_nested_argument
    bl dos_exec
    check_ok
    bl dos_get_exit_code
    check_ok
    cbnz x0, api_test_failed
    mov x0, x19
    address x1, io_buffer
    mov x2, #16
    bl dos_read
    check_ok
    cmp x0, #16
    b.ne api_test_failed
    mov x0, x19
    bl dos_close
    check_ok
    address x0, api_program
    address x1, api_exit_argument
    bl dos_exec
    check_ok
    bl dos_get_exit_code
    check_ok
    cmp x0, #7
    b.ne api_test_failed
    bl dos_get_exit_code
    check_ok
    cbnz x0, api_test_failed
    address x0, test_filename
    address x1, api_exit_argument
    bl dos_exec
    cmp x1, #1
    b.ne api_test_failed
    cmp x0, #11
    b.ne api_test_failed
    test_step api_stage_paths
    address x0, api_directory
    mov x1, #1
    mov x2, #0
    bl open_path_object
    cbnz x1, 1f
    ldr x3, [x0, #16]
    blr x3
    b api_test_failed
1:
    cmp x0, #2
    b.ne api_test_failed
    address x0, api_directory
    mov w8, #0x39
    bl dos_call
    check_ok
    address x0, api_directory
    mov w8, #0x39
    bl dos_call
    cmp x1, #1
    b.ne api_test_failed
    cmp x0, #5
    b.ne api_test_failed
    address x0, api_directory
    mov w8, #0x3b
    bl dos_call
    check_ok
    address x0, io_buffer
    mov x1, #256
    mov w8, #0x47
    bl dos_call
    check_ok
    address x0, io_buffer
    address x1, api_directory_name
    bl strcmp
    cbnz x0, api_test_failed

    test_step api_stage_handles
    address x0, api_filename
    mov x1, #0
    mov w8, #0x3c
    bl dos_call
    check_ok
    mov x19, x0
    address x1, api_data
    mov x2, #6
    mov w8, #0x40
    bl dos_call
    check_ok
    cmp x0, #6
    b.ne api_test_failed
    address x0, api_filename
    mov x1, #0
    bl dos_create_new
    cmp x1, #1
    b.ne api_test_failed
    cmp x0, #80
    b.ne api_test_failed
    mov x0, x19
    mov w8, #0x45
    bl dos_call
    check_ok
    mov x20, x0
    mov x1, #2
    mov x2, #0
    mov w8, #0x42
    bl dos_call
    check_ok
    cmp x0, #2
    b.ne api_test_failed
    mov x0, x19
    address x1, io_buffer
    mov x2, #2
    mov w8, #0x3f
    bl dos_call
    check_ok
    cmp x0, #2
    b.ne api_test_failed
    address x2, io_buffer
    ldrh w2, [x2]
    mov w3, #0x6463             // shared offset: bytes "cd"
    cmp w2, w3
    b.ne api_test_failed
    mov x0, x20
    mov x1, #31
    mov w8, #0x46
    bl dos_call
    check_ok
    mov x0, x19
    mov w8, #0x3e
    bl dos_call
    check_ok
    mov x0, x20
    mov x1, #-1
    mov x2, #2
    mov w8, #0x42
    bl dos_call
    check_ok
    cmp x0, #5
    b.ne api_test_failed
    mov x0, #31
    address x1, io_buffer
    mov x2, #1
    mov w8, #0x3f
    bl dos_call
    check_ok
    cmp x0, #1
    b.ne api_test_failed
    address x2, io_buffer
    ldrb w2, [x2]
    cmp w2, #'f'
    b.ne api_test_failed
    mov x0, #31
    mov w8, #0x3e
    bl dos_call
    check_ok
    mov x0, x20
    mov x1, #3
    mov x2, #0
    mov w8, #0x42
    bl dos_call
    check_ok
    mov x0, x20
    address x1, io_buffer
    mov x2, #0
    mov w8, #0x40
    bl dos_call
    check_ok
    mov x0, x20
    mov w8, #0x68
    bl dos_call
    check_ok
    test_step api_stage_file_time
    mov x0, x20
    mov x1, #1
    mov x2, #0x585d             // 2024-02-29
    mov x3, #0x645c             // 12:34:56
    bl dos_file_time
    check_ok
    mov x0, x20
    mov x1, #0
    bl dos_file_time
    check_ok
    mov x4, #0x585d
    cmp x2, x4
    b.ne api_test_failed
    mov x4, #0x645c
    cmp x3, x4
    b.ne api_test_failed
    mov x0, x20
    mov x1, #0
    bl dos_ioctl
    check_ok
    cbnz x0, api_test_failed
    mov x0, x20
    mov x1, #6
    bl dos_ioctl
    check_ok
    cbnz x0, api_test_failed     // position 3 at EOF of truncated 3-byte file
    bl dos_disk_reset
    check_ok
    mov x0, x20
    mov w8, #0x3e
    bl dos_call
    check_ok

    test_step api_stage_metadata
    address x0, api_filename
    address x1, api_renamed
    mov w8, #0x56
    bl dos_call
    check_ok
    address x0, api_filename
    mov x1, #0
    mov w8, #0x3d
    bl dos_call
    cmp x1, #1
    b.ne api_test_failed
    cmp x0, #2
    b.ne api_test_failed
    address x0, api_renamed
    mov x1, #0
    mov w8, #0x3d
    bl dos_call
    check_ok
    mov x19, x0
    mov x1, #0
    mov x2, #2
    mov w8, #0x42
    bl dos_call
    check_ok
    cmp x0, #3
    b.ne api_test_failed
    mov x0, x19
    address x1, api_data
    mov x2, #1
    mov w8, #0x40
    bl dos_call
    cmp x1, #1
    b.ne api_test_failed
    cmp x0, #5
    b.ne api_test_failed
    mov x0, x19
    mov x1, #-1
    mov x2, #0
    mov w8, #0x42
    bl dos_call
    cmp x1, #1
    b.ne api_test_failed
    mov x0, x19
    mov w8, #0x3e
    bl dos_call
    check_ok
    address x0, api_renamed
    mov x1, #1
    mov x2, #3                  // read-only + hidden
    mov w8, #0x43
    bl dos_call
    check_ok
    address x0, api_renamed
    mov x1, #0
    mov w8, #0x43
    bl dos_call
    check_ok
    and x0, x0, #3
    cmp x0, #3
    b.ne api_test_failed
    test_step api_stage_search
    address x0, api_pattern
    mov x1, #0
    bl dos_find_first
    cmp x1, #1
    b.ne api_test_failed
    cmp x0, #18
    b.ne api_test_failed
    address x0, api_pattern
    mov x1, #2
    bl dos_find_first
    check_ok
    bl dos_get_dta
    mov x21, x0
    ldr x2, [x0, #8]
    cmp x2, #3
    b.ne api_test_failed
    add x0, x0, #24
    address x1, api_renamed
    bl strcasecmp
    cbnz x0, api_test_failed
    address x0, api_second_dta
    mov x1, #280
    bl dos_set_dta
    check_ok
    address x0, test_filename
    mov x1, #0
    bl dos_find_first
    check_ok
    bl dos_find_next
    cmp x1, #1
    b.ne api_test_failed
    cmp x0, #18
    b.ne api_test_failed
    mov x0, x21
    mov x1, #280
    bl dos_set_dta
    check_ok
    bl dos_find_next
    cmp x1, #1
    b.ne api_test_failed
    cmp x0, #18
    b.ne api_test_failed
    test_step api_stage_metadata
    address x0, api_renamed
    mov x1, #2
    mov w8, #0x3d
    bl dos_call
    cmp x1, #1
    b.ne api_test_failed
    address x0, api_renamed
    mov x1, #1
    mov x2, #0x20
    mov w8, #0x43
    bl dos_call
    check_ok

    test_step api_stage_cleanup
    address x0, api_parent
    mov w8, #0x3b
    bl dos_call
    check_ok
    address x0, api_directory
    mov w8, #0x3a
    bl dos_call
    cmp x1, #1
    b.ne api_test_failed
    cmp x0, #5
    b.ne api_test_failed
    address x0, api_full_renamed
    mov w8, #0x41
    bl dos_call
    check_ok
    address x0, api_directory
    mov w8, #0x3a
    bl dos_call
    check_ok
    address x0, api_wrong_drive
    mov x1, #0
    mov w8, #0x3d
    bl dos_call
    cmp x1, #1
    b.ne api_test_failed
    cmp x0, #15
    b.ne api_test_failed
    mov x0, #0
    b api_test_return
api_test_failed:
    address x0, api_fail_message
    bl puts
    address x0, api_test_stage
    ldr x0, [x0]
    bl puts
    address x0, newline
    bl puts
    mov x0, #1
api_test_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe
.section .rodata
api_directory: .asciz "\\ARMAPI.TMP"
api_directory_name: .asciz "ARMAPI.TMP"
api_filename: .asciz ".\\TEST.TXT"
api_renamed: .asciz "MOVED.TXT"
api_full_renamed: .asciz "\\ARMAPI.TMP\\MOVED.TXT"
api_parent: .asciz "A:..\\."
api_wrong_drive: .asciz "B:\\ARMTEST.TXT"
api_data: .ascii "abcdef"
api_pattern: .asciz "mO?ED.*"
api_program: .asciz "\\NATIVE.EXE"
api_nested_argument: .asciz "nested"
api_exit_argument: .asciz "exit7"
api_fail_message: .asciz "API SELFTEST FAIL: "
api_stage_paths: .asciz "paths and directory creation"
api_stage_memory: .asciz "arena ownership, in-place resize and invalid free"
api_stage_process: .asciz "native loading, nested exec, exit code, parent handles"
api_stage_clock: .asciz "leap years, invalid dates and clock rollover"
api_stage_fcb: .asciz "FCB sequential/random records, EOF padding and writes"
api_stage_disk_info: .asciz "firmware free space and drive selection"
api_stage_file_time: .asciz "file timestamps, IOCTL and flushing"
api_stage_handles: .asciz "seek, shared duplicate handles, truncate"
api_stage_metadata: .asciz "rename, file size, modes, attributes"
api_stage_cleanup: .asciz "directory enumeration and cleanup"
api_stage_search: .asciz "wildcards, hidden files and independent DTAs"
.section .bss
.balign 8
api_test_stage: .skip 8
api_second_dta: .skip 280

.section .text
clock_selftest:
    frame
    stp x19, x20, [sp, #-16]!
    sub sp, sp, #32
    address x19, clock_epoch
    ldp x0, x1, [x19]
    stp x0, x1, [sp]
    ldr x0, [x19, #16]
    str x0, [sp, #16]
    mov x20, #1
    mov x0, #2024
    mov x1, #2
    mov x2, #29
    bl dos_set_date
    cbnz x1, clock_test_return
    bl dos_get_date
    cmp x0, #2024
    b.ne clock_test_return
    cmp x2, #2
    b.ne clock_test_return
    cmp x3, #29
    b.ne clock_test_return
    cmp x4, #4                 // Thursday
    b.ne clock_test_return
    mov x0, #2100
    mov x1, #2
    mov x2, #29
    bl dos_set_date
    cmp x1, #1
    b.ne clock_test_return
    mov x0, #2000
    mov x1, #2
    mov x2, #29
    bl dos_set_date
    cbnz x1, clock_test_return
    mov x0, #2024
    mov x1, #12
    mov x2, #31
    bl dos_set_date
    cbnz x1, clock_test_return
    mov x0, #23
    mov x1, #59
    mov x2, #59
    mov x3, #0
    bl dos_set_time
    cbnz x1, clock_test_return
    // Advance the runtime anchor by one second without changing host time.
    ldr x0, [x19, #16]
    mrs x1, cntfrq_el0
    sub x0, x0, x1
    str x0, [x19, #16]
    bl dos_get_date
    cmp x0, #2025
    b.ne clock_test_return
    cmp x2, #1
    b.ne clock_test_return
    cmp x3, #1
    b.ne clock_test_return
    cmp x4, #3                 // Wednesday
    b.ne clock_test_return
    bl dos_get_time
    cbnz x0, clock_test_return
    cbnz x2, clock_test_return
    cmp x3, #2
    b.hi clock_test_return
    mov x0, #24
    mov x1, #0
    mov x2, #0
    mov x3, #0
    bl dos_set_time
    cmp x1, #1
    b.ne clock_test_return
    mov x20, #0
clock_test_return:
    ldp x0, x1, [sp]
    stp x0, x1, [x19]
    ldr x0, [sp, #16]
    str x0, [x19, #16]
    mov x0, x20
    add sp, sp, #32
    ldp x19, x20, [sp], #16
    unframe

fcb_selftest:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x22, #1
    bl dos_get_dta
    mov x20, x0
    mov x21, x2
    address x19, api_read_fcb
    mov x0, x19
    mov x22, #1
    bl dos_fcb_open
    cbnz x0, fcb_test_return
    ldr w2, [x19, #16]
    cmp w2, #16
    b.ne fcb_test_close
    mov w2, #10
    strh w2, [x19, #14]
    mov x0, x19
    mov x22, #2
    bl dos_fcb_seq_read
    cbnz x0, fcb_test_close
    mov x0, x20
    address x1, api_fcb_first_record
    mov x2, #10
    bl compare_bytes
    cbnz x0, fcb_test_close
    mov x0, x19
    mov x22, #3
    bl dos_fcb_seq_read
    cmp x0, #3
    b.ne fcb_test_close
    mov x0, x20
    address x1, api_fcb_second_record
    mov x2, #10
    bl compare_bytes
    cbnz x0, fcb_test_close
    mov x0, x19
    mov x22, #4
    bl dos_fcb_seq_read
    cmp x0, #1
    b.ne fcb_test_close
    mov x0, x19
    mov x22, #5
    bl dos_fcb_get_position
    ldr w2, [x19, #33]
    cmp w2, #2
    b.ne fcb_test_close
    str wzr, [x19, #33]
    mov x0, x19
    mov x22, #6
    bl dos_fcb_random_read
    cbnz x0, fcb_test_close
    ldrb w2, [x19, #32]
    cbnz w2, fcb_test_close
    mov x0, x20
    address x1, api_fcb_first_record
    mov x2, #10
    bl compare_bytes
    cbnz x0, fcb_test_close
    mov w2, #300
    strh w2, [x19, #14]
    mov x0, x19
    mov x22, #7
    bl dos_fcb_seq_read
    cmp x0, #2
    b.ne fcb_test_close
    mov x0, x19
    mov x22, #8
    bl dos_fcb_close
    cbnz x0, fcb_test_return
    mov x0, x19
    mov x22, #9
    bl dos_fcb_close
    cmp x0, #255
    b.ne fcb_test_return
    mov w2, #10
    strh w2, [x19, #14]
    mov x0, x19
    mov x22, #10
    bl dos_fcb_get_length
    cbnz x0, fcb_test_return
    ldr w2, [x19, #33]
    cmp w2, #2
    b.ne fcb_test_return
    address x0, api_fcb_write_path
    mov x1, #0
    bl dos_open
    cbnz x1, 1f
    bl dos_close
    b fcb_test_return
1:
    cmp x0, #2
    b.ne fcb_test_return
    address x19, api_write_fcb
    mov x0, x19
    mov x22, #11
    bl dos_fcb_create
    cbnz x0, fcb_test_return
    mov w2, #16
    strh w2, [x19, #14]
    address x0, test_contents
    mov x1, x20
    mov x2, #16
    bl copy_bytes
    mov x0, x19
    mov x22, #12
    bl dos_fcb_seq_write
    cbnz x0, fcb_test_close
    ldr w2, [x19, #16]
    cmp w2, #16
    b.ne fcb_test_close
    mov x0, x19
    mov x22, #13
    bl dos_fcb_close
    cbnz x0, fcb_test_return
    mov x0, x19
    mov x22, #14
    bl dos_fcb_get_length
    cbnz x0, fcb_test_return
    ldr w2, [x19, #33]
    cmp w2, #1
    b.ne fcb_test_return
    mov x0, x19
    mov x22, #15
    bl dos_fcb_delete
    cbnz x0, fcb_test_return
    mov x22, #0
    b fcb_test_return
fcb_test_close:
    mov x0, x19
    bl dos_fcb_close
fcb_test_return:
    cbz x22, 1f
    mov x0, x22
    mov x1, #2
    bl print_padded_number
    address x0, newline
    bl puts
1:
    mov x0, x20
    mov x1, x21
    bl dos_set_dta
    mov x0, x22
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe
compare_bytes:
1:
    ldrb w3, [x0], #1
    ldrb w4, [x1], #1
    cmp w3, w4
    b.ne 2f
    subs x2, x2, #1
    b.ne 1b
    mov x0, #0
    ret
2:
    mov x0, #1
    ret
.section .rodata
api_fcb_first_record: .ascii "ARM64 FAT "
api_fcb_second_record: .ascii "read\r\n"
    .zero 4
api_fcb_write_path: .asciz "\\ARMFCB.TMP"
.section .data
api_read_fcb:
    .byte 0
    .ascii "ARMTEST TXT"
    .zero 25
api_write_fcb:
    .byte 0
    .ascii "ARMFCB  TMP"
    .zero 25
