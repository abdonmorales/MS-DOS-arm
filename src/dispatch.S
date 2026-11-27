// SPDX-License-Identifier: MIT
// DOS function dispatcher (DISPATCH.ASM / MS_TABLE.ASM) and the small
// system-state services: extended error, break, verify, switch character,
// vectors, InDOS, PSP selection, allocation strategy, code page and DBCS.
//
// AAPCS64: w8 = function, x0-x5 = arguments. x1=0 success; x1=1 error with
// the DOS error code in x0. Every failing call is recorded for 59h.
.equ DOS_MAX_FUNCTION, 0x6c
.equ ARMDOS_DISK_FUNCTION, 0xe0  // ARM DOS extension: table slot 6Dh
.equ SDA_CRITICAL, 0
.equ SDA_INDOS, 1
.equ SDA_EXPLICIT, 2
.equ SDA_CLASS, 3
.equ SDA_ACTION, 4
.equ SDA_LOCUS, 5
.equ SDA_ERROR, 8
.equ SDA_SIZE, 16
.section .text
.global dos_call
dos_call:
    cmp w8, #DOS_MAX_FUNCTION
    b.hi dos_call_extension
dos_call_dispatch:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, dos_break_flag
    ldr x9, [x9, :lo12:dos_break_flag]
    cbz x9, 1f
    adrp x9, process_frames
    ldr x9, [x9, :lo12:process_frames]
    cbz x9, 1f
    // BREAK ON: every call made by a program checks for a pending Ctrl-C.
    stp x0, x1, [sp, #-64]!
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x8, [sp, #48]
    bl ctrl_c_poll
    ldp x6, x8, [sp, #48]
    ldp x4, x5, [sp, #32]
    ldp x2, x3, [sp, #16]
    ldp x0, x1, [sp], #64
1:
    adr x9, dos_table
    ldrsw x10, [x9, w8, uxtw #2]
    add x10, x9, x10
    blr x10
    cmp x1, #1
    b.ne 2f
    adrp x9, dos_sda
    add x9, x9, :lo12:dos_sda
    str x0, [x9, #SDA_ERROR]
    strb wzr, [x9, #SDA_EXPLICIT]
2:
    ldp x29, x30, [sp], #16
    ret
dos_call_extension:
    cmp w8, #ARMDOS_DISK_FUNCTION
    b.ne dos_call_invalid
    mov w8, #(DOS_MAX_FUNCTION + 1)
    b dos_call_dispatch
dos_call_invalid:
    mov x0, #1
    adrp x9, dos_sda
    add x9, x9, :lo12:dos_sda
    str x0, [x9, #SDA_ERROR]
    strb wzr, [x9, #SDA_EXPLICIT]
    mov x1, #1
    ret

.macro dosfn target
    .word \target - dos_table
.endm
.balign 4
dos_table:
    dosfn dos_terminate_zero        // 00
    dosfn dos_console_input         // 01
    dosfn dos_console_out           // 02
    dosfn dos_aux_input             // 03
    dosfn dos_aux_output            // 04
    dosfn dos_printer_output        // 05
    dosfn dos_console_direct        // 06
    dosfn dos_console_noecho        // 07
    dosfn dos_console_noecho        // 08
    dosfn dos_print_string          // 09
    dosfn dos_console_buffer        // 0A
    dosfn dos_console_status        // 0B
    dosfn dos_console_flush         // 0C
    dosfn dos_disk_reset            // 0D
    dosfn dos_set_drive             // 0E
    dosfn fcbx_open                 // 0F
    dosfn fcbx_close                // 10
    dosfn dos_fcb_find_first        // 11
    dosfn dos_fcb_find_next         // 12
    dosfn dos_fcb_delete_wild       // 13
    dosfn fcbx_seq_read             // 14
    dosfn fcbx_seq_write            // 15
    dosfn fcbx_create               // 16
    dosfn dos_fcb_rename            // 17
    dosfn dos_null_function         // 18
    dosfn dos_get_drive             // 19
    dosfn dos_set_dta               // 1A
    dosfn dos_alloc_info_default    // 1B
    dosfn dos_alloc_info            // 1C
    dosfn dos_null_function         // 1D
    dosfn dos_null_function         // 1E
    dosfn dos_get_dpb_default       // 1F
    dosfn dos_null_function         // 20
    dosfn fcbx_random_read          // 21
    dosfn fcbx_random_write         // 22
    dosfn fcbx_get_length           // 23
    dosfn fcbx_get_position         // 24
    dosfn dos_set_vector            // 25
    dosfn dos_create_psp            // 26
    dosfn fcbx_block_read           // 27
    dosfn fcbx_block_write          // 28
    dosfn dos_parse_filename        // 29
    dosfn dos_get_date              // 2A
    dosfn dos_set_date              // 2B
    dosfn dos_get_time              // 2C
    dosfn dos_set_time              // 2D
    dosfn dos_set_verify            // 2E
    dosfn dos_get_dta               // 2F
    dosfn dos_get_version           // 30
    dosfn dos_keep_process          // 31
    dosfn dos_get_dpb               // 32
    dosfn dos_break                 // 33
    dosfn dos_get_indos             // 34
    dosfn dos_get_vector            // 35
    dosfn dos_free_space            // 36
    dosfn dos_switchar              // 37
    dosfn dos_country               // 38
    dosfn dos_mkdir                 // 39
    dosfn dos_rmdir                 // 3A
    dosfn dos_chdir                 // 3B
    dosfn dos_create                // 3C
    dosfn dos_open_append           // 3D
    dosfn dos_close                 // 3E
    dosfn dos_read                  // 3F
    dosfn dos_write                 // 40
    dosfn dos_delete                // 41
    dosfn dos_seek                  // 42
    dosfn dos_attributes            // 43
    dosfn dos_ioctl                 // 44
    dosfn dos_dup                   // 45
    dosfn dos_dup2                  // 46
    dosfn dos_getcwd                // 47
    dosfn dos_allocate              // 48
    dosfn dos_free                  // 49
    dosfn dos_resize                // 4A
    dosfn dos_exec_append           // 4B
    dosfn dos_terminate             // 4C
    dosfn dos_get_exit_code         // 4D
    dosfn dos_find_first_append     // 4E
    dosfn dos_find_next             // 4F
    dosfn dos_set_psp               // 50
    dosfn dos_get_psp               // 51
    dosfn dos_list_of_lists         // 52
    dosfn dos_translate_bpb         // 53
    dosfn dos_get_verify            // 54
    dosfn dos_child_psp             // 55
    dosfn dos_rename                // 56
    dosfn dos_file_time             // 57
    dosfn dos_strategy              // 58
    dosfn dos_extended_error        // 59
    dosfn dos_create_temp           // 5A
    dosfn dos_create_new            // 5B
    dosfn dos_lock                  // 5C
    dosfn dos_server                // 5D
    dosfn dos_network_machine       // 5E
    dosfn dos_network_redirect      // 5F
    dosfn dos_truename              // 60
    dosfn dos_null_function         // 61
    dosfn dos_get_psp               // 62
    dosfn dos_dbcs                  // 63
    dosfn dos_null_function         // 64
    dosfn dos_ext_country           // 65
    dosfn dos_code_page             // 66
    dosfn dos_handle_count          // 67
    dosfn dos_commit                // 68
    dosfn dos_media_id              // 69
    dosfn dos_commit                // 6A
    dosfn dos_null_function         // 6B
    dosfn dos_extended_open_append  // 6C
    dosfn disk_services             // E0 (ARM DOS disk services, slot 6Dh)

// Reserved CP/M-compatibility and network-only numbers: AL=0, no effect.
dos_null_function:
    mov x0, #0
    mov x1, #0
    ret

dos_terminate_zero:
    mov x0, #0
    b dos_terminate

dos_bad_subfunction:
    mov x0, #1
    mov x1, #1
    ret

// ---------------------------------------------------------------------------
// Boot-time initialisation for the state kept in this file and its siblings.
dos2_init:
    frame
    address x0, dos_switch_char
    mov x1, #'/'
    str x1, [x0]
    address x0, dos_country_code
    mov x1, #1
    str x1, [x0]
    address x0, config_lastdrive
    mov x1, #5                  // E:, the DOS default
    str x1, [x0]
    address x0, config_buffers
    mov x1, #FAT_SLOTS_DEFAULT
    str x1, [x0]
    address x0, config_files
    mov x1, #SFT_ENTRIES
    str x1, [x0]
    // The shell's own descriptor answers 51h/62h when no program runs.
    address x0, kernel_descriptor
    address x1, process_signature
    ldr x1, [x1]
    str x1, [x0]
    mov x1, #1
    str x1, [x0, #8]
    mov x1, #64
    str x1, [x0, #16]
    address x1, dos_call
    str x1, [x0, #24]
    address x1, kernel_empty_tail
    str x1, [x0, #32]
    address x1, env_block
    str x1, [x0, #40]
    address x1, current_directory
    str x1, [x0, #48]
    address x1, image_handle
    ldr x1, [x1]
    str x1, [x0, #56]
    bl dev_init
    unframe

// ---------------------------------------------------------------------------
// 59h: x0 = last error, x2 = class, x3 = suggested action, x4 = locus.
dos_extended_error:
    address x9, dos_sda
    ldr x0, [x9, #SDA_ERROR]
    ldrb w2, [x9, #SDA_EXPLICIT]
    cbz w2, 1f
    ldrb w2, [x9, #SDA_CLASS]
    ldrb w3, [x9, #SDA_ACTION]
    ldrb w4, [x9, #SDA_LOCUS]
    mov x1, #0
    ret
1:
    address x10, dos_error_classes
2:
    ldrb w11, [x10]
    cbz w11, 3f
    cmp x11, x0
    b.eq 3f
    add x10, x10, #4
    b 2b
3:
    ldrb w2, [x10, #1]
    ldrb w3, [x10, #2]
    ldrb w4, [x10, #3]
    mov x1, #0
    ret

// 5Dh server functions without a network: 01 commit all files, 06 address of
// the swappable data area (x0) and its size (x2), 0A set extended error
// (x1 code, x2 class, x3 action, x4 locus). Others need a redirector.
dos_server:
    cmp x0, #1
    b.eq dos_disk_reset
    cmp x0, #6
    b.eq 1f
    cmp x0, #0x0a
    b.ne dos_bad_subfunction
    address x9, dos_sda
    str x1, [x9, #SDA_ERROR]
    strb w2, [x9, #SDA_CLASS]
    strb w3, [x9, #SDA_ACTION]
    strb w4, [x9, #SDA_LOCUS]
    mov w5, #1
    strb w5, [x9, #SDA_EXPLICIT]
    mov x0, #0
    mov x1, #0
    ret
1:
    address x0, dos_sda
    mov x2, #SDA_SIZE
    mov x3, #SDA_SIZE
    mov x1, #0
    ret

// 5Eh: 00 get machine name returns x2 = 0 (no name defined, no network).
dos_network_machine:
    cbnz x0, dos_bad_subfunction
    mov x2, #0
    mov x0, #0
    mov x1, #0
    ret
// 5Fh: 02 get redirection entry reports no entries; others need a network.
dos_network_redirect:
    cmp x0, #2
    b.ne dos_bad_subfunction
    mov x0, #18
    mov x1, #1
    ret

// ---------------------------------------------------------------------------
// 33h: x0 = 0 get (x2 = state), 1 set from x1, 2 exchange, 5 boot drive.
dos_break:
    address x9, dos_break_flag
    cmp x0, #0
    b.eq 1f
    cmp x0, #1
    b.eq 2f
    cmp x0, #2
    b.eq 3f
    cmp x0, #5
    b.ne dos_bad_subfunction
    mov x2, #1                  // A:
    b 4f
1:
    ldr x2, [x9]
    b 4f
2:
    and x1, x1, #1
    str x1, [x9]
    mov x2, x1
    b 4f
3:
    ldr x2, [x9]
    and x1, x1, #1
    str x1, [x9]
4:
    mov x0, #0
    mov x1, #0
    ret

// 2Eh: x0 = verify flag. 54h: x0 = verify flag. Writes are always flushed
// and read back by the cache, so the flag is kept for compatibility.
dos_set_verify:
    and x0, x0, #1
    address x9, dos_verify_flag
    str x0, [x9]
    mov x1, #0
    ret
dos_get_verify:
    address x9, dos_verify_flag
    ldr x0, [x9]
    mov x1, #0
    ret

// 34h: x0 = InDOS byte, x2 = critical-error flag byte.
dos_get_indos:
    address x0, dos_sda
    add x2, x0, #SDA_CRITICAL
    add x0, x0, #SDA_INDOS
    mov x1, #0
    ret

// 37h: 0 get switch character (x2), 1 set from x1, 2 AVAILDEV (x2=FFh), 3 set.
dos_switchar:
    address x9, dos_switch_char
    cmp x0, #0
    b.eq 1f
    cmp x0, #1
    b.eq 2f
    cmp x0, #2
    b.eq 3f
    cmp x0, #3
    b.ne dos_bad_subfunction
    mov x0, #0
    mov x1, #0
    ret
1:
    ldr x2, [x9]
    mov x0, #0
    mov x1, #0
    ret
2:
    and x1, x1, #255
    str x1, [x9]
    mov x2, x1
    mov x0, #0
    mov x1, #0
    ret
3:
    mov x2, #255
    mov x0, #0
    mov x1, #0
    ret

// 25h: x0 = vector 0-255, x1 = handler. 35h: x0 = vector -> x0 handler.
// Vector 23h is called on Ctrl-C (return x0=0 to continue); 22h-24h are
// saved and restored around every child process, as the PSP did.
dos_set_vector:
    cmp x0, #255
    b.hi dos_bad_subfunction
    address x9, dos_vectors
    str x1, [x9, x0, lsl #3]
    mov x0, #0
    mov x1, #0
    ret
dos_get_vector:
    cmp x0, #255
    b.hi dos_bad_subfunction
    address x9, dos_vectors
    ldr x0, [x9, x0, lsl #3]
    mov x1, #0
    ret

// ---------------------------------------------------------------------------
// The PSP of this port is the process descriptor (ABI.md).
dos_current_psp:
    address x0, dos_psp_override
    ldr x0, [x0]
    cbnz x0, 1f
    address x0, process_frames
    ldr x0, [x0]
    cbz x0, 2f
    add x0, x0, #328
1:
    ret
2:
    address x0, kernel_descriptor
    ret
dos_get_psp:
    frame
    bl dos_current_psp
    mov x2, x0
    mov x1, #0
    unframe
// 50h: x0 = descriptor to treat as current (0 restores the real one).
dos_set_psp:
    address x9, dos_psp_override
    str x0, [x9]
    mov x1, #0
    ret
// 26h / 55h: x0 = destination (64 bytes). Copies the current descriptor;
// 55h also makes the copy current, as DOS does for the new child PSP.
dos_create_psp:
    mov x2, #0
    b 1f
dos_child_psp:
    mov x2, #1
1:
    cbz x0, dos_bad_subfunction
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x2
    bl dos_current_psp
    mov x1, x19
    mov x2, #64
    bl copy_bytes
    cbz x20, 2f
    address x9, dos_psp_override
    str x19, [x9]
2:
    mov x0, x19
    mov x1, #0
    ldp x19, x20, [sp], #16
    unframe

// 58h: 0 get (x0), 1 set from x1: 0 first fit, 1 best fit, 2 last fit.
dos_strategy:
    address x9, plat_alloc_strategy
    cbnz x0, 1f
    ldr x0, [x9]
    mov x1, #0
    ret
1:
    cmp x0, #1
    b.ne dos_bad_subfunction
    cmp x1, #2
    b.hi dos_bad_subfunction
    str x1, [x9]
    mov x0, #0
    mov x1, #0
    ret

// 66h: 1 get (x2 active, x3 system code page), 2 set x1: the tables for
// the current country in that code page come from COUNTRY.SYS (NLSFUNC's
// job in DOS, built in here).
dos_code_page:
    cmp x0, #1
    b.eq 1f
    cmp x0, #2
    b.ne dos_bad_subfunction
    address x9, nls_code_page
    ldr x9, [x9]
    cmp x1, x9
    b.eq 3f
    cbz x1, 2f
    address x9, dos_country_code
    ldr x0, [x9]
    b nls_reload                // returns x1 = 0, or x0 = 2
3:
    mov x0, #0
    mov x1, #0
    ret
1:
    address x9, nls_code_page
    ldr x2, [x9]
    address x9, nls_system_code_page
    ldr x3, [x9]
    mov x0, x2
    mov x1, #0
    ret
2:
    mov x0, #2
    mov x1, #1
    ret

// 67h: x0 = handles wanted. The table holds 32 per process.
dos_handle_count:
    cmp x0, #32
    b.hi 1f
    mov x0, #0
    mov x1, #0
    ret
1:
    mov x0, #8
    mov x1, #1
    ret

// 63h: 0 -> x0 lead-byte table (empty: code page 437 has no DBCS);
// 1 set / 2 get interim console flag (x2 = 0).
dos_dbcs:
    cbnz x0, 1f
    address x0, nls_dbcs_table
    add x0, x0, #2
    mov x1, #0
    ret
1:
    cmp x0, #2
    b.hi dos_bad_subfunction
    mov x2, #0
    mov x0, #0
    mov x1, #0
    ret

// ---------------------------------------------------------------------------
// Ctrl-C (CTRLC.ASM). Called when ^C is read or seen while polling.
ctrl_c_poll:
    frame
    bl poll_key
    cmp x0, #3
    b.ne 1f
    address x1, pending_key
    str xzr, [x1]
    bl ctrl_c_raise
1:
    unframe

// Echo ^C, then give vector 23h a chance (x0=0 from it means continue);
// otherwise end the running program with termination type 1. Returns only
// when execution continues (or when no program is running).
ctrl_c_raise:
    frame
    address x0, ctrl_c_echo
    bl puts
    address x0, dos_vectors
    ldr x9, [x0, #0x23 * 8]
    cbz x9, 1f
    mov x0, #0
    blr x9
    cbz x0, 2f
1:
    address x0, process_frames
    ldr x0, [x0]
    cbz x0, 2f
    mov x1, #1
    str x1, [x0, #848]          // termination type 1 (Ctrl-C)
    mov x0, #0
    b proc_resume
2:
    unframe

// ---------------------------------------------------------------------------
.section .rodata
// Extended error classes (EXTERR.INC): code, class, action, locus.
dos_error_classes:
    .byte 1, 7, 4, 1
    .byte 2, 8, 3, 2
    .byte 3, 8, 3, 2
    .byte 4, 1, 4, 1
    .byte 5, 3, 3, 2
    .byte 6, 7, 4, 1
    .byte 7, 7, 5, 5
    .byte 8, 1, 4, 5
    .byte 9, 7, 4, 5
    .byte 10, 7, 4, 1
    .byte 11, 9, 3, 1
    .byte 12, 7, 4, 1
    .byte 13, 9, 4, 1
    .byte 15, 8, 3, 2
    .byte 16, 3, 3, 2
    .byte 17, 13, 3, 2
    .byte 18, 8, 3, 2
    .byte 19, 11, 7, 2
    .byte 20, 4, 5, 1
    .byte 21, 2, 7, 2
    .byte 23, 11, 4, 2
    .byte 25, 11, 4, 2
    .byte 27, 11, 4, 2
    .byte 29, 5, 4, 2
    .byte 30, 5, 4, 2
    .byte 31, 5, 4, 1
    .byte 32, 10, 2, 2
    .byte 33, 10, 2, 2
    .byte 34, 11, 7, 2
    .byte 36, 1, 4, 1
    .byte 50, 9, 3, 3
    .byte 80, 12, 3, 2
    .byte 82, 1, 4, 2
    .byte 83, 13, 4, 1
    .byte 0, 13, 4, 1           // anything else: unknown
ctrl_c_echo: .asciz "^C\r\n"
kernel_empty_tail: .asciz ""

.section .bss
.balign 16
// Swappable data area: these fields are the live kernel state.
dos_sda: .skip SDA_SIZE
dos_break_flag: .skip 8
dos_verify_flag: .skip 8
dos_switch_char: .skip 8
dos_psp_override: .skip 8
dos_vectors: .skip 256 * 8
kernel_descriptor: .skip 64
config_lastdrive: .skip 8
config_buffers: .skip 8
config_files: .skip 8
