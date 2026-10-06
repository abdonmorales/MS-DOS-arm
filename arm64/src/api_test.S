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
api_fail_message: .asciz "API SELFTEST FAIL: "
api_stage_paths: .asciz "paths and directory creation"
api_stage_handles: .asciz "seek, shared duplicate handles, truncate"
api_stage_metadata: .asciz "rename, file size, modes, attributes"
api_stage_cleanup: .asciz "directory enumeration and cleanup"
api_stage_search: .asciz "wildcards, hidden files and independent DTAs"
.section .bss
.balign 8
api_test_stage: .skip 8
api_second_dta: .skip 280
