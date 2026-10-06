// SPDX-License-Identifier: MIT
// DOS 4.0 pathname/handle semantics, with UEFI as the firmware backend.
.section .text

// Translate EFI_STATUS without dropping access/media/resource failures into
// the misleading file-not-found result used by the original scaffold.
efi_error_to_dos:
    and x0, x0, #0x7fffffffffffffff
    cmp x0, #14                 // EFI_NOT_FOUND
    b.eq 1f
    cmp x0, #9                  // EFI_OUT_OF_RESOURCES
    b.eq 2f
    cmp x0, #8                  // EFI_WRITE_PROTECTED
    b.eq 3f
    cmp x0, #12                 // EFI_NO_MEDIA
    b.eq 4f
    cmp x0, #2                  // EFI_INVALID_PARAMETER
    b.eq 5f
    mov x0, #5
    ret
1:  mov x0, #2
    ret
2:  mov x0, #8
    ret
3:  mov x0, #19
    ret
4:  mov x0, #21
    ret
5:  mov x0, #1
    ret

// x0=ASCII path, x1=256-byte destination. Canonical result begins with '\'.
// A: relative paths use this drive's current directory. Other drives fail.
// Dot components are resolved before calling firmware; root cannot escape.
canonicalize_path:
    mov x9, x0
    mov x10, x1
    ldrb w2, [x9]
    cbz w2, canonical_relative
    ldrb w3, [x9, #1]
    cmp w3, #':'
    b.ne canonical_start
    bic w2, w2, #0x20
    cmp w2, #'A'
    b.ne canonical_drive_error
    add x9, x9, #2
canonical_start:
    ldrb w2, [x9]
    cmp w2, #'\\'
    b.eq canonical_absolute
    cmp w2, #'/'
    b.eq canonical_absolute
canonical_relative:
    address x4, current_directory
    mov x7, #0
1:
    ldrb w2, [x4, x7]
    cbz w2, canonical_components
    strb w2, [x10, x7]
    add x7, x7, #1
    b 1b
canonical_absolute:
    mov w2, #'\\'
    strb w2, [x10]
    mov x7, #1
canonical_components:
    ldrb w2, [x9]
    cbz w2, canonical_done
    cmp w2, #'\\'
    b.eq canonical_skip
    cmp w2, #'/'
    b.eq canonical_skip
    mov x4, x9
    mov x5, #0
canonical_scan:
    ldrb w2, [x9]
    cbz w2, canonical_component
    cmp w2, #'\\'
    b.eq canonical_component
    cmp w2, #'/'
    b.eq canonical_component
    cmp w2, #32
    b.lo canonical_bad_path
    cmp w2, #':'
    b.eq canonical_bad_path
    cmp w2, #'"'
    b.eq canonical_bad_path
    cmp w2, #'<'
    b.eq canonical_bad_path
    cmp w2, #'>'
    b.eq canonical_bad_path
    cmp w2, #'|'
    b.eq canonical_bad_path
    add x9, x9, #1
    add x5, x5, #1
    b canonical_scan
canonical_component:
    ldrb w2, [x4]
    cmp w2, #'.'
    b.ne canonical_append
    cmp x5, #1
    b.eq canonical_components
    cmp x5, #2
    b.ne canonical_append
    ldrb w2, [x4, #1]
    cmp w2, #'.'
    b.ne canonical_append
canonical_parent:
    cmp x7, #1
    b.ls canonical_components
    sub x7, x7, #1
    ldrb w2, [x10, x7]
    cmp w2, #'\\'
    b.ne canonical_parent
    cbnz x7, canonical_components
    mov x7, #1
    b canonical_components
canonical_append:
    cmp x7, #1
    b.ls 1f
    mov w2, #'\\'
    strb w2, [x10, x7]
    add x7, x7, #1
1:
    add x6, x7, x5
    cmp x6, #255
    b.hi canonical_bad_path
2:
    ldrb w2, [x4], #1
    strb w2, [x10, x7]
    add x7, x7, #1
    subs x5, x5, #1
    b.ne 2b
    b canonical_components
canonical_skip:
    add x9, x9, #1
    b canonical_components
canonical_done:
    strb wzr, [x10, x7]
    mov x0, x10
    mov x1, #0
    ret
canonical_drive_error:
    mov x0, #15
    mov x1, #1
    ret
canonical_bad_path:
    mov x0, #3
    mov x1, #1
    ret

// GetInfo returns raw EFI status and, on success, x1=EFI_FILE_INFO buffer.
get_file_info:
    frame
    sub sp, sp, #16
    mov x2, #1024
    str x2, [sp]
    mov x2, sp
    address x1, file_info_guid
    address x3, file_info_buffer
    ldr x4, [x0, #64]
    blr x4
    address x1, file_info_buffer
    add sp, sp, #16
    unframe

resize_file:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    bl get_file_info
    cbnz x0, resize_return
    mov x3, x1
    str x20, [x3, #8]
    ldr x2, [x3]
    mov x0, x19
    address x1, file_info_guid
    ldr x4, [x19, #72]
    blr x4
resize_return:
    ldp x19, x20, [sp], #16
    unframe

// 42h: x0=handle, x1=signed byte offset, x2=origin 0/1/2.
dos_seek:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x1
    mov x20, x2
    cmp x20, #2
    b.hi seek_invalid
    bl file_handle
    cbz x0, seek_bad_handle
    mov x21, x0
    cbz x20, seek_absolute
    cmp x20, #2
    b.eq seek_end
    sub sp, sp, #16
    mov x1, sp
    ldr x3, [x21, #48]
    blr x3
    ldr x22, [sp]
    add sp, sp, #16
    cbnz x0, seek_efi_error
    b seek_add
seek_end:
    bl get_file_info
    cbnz x0, seek_efi_error
    ldr x22, [x1, #8]
    b seek_add
seek_absolute:
    mov x22, #0
seek_add:
    adds x1, x22, x19
    tbnz x1, #63, seek_invalid
    mov x19, x1
    mov x0, x21
    ldr x3, [x21, #56]
    blr x3
    cbnz x0, seek_efi_error
    mov x0, x19
    mov x1, #0
    b seek_return
seek_bad_handle:
    mov x0, #6
    b seek_error
seek_invalid:
    mov x0, #1
    b seek_error
seek_efi_error:
    bl efi_error_to_dos
seek_error:
    mov x1, #1
seek_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

dos_commit:
    frame
    bl file_handle
    cbz x0, commit_bad_handle
    ldr x3, [x0, #80]
    blr x3
    cbnz x0, commit_error
    mov x1, #0
    unframe
commit_bad_handle:
    mov x0, #6
    mov x1, #1
    unframe
commit_error:
    bl efi_error_to_dos
    mov x1, #1
    unframe

dos_dup:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
    bl file_handle
    cbz x0, dup_bad_handle
    address x3, handles
    mov x4, #5
1:
    ldr x5, [x3, x4, lsl #3]
    cbz x5, 2f
    add x4, x4, #1
    cmp x4, #32
    b.lo 1b
    mov x0, #4
    mov x1, #1
    b dup_return
2:
    str x0, [x3, x4, lsl #3]
    address x3, handle_modes
    ldrb w5, [x3, x19]
    strb w5, [x3, x4]
    mov x0, x4
    mov x1, #0
    b dup_return
dup_bad_handle:
    mov x0, #6
    mov x1, #1
dup_return:
    ldr x19, [sp], #16
    unframe

dos_dup2:
    frame
    stp x19, x20, [sp, #-16]!
    str x21, [sp, #-16]!
    mov x19, x1
    mov x21, x0
    cmp x19, #5
    b.lo dup2_bad_handle
    cmp x19, #32
    b.hs dup2_bad_handle
    cmp x0, x19
    b.eq dup2_same
    bl file_handle
    cbz x0, dup2_bad_handle
    mov x20, x0
    address x3, handles
    ldr x3, [x3, x19, lsl #3]
    cbz x3, dup2_install
    mov x0, x19
    bl dos_close
    cbnz x1, dup2_return
dup2_install:
    address x3, handles
    str x20, [x3, x19, lsl #3]
    address x3, handle_modes
    ldrb w4, [x3, x21]
    strb w4, [x3, x19]
    mov x0, x19
    mov x1, #0
    b dup2_return
dup2_same:
    bl file_handle
    cbz x0, dup2_bad_handle
    mov x0, x19
    mov x1, #0
    b dup2_return
dup2_bad_handle:
    mov x0, #6
    mov x1, #1
dup2_return:
    ldr x21, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// Open a path as an EFI object directly (not a DOS-visible handle).
// x0=ASCII path, x1=EFI open mode, x2=attributes.
open_path_object:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x1
    mov x20, x2
    bl path_to_utf16
    cbnz x1, object_return
    mov x2, x0
    address x0, root_directory
    ldr x0, [x0]
    cbz x0, object_no_volume
    sub sp, sp, #16
    str xzr, [sp]
    mov x1, sp
    mov x3, x19
    mov x4, x20
    ldr x5, [x0, #8]
    blr x5
    ldr x2, [sp]
    add sp, sp, #16
    cbnz x0, object_error
    mov x0, x2
    mov x1, #0
    b object_return
object_no_volume:
    mov x0, #21
    mov x1, #1
    b object_return
object_error:
    bl efi_error_to_dos
    mov x1, #1
object_return:
    ldp x19, x20, [sp], #16
    unframe

dos_mkdir:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
    mov x1, #1
    mov x2, #0
    bl open_path_object
    cbnz x1, mkdir_create
    ldr x3, [x0, #16]
    blr x3
    mov x0, #5
    mov x1, #1
    b mkdir_return
mkdir_create:
    cmp x0, #2
    b.ne mkdir_return
    mov x0, x19
    mov x1, #0x8000000000000003
    mov x2, #16
    bl open_path_object
    cbnz x1, mkdir_return
    ldr x3, [x0, #16]
    blr x3
    cbnz x0, mkdir_error
    mov x1, #0
    b mkdir_return
mkdir_error:
    bl efi_error_to_dos
    mov x1, #1
mkdir_return:
    ldr x19, [sp], #16
    unframe

dos_chdir:
    frame
    str x19, [sp, #-16]!
    mov x1, #1
    mov x2, #0
    bl open_path_object
    cbnz x1, chdir_return
    mov x19, x0
    bl get_file_info
    cbnz x0, chdir_close_error
    ldr x2, [x1, #72]
    tbz x2, #4, chdir_close_error
    mov x0, x19
    ldr x3, [x0, #16]
    blr x3
    cbnz x0, chdir_error
    address x0, canonical_buffer
    address x1, current_directory
    bl copy_cstring
    mov x0, #0
    mov x1, #0
    b chdir_return
chdir_close_error:
    mov x0, x19
    ldr x3, [x0, #16]
    blr x3
    mov x0, #3
    mov x1, #1
    b chdir_return
chdir_error:
    bl efi_error_to_dos
    mov x1, #1
chdir_return:
    ldr x19, [sp], #16
    unframe

// 47h: x0=buffer, x1=capacity. Return path without drive/leading slash.
dos_getcwd:
    mov x9, x0
    mov x10, x1
    address x2, current_directory
    add x2, x2, #1
    mov x3, #0
1:
    ldrb w4, [x2, x3]
    cmp x3, x10
    b.hs 2f
    strb w4, [x9, x3]
    cbz w4, 3f
    add x3, x3, #1
    b 1b
2:
    mov x0, #8
    mov x1, #1
    ret
3:
    mov x0, x9
    mov x1, #0
    ret

dos_rmdir:
    frame
    stp x19, x20, [sp, #-16]!
    mov x1, #3
    mov x2, #0
    bl open_path_object
    cbnz x1, rmdir_return
    mov x19, x0
    address x0, canonical_buffer
    ldrb w1, [x0, #1]
    cbz w1, rmdir_denied          // root is never removable
    address x1, current_directory
    bl strcmp
    cbz x0, rmdir_denied
    mov x0, x19
    bl get_file_info
    cbnz x0, rmdir_denied
    ldr x2, [x1, #72]
    tbz x2, #4, rmdir_denied
    sub sp, sp, #16
1:
    mov x0, x19
    mov x1, #1024
    str x1, [sp]
    mov x1, sp
    address x2, file_info_buffer
    ldr x3, [x0, #32]
    blr x3
    cbnz x0, rmdir_read_denied
    ldr x0, [sp]
    cbz x0, rmdir_empty
    address x2, file_info_buffer
    ldrh w3, [x2, #80]
    cmp w3, #'.'
    b.ne rmdir_read_denied
    ldrh w3, [x2, #82]
    cbz w3, 1b
    cmp w3, #'.'
    b.ne rmdir_read_denied
    ldrh w3, [x2, #84]
    cbnz w3, rmdir_read_denied
    b 1b
rmdir_read_denied:
    add sp, sp, #16
    b rmdir_denied
rmdir_empty:
    add sp, sp, #16
    mov x0, x19
    ldr x3, [x0, #24]
    blr x3
    cbnz x0, rmdir_delete_error
    mov x1, #0
    b rmdir_return
rmdir_denied:
    mov x0, x19
    ldr x3, [x0, #16]
    blr x3
    mov x0, #5
    mov x1, #1
    b rmdir_return
rmdir_delete_error:
    bl efi_error_to_dos
    mov x1, #1
rmdir_return:
    ldp x19, x20, [sp], #16
    unframe

// 43h: x0=path, x1=0(get)/1(set), x2=DOS attributes.
dos_attributes:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x20, x1
    mov x21, x2
    cmp x20, #1
    b.hi attrs_invalid
    mov x1, #1
    mov x2, #0
    bl open_path_object
    cbnz x1, attrs_return
    mov x19, x0
    bl get_file_info
    cbnz x0, attrs_close_error
    ldr x22, [x1, #72]
    cbnz x20, attrs_set
    mov x0, x19
    ldr x3, [x0, #16]
    blr x3
    and x0, x22, #0x3f
    mov x1, #0
    b attrs_return
attrs_set:
    mov x2, #0x27
    and x2, x21, x2
    cmp x2, x21
    b.ne attrs_close_error
    and x22, x22, #16
    orr x22, x22, x21
    str x22, [x1, #72]
    mov x3, x1
    ldr x2, [x3]
    address x1, file_info_guid
    mov x0, x19
    ldr x4, [x0, #72]
    blr x4
    mov x22, x0
    mov x0, x19
    ldr x3, [x0, #16]
    blr x3
    cbnz x22, attrs_set_error
    mov x0, #0
    mov x1, #0
    b attrs_return
attrs_set_error:
    mov x0, x22
    bl efi_error_to_dos
    mov x1, #1
    b attrs_return
attrs_close_error:
    mov x0, x19
    ldr x3, [x0, #16]
    blr x3
    mov x0, #5
    mov x1, #1
    b attrs_return
attrs_invalid:
    mov x0, #1
    mov x1, #1
attrs_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// 56h: x0=old pathname, x1=new pathname. EFI SetInfo moves the file.
dos_rename:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x20, x1
    mov x1, #3
    mov x2, #0
    bl open_path_object
    cbnz x1, rename_return
    mov x19, x0
    mov x0, x20
    bl path_to_utf16
    cbnz x1, rename_close_error
    mov x21, x0
    mov x0, x19
    bl get_file_info
    cbnz x0, rename_close_error
    add x3, x1, #80
    mov x4, #0
1:
    ldrh w2, [x21, x4]
    strh w2, [x3, x4]
    add x4, x4, #2
    cbnz w2, 1b
    add x2, x4, #80
    str x2, [x1]
    mov x3, x1
    address x1, file_info_guid
    mov x0, x19
    ldr x4, [x0, #72]
    blr x4
    mov x22, x0
    mov x0, x19
    ldr x3, [x0, #16]
    blr x3
    cbnz x22, rename_error
    mov x0, #0
    mov x1, #0
    b rename_return
rename_error:
    mov x0, x22
    bl efi_error_to_dos
    mov x1, #1
    b rename_return
rename_close_error:
    mov x0, x19
    ldr x3, [x0, #16]
    blr x3
    mov x0, #5
    mov x1, #1
rename_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

copy_cstring:
1:
    ldrb w2, [x0], #1
    strb w2, [x1], #1
    cbnz w2, 1b
    ret

.section .data
current_directory: .asciz "\\"
    .space 254
.section .bss
.balign 16
canonical_buffer: .skip 256
