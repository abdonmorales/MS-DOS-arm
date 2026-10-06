// SPDX-License-Identifier: MIT
// Native AArch64 port foundation for v4.0/src/DOS and COMMAND.
// UEFI supplies the platform console and storage; this is an application
// runtime, not yet the complete DOS kernel or an x86 binary emulator.

.macro frame
    stp x29, x30, [sp, #-16]!
    mov x29, sp
.endm
.macro unframe
    ldp x29, x30, [sp], #16
    ret
.endm
.macro address reg, name
    adrp \reg, \name
    add \reg, \reg, :lo12:\name
.endm

.section .text
.global efi_main
efi_main:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    address x2, image_handle
    str x0, [x2]
    address x2, system_table
    str x1, [x2]
    ldr x0, [x1, #96]            // EFI_BOOT_SERVICES
    address x2, boot_services
    str x0, [x2]
    ldr x3, [x0, #256]           // SetWatchdogTimer
    mov x0, #0
    mov x1, #0
    mov x2, #0
    mov x4, x3
    mov x3, #0
    blr x4
    bl filesystem_init
    bl search_init
    address x0, banner
    bl puts
    bl selftest
    cbnz x0, boot_failed
shell_loop:
    bl shell_prompt
    address x0, command_buffer
    mov x1, #255
    bl read_line
    address x19, command_buffer
    mov x0, x19
    bl split_command
    mov x20, x0                 // arguments; first word uppercased
    address x21, commands
1:
    ldrsw x1, [x21]
    cbz x1, unknown_command
    add x1, x21, x1
    mov x0, x19
    bl strcmp
    cbz x0, execute_command
    add x21, x21, #8
    b 1b
execute_command:
    ldrsw x2, [x21, #4]
    add x2, x21, x2
    mov x0, x20
    blr x2
    b shell_loop
unknown_command:
    ldrb w0, [x19]
    cbz w0, shell_loop
    address x0, unknown_message
    bl puts
    b shell_loop
boot_failed:
    address x0, failed_message
    bl puts
    mov x0, #1
    b efi_return
efi_exit:
    mov x0, #0
efi_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// AAPCS64: w8 = DOS function; x0-x3 = arguments. x1=0 on success;
// x1=1 on error, x0=error code. Unimplemented calls fail explicitly.
.global dos_call
dos_call:
    cmp w8, #0x1a
    b.eq dos_set_dta
    cmp w8, #0x2f
    b.eq dos_get_dta
    cmp w8, #0x02
    b.eq dos_console_out
    cmp w8, #0x09
    b.eq dos_print_string
    cmp w8, #0x30
    b.eq dos_get_version
    cmp w8, #0x39
    b.eq dos_mkdir
    cmp w8, #0x3a
    b.eq dos_rmdir
    cmp w8, #0x3b
    b.eq dos_chdir
    cmp w8, #0x3c
    b.eq dos_create
    cmp w8, #0x3d
    b.eq dos_open
    cmp w8, #0x3e
    b.eq dos_close
    cmp w8, #0x3f
    b.eq dos_read
    cmp w8, #0x40
    b.eq dos_write
    cmp w8, #0x41
    b.eq dos_delete
    cmp w8, #0x42
    b.eq dos_seek
    cmp w8, #0x43
    b.eq dos_attributes
    cmp w8, #0x45
    b.eq dos_dup
    cmp w8, #0x46
    b.eq dos_dup2
    cmp w8, #0x47
    b.eq dos_getcwd
    cmp w8, #0x48
    b.eq dos_allocate
    cmp w8, #0x49
    b.eq dos_free
    cmp w8, #0x4e
    b.eq dos_find_first
    cmp w8, #0x4f
    b.eq dos_find_next
    cmp w8, #0x56
    b.eq dos_rename
    cmp w8, #0x68
    b.eq dos_commit
    mov x0, #1                  // invalid function
    mov x1, #1
    ret

// Adapted from GETSET.ASM $GET_VERSION: 4.00 and OEM/user identity.
// Segmented pointers and the compatibility fake-version state are absent.
dos_get_version:
    mov x0, #4
    mov x1, #0
    mov x2, #0                  // user number
    mov x3, #0xff               // Microsoft OEM identifier
    ret

dos_console_out:
    frame
    bl putc
    mov x1, #0
    unframe

// CPMIO.ASM $Std_Con_String_Output, retaining DOS '$' termination.
dos_print_string:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
1:
    ldrb w0, [x19], #1
    cmp w0, #'$'
    b.eq 2f
    cbz w0, 2f
    bl putc
    b 1b
2:
    mov x0, #0x24
    mov x1, #0
    ldr x19, [sp], #16
    unframe

dos_allocate:
    frame
    mov x1, x0                  // bytes, native ABI rather than paragraphs
    mov x0, #2                  // EfiLoaderData
    address x2, pool_result
    address x3, boot_services
    ldr x3, [x3]
    ldr x3, [x3, #64]
    blr x3
    cbnz x0, dos_error_frame
    address x0, pool_result
    ldr x0, [x0]
    mov x1, #0
    unframe
dos_free:
    frame
    address x3, boot_services
    ldr x3, [x3]
    ldr x3, [x3, #72]
    blr x3
    cbnz x0, dos_error_frame
    mov x1, #0
    unframe
dos_error_frame:
    mov x0, #5                  // access/device error
    mov x1, #1
    unframe

// HANDLE.ASM-style native handles. Firmware protocol objects never escape
// through the DOS-facing API. Open mode is 0=read, 1=write, 2=read/write.
dos_open:
    mov x2, #0
    b open_common
dos_create:
    mov x3, #0x27              // read-only, hidden, system, archive
    bic x3, x1, x3
    cbnz x3, create_bad_attributes
    lsl x2, x1, #8
    orr x2, x2, #1
    mov x1, #2
    b open_common
create_bad_attributes:
    mov x0, #1
    mov x1, #1
    ret
open_common:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    cmp x1, #2
    b.hi open_denied
    mov x23, x1
    mov x24, x2
    mov x19, x0
    address x20, handles
    mov x21, #5
1:
    ldr x0, [x20, x21, lsl #3]
    cbz x0, 2f
    add x21, x21, #1
    cmp x21, #32
    b.lo 1b
    mov x0, #4                  // too many open files
    b open_error
2:
    address x0, root_directory
    ldr x22, [x0]
    cbz x22, open_denied
    mov x0, x19
    bl path_to_utf16
    cbnz x1, open_path_error
    mov x2, x0
    mov x0, x22
    add x1, x20, x21, lsl #3
    mov x3, #1                  // EFI_FILE_MODE_READ
    cbz x23, 3f
    mov x3, #3                  // READ | WRITE
3:
    cbz x24, 4f
    orr x3, x3, #0x8000000000000000  // EFI_FILE_MODE_CREATE
4:
    lsr x4, x24, #8
    ldr x5, [x22, #8]
    blr x5
    cbnz x0, open_not_found
    cbz x24, open_success
    // DOS create truncates an existing file to zero bytes, unlike EFI Open.
    ldr x0, [x20, x21, lsl #3]
    bl truncate_file
    cbz x0, open_success
    ldr x0, [x20, x21, lsl #3]
    ldr x3, [x0, #16]
    blr x3
    str xzr, [x20, x21, lsl #3]
    b open_denied
open_success:
    ldr x0, [x20, x21, lsl #3]
    bl get_file_info
    cbnz x0, open_reject_object
    ldr x2, [x1, #72]
    tbnz x2, #4, open_reject_object
    address x3, handle_modes
    strb w23, [x3, x21]
    mov x0, x21
    mov x1, #0
    b open_return
open_reject_object:
    ldr x0, [x20, x21, lsl #3]
    ldr x3, [x0, #16]
    blr x3
    str xzr, [x20, x21, lsl #3]
    b open_denied
open_not_found:
    bl efi_error_to_dos
    b open_error
open_path_error:
    b open_error
open_denied:
    mov x0, #5
open_error:
    mov x1, #1
open_return:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

truncate_file:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
    sub sp, sp, #16
    mov x2, #1024
    str x2, [sp]
    mov x2, sp
    address x1, file_info_guid
    address x3, file_info_buffer
    ldr x4, [x19, #64]
    blr x4
    cbnz x0, truncate_return
    address x3, file_info_buffer
    str xzr, [x3, #8]           // FileSize
    ldr x2, [x3]                // Size of EFI_FILE_INFO
    mov x0, x19
    address x1, file_info_guid
    ldr x4, [x19, #72]
    blr x4
truncate_return:
    add sp, sp, #16
    ldr x19, [sp], #16
    unframe

file_handle:
    cmp x0, #5
    b.lo 1f
    cmp x0, #32
    b.hs 1f
    address x3, handles
    ldr x0, [x3, x0, lsl #3]
    cbz x0, 1f
    ret
1:
    mov x0, #0
    ret
dos_close:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
    bl file_handle
    cbz x0, close_bad_handle
    // Duplicates share the same object and position. Close it only when the
    // final native handle reference is released.
    address x3, handles
    mov x4, #5
1:
    cmp x4, x19
    b.eq 2f
    ldr x5, [x3, x4, lsl #3]
    cmp x5, x0
    b.eq close_release
2:
    add x4, x4, #1
    cmp x4, #32
    b.lo 1b
    ldr x3, [x0, #16]
    blr x3
    cbnz x0, close_bad_handle
close_release:
    address x3, handles
    str xzr, [x3, x19, lsl #3]
    mov x1, #0
    b close_return
close_bad_handle:
    mov x0, #6
    mov x1, #1
close_return:
    ldr x19, [sp], #16
    unframe
dos_read:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x1                 // destination
    mov x20, x2                 // length
    cmp x0, #32
    b.hs read_bad_handle
    address x3, handle_modes
    ldrb w3, [x3, x0]
    cmp w3, #1
    b.eq read_access_error
    bl file_handle
    cbz x0, read_bad_handle
    sub sp, sp, #16
    str x20, [sp]
    mov x1, sp
    mov x2, x19
    ldr x3, [x0, #32]
    blr x3
    ldr x2, [sp]
    add sp, sp, #16
    cbnz x0, read_device_error
    mov x0, x2
    mov x1, #0
    b read_return
read_bad_handle:
    mov x0, #6
    b read_error
read_device_error:
    bl efi_error_to_dos
    b read_error
read_access_error:
    mov x0, #5
read_error:
    mov x1, #1
read_return:
    ldp x19, x20, [sp], #16
    unframe

dos_write:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x1
    mov x20, x2
    cmp x0, #1
    b.eq write_console
    cmp x0, #2
    b.eq write_console
    cmp x0, #32
    b.hs write_bad_handle
    address x3, handle_modes
    ldrb w3, [x3, x0]
    cbz w3, write_access_error
    bl file_handle
    cbz x0, write_bad_handle
    mov x21, x0
    cbz x20, write_truncate
    sub sp, sp, #16
    str x20, [sp]
    mov x1, sp
    mov x2, x19
    ldr x3, [x0, #40]
    blr x3
    ldr x20, [sp]
    add sp, sp, #16
    cbnz x0, write_device_error
    mov x0, x21
    ldr x3, [x0, #80]           // Flush before reporting successful persistence
    blr x3
    cbnz x0, write_device_error
    mov x0, x20
    mov x1, #0
    b write_return
write_console:
    mov x21, #0
1:
    cmp x21, x20
    b.hs 2f
    ldrb w0, [x19, x21]
    bl putc
    add x21, x21, #1
    b 1b
2:
    mov x0, x20
    mov x1, #0
    b write_return
write_bad_handle:
    mov x0, #6
    b write_error
write_truncate:
    sub sp, sp, #16
    mov x1, sp
    ldr x3, [x0, #48]
    blr x3
    ldr x1, [sp]
    add sp, sp, #16
    cbnz x0, write_device_error
    mov x0, x21
    bl resize_file
    cbnz x0, write_device_error
    mov x0, x21
    ldr x3, [x0, #80]
    blr x3
    cbnz x0, write_device_error
    mov x0, #0
    mov x1, #0
    b write_return
write_device_error:
    bl efi_error_to_dos
    b write_error
write_access_error:
    mov x0, #5
write_error:
    mov x1, #1
write_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

dos_delete:
    frame
    str x19, [sp, #-16]!
    mov x1, #2
    bl dos_open
    cbnz x1, delete_return
    mov x19, x0
    bl file_handle
    ldr x3, [x0, #24]           // Delete also closes the EFI handle
    blr x3
    address x3, handles
    str xzr, [x3, x19, lsl #3]
    cbnz x0, delete_error
    mov x1, #0
    b delete_return
delete_error:
    mov x0, #5
    mov x1, #1
delete_return:
    ldr x19, [sp], #16
    unframe

filesystem_init:
    frame
    str x19, [sp, #-16]!
    address x19, boot_services
    ldr x19, [x19]
    address x0, image_handle
    ldr x0, [x0]
    address x1, loaded_image_guid
    address x2, protocol_result
    ldr x3, [x19, #152]          // HandleProtocol
    blr x3
    cbnz x0, fs_return
    address x0, protocol_result
    ldr x0, [x0]
    ldr x0, [x0, #24]           // LoadedImage.DeviceHandle
    address x1, simple_fs_guid
    address x2, protocol_result
    ldr x3, [x19, #152]
    blr x3
    cbnz x0, fs_return
    address x0, protocol_result
    ldr x0, [x0]
    address x1, root_directory
    ldr x3, [x0, #8]            // OpenVolume
    blr x3
fs_return:
    ldr x19, [sp], #16
    unframe

// Firmware console backend. All stacks remain 16-byte aligned (AAPCS64).
putc:
    frame
    sub sp, sp, #16
    strh w0, [sp]
    strh wzr, [sp, #2]
    mov x1, sp
    address x0, system_table
    ldr x0, [x0]
    ldr x0, [x0, #64]
    ldr x2, [x0, #8]            // OutputString
    blr x2
    add sp, sp, #16
    unframe
puts:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
1:
    ldrb w0, [x19], #1
    cbz w0, 2f
    bl putc
    b 1b
2:
    ldr x19, [sp], #16
    unframe
read_key:
    frame
    stp x19, x20, [sp, #-16]!
    sub sp, sp, #32
    address x19, system_table
    ldr x19, [x19]
    ldr x19, [x19, #48]         // ConIn
1:
    mov x0, x19
    mov x1, sp
    ldr x2, [x19, #8]           // ReadKeyStroke
    blr x2
    cbz x0, 2f
    ldr x0, [x19, #16]          // WaitForKey event
    str x0, [sp, #8]
    mov x0, #1
    add x1, sp, #8
    add x2, sp, #16
    address x3, boot_services
    ldr x3, [x3]
    ldr x3, [x3, #96]           // WaitForEvent
    blr x3
    b 1b
2:
    ldrh w0, [sp, #2]           // UnicodeChar; ignore scan-only keys
    cbz w0, 1b
    add sp, sp, #32
    ldp x19, x20, [sp], #16
    unframe
read_line:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x21, #0
1:
    bl read_key
    cmp w0, #13
    b.eq 4f
    cmp w0, #10
    b.eq 4f
    cmp w0, #8
    b.eq 3f
    cmp w0, #127
    b.eq 3f
    cmp w0, #32
    b.lo 1b
    cmp w0, #126
    b.hi 1b
    cmp x21, x20
    b.hs 1b
    strb w0, [x19, x21]
    add x21, x21, #1
    bl putc
    b 1b
3:
    cbz x21, 1b
    sub x21, x21, #1
    address x0, erase_char
    bl puts
    b 1b
4:
    strb wzr, [x19, x21]
    address x0, newline
    bl puts
    mov x0, x21
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

split_command:
1:
    ldrb w1, [x0]
    cbz w1, 4f
    cmp w1, #' '
    b.eq 3f
    cmp w1, #'a'
    b.lo 2f
    cmp w1, #'z'
    b.hi 2f
    sub w1, w1, #32
    strb w1, [x0]
2:
    add x0, x0, #1
    b 1b
3:
    strb wzr, [x0], #1
    ldrb w1, [x0]
    cmp w1, #' '
    b.eq 3b
4:
    ret
strcmp:
1:
    ldrb w2, [x0], #1
    ldrb w3, [x1], #1
    cmp w2, w3
    b.ne 2f
    cbnz w2, 1b
2:
    sub w0, w2, w3
    ret
path_to_utf16:
    frame
    address x1, canonical_buffer
    bl canonicalize_path
    cbnz x1, path_utf16_return
    address x1, path_buffer
    mov x2, x1
    mov x3, #255
1:
    ldrb w4, [x0], #1
    cmp w4, #'/'
    b.ne 2f
    mov w4, #'\\'
2:
    strh w4, [x1], #2
    cbz w4, 3f
    subs x3, x3, #1
    b.ne 1b
    strh wzr, [x1]
3:
    mov x0, x2
    mov x1, #0
path_utf16_return:
    unframe

cmd_help:
    address x0, help_message
    b puts
cmd_ver:
    address x0, version_message
    b puts
cmd_echo:
    frame
    mov x1, x0
    mov x2, #0
1:
    ldrb w3, [x1, x2]
    cbz w3, 2f
    add x2, x2, #1
    b 1b
2:
    mov x0, #1
    mov w8, #0x40
    bl dos_call
    address x0, newline
    bl puts
    unframe
cmd_cls:
    frame
    address x0, system_table
    ldr x0, [x0]
    ldr x0, [x0, #64]
    ldr x1, [x0, #48]           // ClearScreen
    blr x1
    unframe
cmd_exit:
    // Drop execute_command's return address; main owns the original frame.
    b efi_exit
cmd_type:
    frame
    str x19, [sp, #-16]!
    bl next_word
    mov x1, #0
    mov w8, #0x3d
    bl dos_call
    cbnz x1, type_error
    mov x19, x0
1:
    mov x0, x19
    address x1, io_buffer
    mov x2, #512
    mov w8, #0x3f
    bl dos_call
    cbnz x1, type_read_error
    cbz x0, type_close
    mov x2, x0
    address x1, io_buffer
    mov x0, #1
    bl dos_write
    b 1b
type_read_error:
    address x0, file_error
    bl puts
type_close:
    mov x0, x19
    mov w8, #0x3e
    bl dos_call
    address x0, newline
    bl puts
    b type_return
type_error:
    address x0, file_error
    bl puts
type_return:
    ldr x19, [sp], #16
    unframe
cmd_selftest:
    b selftest
cmd_del:
    frame
    bl next_word
    mov w8, #0x41
    bl dos_call
    cbz x1, 1f
    address x0, file_error
    bl puts
1:
    unframe
// Actual API/read checks, not just reaching a prompt.
selftest:
    frame
    stp x19, x20, [sp, #-16]!
    bl api_selftest
    cbnz x0, selftest_failed
    mov w8, #0x30
    bl dos_call
    cbnz x1, selftest_failed
    cmp x0, #4
    b.ne selftest_failed
    address x0, dos_string_message
    mov w8, #0x09
    bl dos_call
    cbnz x1, selftest_failed
    cmp x0, #0x24
    b.ne selftest_failed
    mov w8, #0xff
    bl dos_call
    cmp x1, #1
    b.ne selftest_failed
    mov x0, #64
    mov w8, #0x48
    bl dos_call
    cbnz x1, selftest_failed
    cbz x0, selftest_failed
    mov w8, #0x49
    bl dos_call
    cbnz x1, selftest_failed
    address x0, test_filename
    mov x1, #0
    mov w8, #0x3d
    bl dos_call
    cbnz x1, selftest_failed
    mov x19, x0
    address x1, io_buffer
    mov x2, #64
    mov w8, #0x3f
    bl dos_call
    cbnz x1, selftest_close_fail
    cmp x0, #16
    b.ne selftest_close_fail
    address x0, io_buffer
    address x1, test_contents
    mov x20, #16
1:
    ldrb w2, [x0], #1
    ldrb w3, [x1], #1
    cmp w2, w3
    b.ne selftest_close_fail
    subs x20, x20, #1
    b.ne 1b
    mov x0, x19
    mov w8, #0x3e
    bl dos_call
    cbnz x1, selftest_failed
    // Use a dedicated scratch name. This self-test changes only that file.
    address x0, write_filename
    mov x1, #0
    mov w8, #0x3d
    bl dos_call
    cbnz x1, selftest_create
    mov w8, #0x3e
    bl dos_call
    b selftest_failed            // Preserve an existing reserved scratch file.
selftest_create:
    cmp x0, #2
    b.ne selftest_failed
    address x0, write_filename
    mov x1, #0
    mov w8, #0x3c
    bl dos_call
    cbnz x1, selftest_failed
    mov x19, x0
    address x1, test_contents
    mov x2, #16
    mov w8, #0x40
    bl dos_call
    cbnz x1, selftest_close_fail
    cmp x0, #16
    b.ne selftest_close_fail
    mov x0, x19
    mov w8, #0x3e
    bl dos_call
    cbnz x1, selftest_failed
    address x0, write_filename
    mov x1, #0
    mov w8, #0x3d
    bl dos_call
    cbnz x1, selftest_failed
    mov x19, x0
    address x1, io_buffer
    mov x2, #64
    mov w8, #0x3f
    bl dos_call
    cbnz x1, selftest_close_fail
    cmp x0, #16
    b.ne selftest_close_fail
    address x0, io_buffer
    address x1, test_contents
    mov x20, #16
2:
    ldrb w2, [x0], #1
    ldrb w3, [x1], #1
    cmp w2, w3
    b.ne selftest_close_fail
    subs x20, x20, #1
    b.ne 2b
    mov x0, x19
    mov w8, #0x3e
    bl dos_call
    cbnz x1, selftest_failed
    address x0, write_filename
    mov w8, #0x41
    bl dos_call
    cbnz x1, selftest_failed
    address x0, write_filename
    mov x1, #0
    mov w8, #0x3d
    bl dos_call
    cmp x1, #1
    b.ne selftest_failed
    address x0, passed_message
    bl puts
    mov x0, #0
    b selftest_return
selftest_close_fail:
    mov x0, x19
    mov w8, #0x3e
    bl dos_call
selftest_failed:
    address x0, failed_message
    bl puts
    mov x0, #1
selftest_return:
    ldp x19, x20, [sp], #16
    unframe

.section .rodata
.balign 8
loaded_image_guid:
    .long 0x5b1b31a1
    .short 0x9562, 0x11d2
    .byte 0x8e,0x3f,0x00,0xa0,0xc9,0x69,0x72,0x3b
simple_fs_guid:
    .long 0x964e5b22
    .short 0x6459, 0x11d2
    .byte 0x8e,0x39,0x00,0xa0,0xc9,0x69,0x72,0x3b
file_info_guid:
    .long 0x09576e92
    .short 0x6d3f, 0x11d2
    .byte 0x8e,0x39,0x00,0xa0,0xc9,0x69,0x72,0x3b
commands:
    .long name_help - ., cmd_help - (. - 4)
    .long name_ver - ., cmd_ver - (. - 4)
    .long name_echo - ., cmd_echo - (. - 4)
    .long name_cls - ., cmd_cls - (. - 4)
    .long name_type - ., cmd_type - (. - 4)
    .long name_dir - ., cmd_dir - (. - 4)
    .long name_del - ., cmd_del - (. - 4)
    .long name_cd - ., cmd_cd - (. - 4)
    .long name_chdir - ., cmd_cd - (. - 4)
    .long name_md - ., cmd_md - (. - 4)
    .long name_mkdir - ., cmd_md - (. - 4)
    .long name_rd - ., cmd_rd - (. - 4)
    .long name_rmdir - ., cmd_rd - (. - 4)
    .long name_copy - ., cmd_copy - (. - 4)
    .long name_ren - ., cmd_ren - (. - 4)
    .long name_rename - ., cmd_ren - (. - 4)
    .long name_attrib - ., cmd_attrib - (. - 4)
    .long name_selftest - ., cmd_selftest - (. - 4)
    .long name_exit - ., cmd_exit - (. - 4)
    .long 0, 0
name_help: .asciz "HELP"
name_ver: .asciz "VER"
name_echo: .asciz "ECHO"
name_cls: .asciz "CLS"
name_type: .asciz "TYPE"
name_dir: .asciz "DIR"
name_del: .asciz "DEL"
name_cd: .asciz "CD"
name_chdir: .asciz "CHDIR"
name_md: .asciz "MD"
name_mkdir: .asciz "MKDIR"
name_rd: .asciz "RD"
name_rmdir: .asciz "RMDIR"
name_copy: .asciz "COPY"
name_ren: .asciz "REN"
name_rename: .asciz "RENAME"
name_attrib: .asciz "ATTRIB"
name_selftest: .asciz "SELFTEST"
name_exit: .asciz "EXIT"
banner: .asciz "\r\nMS-DOS 4.0 AArch64 port development runtime\r\nNative ARM64 assembly / UEFI platform backend\r\nPartial port: x86 applications and the full DOS kernel are not implemented.\r\n"
prompt: .asciz "A:\\> "
newline: .asciz "\r\n"
erase_char: .asciz "\b \b"
unknown_message: .asciz "Bad command or unsupported port feature.\r\n"
help_message: .asciz "HELP VER ECHO CLS DIR TYPE DEL CD MD RD COPY REN ATTRIB SELFTEST EXIT\r\nA: is the boot volume. Quote paths containing spaces.\r\n"
version_message: .asciz "MS-DOS API baseline 4.00; AArch64 development port (partial).\r\n"
passed_message: .asciz "SELFTEST PASS: version, errors, allocation, FAT read/write/delete.\r\n"
failed_message: .asciz "SELFTEST FAIL\r\n"
file_error: .asciz "File/device error.\r\n"
test_filename: .asciz "\\ARMTEST.TXT"
write_filename: .asciz "\\ARMCHK.TMP"
test_contents: .ascii "ARM64 FAT read\r\n"
dos_string_message: .asciz "DOS string service OK\r\n$"

.section .bss
.balign 16
image_handle: .skip 8
system_table: .skip 8
boot_services: .skip 8
root_directory: .skip 8
protocol_result: .skip 8
pool_result: .skip 8
handles: .skip 256
handle_modes: .skip 32
command_buffer: .skip 256
path_buffer: .skip 512
io_buffer: .skip 528
file_info_buffer: .skip 1024

.include "src/files.S"
.include "src/api_test.S"
.include "src/search.S"

.include "src/shell.S"
