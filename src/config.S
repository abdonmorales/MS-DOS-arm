// SPDX-License-Identifier: MIT
// CONFIG.SYS processing (SYSINIT1.ASM/SYSCONF.ASM in MS-DOS 4.0 src/BIOS):
// BREAK, BUFFERS, COUNTRY, DEVICE, FCBS, FILES, INSTALL, LASTDRIVE, REM,
// SHELL and STACKS. Lines are processed in order, except that INSTALL
// programs run after every DEVICE driver has loaded, as in DOS 4.0.
.equ CONFIG_SIZE, 8192
.section .text

// x0 = text. Returns x0 = keyword index (or -1), x1 = value text.
config_keyword:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    address x20, config_keywords
    mov x21, #0
1:
    ldrb w2, [x20]
    cbz w2, 8f
    mov x2, x19
    mov x3, x20
2:
    ldrb w4, [x3], #1
    cbz w4, 4f
    ldrb w5, [x2], #1
    cmp w5, #'a'
    b.lo 3f
    cmp w5, #'z'
    b.hi 3f
    sub w5, w5, #32
3:
    cmp w4, w5
    b.eq 2b
    b 7f
4:
    ldrb w5, [x2]               // keyword ends at blank, '=' or end
    cbz w5, 6f
    cmp w5, #' '
    b.eq 5f
    cmp w5, #9
    b.eq 5f
    cmp w5, #'='
    b.ne 7f
5:
    ldrb w5, [x2]
    cmp w5, #' '
    b.eq 51f
    cmp w5, #9
    b.eq 51f
    cmp w5, #'='
    b.ne 6f
51:
    add x2, x2, #1
    b 5b
6:
    mov x0, x21
    mov x1, x2
    b 9f
7:
    ldrb w4, [x20], #1          // next keyword
    cbnz w4, 7b
    add x21, x21, #1
    b 1b
8:
    mov x0, #-1
    mov x1, x19
9:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// Reads \CONFIG.SYS (if present) and applies it.
config_process:
    enter
    address x0, config_path
    mov x1, #0
    bl dos_open
    cbnz x1, config_done
    mov x19, x0
    address x20, config_text
    mov x21, #0
1:
    mov x0, x19
    add x1, x20, x21
    mov x2, #CONFIG_SIZE - 1
    sub x2, x2, x21
    cbz x2, 2f
    bl dos_read
    cbnz x1, 2f
    cbz x0, 2f
    add x21, x21, x0
    b 1b
2:
    strb wzr, [x20, x21]
    mov x0, x19
    bl dos_close
    address x0, config_install_count
    str xzr, [x0]
    mov x22, #0                 // line number
    mov x23, x20                // cursor
config_line:
    ldrb w2, [x23]
    cbz w2, config_installs
    add x22, x22, #1
    mov x24, x23                // line start
1:
    ldrb w2, [x23]
    cbz w2, 3f
    cmp w2, #13
    b.eq 2f
    cmp w2, #10
    b.eq 2f
    cmp w2, #0x1a
    b.eq 21f
    add x23, x23, #1
    b 1b
21:
    strb wzr, [x23]             // ^Z ends the file
    b 3f
2:
    strb wzr, [x23], #1
    ldrb w2, [x23]
    cmp w2, #10
    b.ne 3f
    add x23, x23, #1
3:
    mov x0, x24
    bl skip_blanks
    mov x24, x0
    bl trim_trailing
    ldrb w2, [x24]
    cbz w2, config_line
    cmp w2, #';'
    b.eq config_line
    mov x0, x24                 // lines are at most 255 characters
    bl fat_strlen
    cmp x0, #255
    b.hi config_bad_line
    mov x0, x24
    bl config_keyword
    mov x25, x1
    cmp x0, #0
    b.lt config_unrecognized
    address x2, config_handlers
    ldrsw x3, [x2, x0, lsl #2]
    add x3, x2, x3
    mov x0, x25
    blr x3
    cbz x1, config_line
    b config_bad_line
config_unrecognized:
    address x0, config_unrecognized_message
    bl puts
config_bad_line:
    address x0, config_error_line
    bl puts
    mov x0, x22
    mov x1, #1
    bl print_number_width
    address x0, newline
    bl puts
    b config_line
config_installs:
    address x24, config_install_list
    address x25, config_install_count
    ldr x25, [x25]
1:
    cbz x25, config_done
    ldr x0, [x24], #8
    bl config_run_program
    sub x25, x25, #1
    b 1b
config_done:
    leave

// x0 = "path [arguments]": runs a program (INSTALL=, or SHELL=).
config_run_program:
    frame
    stp x19, x20, [sp, #-16]!
    bl next_word
    mov x19, x0
    mov x20, x1
    mov x0, x19
    mov x1, x20
    bl dos_exec
    cbz x1, 1f
    address x0, config_bad_program
    bl puts
    mov x0, x19
    bl puts
    address x0, newline
    bl puts
1:
    ldp x19, x20, [sp], #16
    unframe

// Each handler: x0 = value text. Returns x1 = 0, or x1 = 1 for an error.
config_rem:
    mov x1, #0
    ret

config_break:
    frame
    mov x1, #0
    bl on_off_argument
    cmp x0, #1
    b.hi 1f
    address x9, dos_break_flag
    str x0, [x9]
    mov x1, #0
    unframe
1:
    mov x1, #1
    unframe

// BUFFERS=n[,m]: n sector buffers (1-99); up to 32 are cached.
config_buffers_set:
    frame
    bl config_number
    cbnz x1, 2f
    cbz x0, 2f
    cmp x0, #99
    b.hi 2f
    address x9, config_buffers
    str x0, [x9]
    cmp x0, #2
    b.hs 1f
    mov x0, #2
1:
    cmp x0, #FAT_SLOTS
    b.ls 3f
    mov x0, #FAT_SLOTS
3:
    address x9, fat_slot_count
    str x0, [x9]
    mov x1, #0
    unframe
2:
    mov x1, #1
    unframe

// FILES=n (8-255): open files at once (the SFT holds up to 64).
config_files_set:
    frame
    bl config_number
    cbnz x1, 2f
    cmp x0, #8
    b.lo 2f
    cmp x0, #255
    b.hi 2f
    cmp x0, #SFT_ENTRIES
    b.ls 1f
    mov x0, #SFT_ENTRIES
1:
    address x9, config_files
    str x0, [x9]
    mov x1, #0
    unframe
2:
    mov x1, #1
    unframe

// FCBS=n,m and STACKS=n,s: accepted for compatibility; FCBs have no table
// limit and interrupt stacks are per exception level on AArch64.
config_accept:
    frame
    bl config_number
    unframe

// COUNTRY=nnn[,[cp][,file]]: the country's tables come from COUNTRY.SYS
// (default \COUNTRY.SYS on the boot drive). Without that file the built-in
// code page 437 records are used.
config_country:
    enter
    mov x19, x0
    bl config_number
    cbnz x1, 8f
    mov x20, x0                 // country
    mov x21, #0                 // code page
    address x22, config_country_file
1:
    ldrb w2, [x19]
    cbz w2, 4f
    add x19, x19, #1
    cmp w2, #','
    b.ne 1b
    ldrb w2, [x19]
    cmp w2, #','
    b.eq 2f
    cbz w2, 4f
    mov x0, x19
    bl config_number
    cbnz x1, 8f
    mov x21, x0
2:
    ldrb w2, [x19]              // the file after the second comma
    cbz w2, 4f
    add x19, x19, #1
    cmp w2, #','
    b.ne 2b
    mov x0, x19
    bl skip_blanks
    ldrb w2, [x0]
    cbz w2, 4f
    address x1, nls_file
    bl config_copy_word
    mov x23, #1                 // named: it must load
    b 5f
4:
    address x0, config_country_file
    address x1, nls_file
    bl config_copy_word
    mov x23, #0
5:
    mov x0, x20
    mov x1, x21
    address x2, nls_file
    bl nls_load
    cbnz x1, 6f
    address x9, nls_code_page
    ldr x2, [x9]
    address x9, nls_system_code_page
    str x2, [x9]
    b 9f
6:
    cmp x0, #2
    b.ne 8f
    address x9, nls_file        // no COUNTRY.SYS: the built-in records
    strb wzr, [x9]
    cbnz x23, 8f
    cbz x21, 7f
    cmp x21, #437
    b.ne 8f
7:
    mov x1, x20
    mov x0, #0
    bl dos_country
    cbz x1, 9f
8:
    address x0, config_bad_country
    bl puts
9:
    mov x1, #0
    leave

// x0 = text, x1 = 128-byte output: copies one word (to a blank or the end).
config_copy_word:
    mov x2, #0
1:
    ldrb w3, [x0, x2]
    cmp w3, #' '
    b.ls 2f
    strb w3, [x1, x2]
    add x2, x2, #1
    cmp x2, #127
    b.lo 1b
2:
    strb wzr, [x1, x2]
    ret

// LASTDRIVE=x (A-Z)
config_lastdrive_set:
    ldrb w2, [x0]
    cmp w2, #'a'
    b.lo 1f
    sub w2, w2, #32
1:
    cmp w2, #'A'
    b.lo 2f
    cmp w2, #'Z'
    b.hi 2f
    ldrb w3, [x0, #1]
    cbz w3, 3f
    cmp w3, #':'
    b.ne 2f
3:
    sub w2, w2, #'A' - 1
    address x9, config_lastdrive
    str x2, [x9]
    mov x1, #0
    ret
2:
    mov x1, #1
    ret

// SHELL=path [arguments]: COMSPEC; a program other than the built-in
// COMMAND (the kernel's own \EFI\BOOT\BOOTAA64.EFI) runs instead of it.
config_shell:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    bl fat_strlen               // the buffers hold 255 characters
    cmp x0, #255
    b.hi 9f
    mov x0, x19
    address x1, config_shell_line
    bl copy_cstring
    address x0, config_shell_line
    address x1, config_shell_name
    bl copy_cstring
    address x0, config_shell_name
    bl next_word
    mov x20, x0
    address x0, comspec_name
    mov x1, x20
    bl env_set
    mov x0, x20
    address x1, config_canon
    bl canonicalize_path
    cbnz x1, 1f
    address x0, config_canon
    address x1, kernel_image_path
    bl strcasecmp
    cbz x0, 2f
    mov x0, x20
    bl config_is_command
    cbnz x0, 2f
1:
    address x9, config_shell_program
    mov x1, #1
    str x1, [x9]
2:
    mov x1, #0
    ldp x19, x20, [sp], #16
    unframe
9:
    mov x1, #1                  // too long: reported as a bad line
    ldp x19, x20, [sp], #16
    unframe

// x0 = path. Returns x0 = 1 if its name is COMMAND.COM.
config_is_command:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
    bl dir_prefix_len
    add x0, x19, x0
    address x1, command_com
    bl strcasecmp
    cmp x0, #0
    cset x0, eq
    ldr x19, [sp], #16
    unframe

// INSTALL=path [arguments]: queued until the drivers are loaded.
config_install:
    address x9, config_install_count
    ldr x10, [x9]
    cmp x10, #8
    b.hs 1f
    address x11, config_install_list
    str x0, [x11, x10, lsl #3]
    add x10, x10, #1
    str x10, [x9]
    mov x1, #0
    ret
1:
    mov x1, #1
    ret

// DEVICE=path [arguments]: loads a native driver image (see ABI.md) and
// calls its entry with an init request; the driver stays resident.
config_device:
    enter
    bl next_word
    mov x19, x0
    mov x20, x1
    mov x0, x19
    mov x1, #0
    mov x2, #0
    bl pe_load
    cbnz x1, 8f
    mov x21, x2
    address x22, config_request
    mov x0, #0
1:
    str xzr, [x22, x0]
    add x0, x0, #8
    cmp x0, #96
    b.lo 1b
    address x0, dos_call
    str x0, [x22]
    bl drive_next_free          // a block driver's unit gets this letter
    str x0, [x22, #64]
    address x0, plat_putc       // the UART itself, for CON and PRN drivers
    str x0, [x22, #72]
    address x0, plat_poll_key
    str x0, [x22, #80]
    mov x0, x20
    bl skip_blanks
    mov x1, x0
    address x0, config_device_tails
    address x2, config_device_count
    ldr x3, [x2]
    cmp x3, #16
    b.hs 8f
    add x4, x3, #1
    str x4, [x2]
    add x23, x0, x3, lsl #7     // driver arguments stay valid while resident
    mov x2, #0
11:
    ldrb w3, [x1, x2]
    strb w3, [x23, x2]
    cbz w3, 12f
    add x2, x2, #1
    cmp x2, #127
    b.lo 11b
    strb wzr, [x23, x2]
12:
    str x23, [x22, #8]
    mov x0, x22
    blr x21
    cbnz x1, 7f
    ldr x2, [x22, #48]          // sectors: a block device
    cbz x2, 6f
    ldr x0, [x22, #24]
    ldr x1, [x22, #56]
    cbz x0, 7f
    bl drive_add_block
    cbnz x1, 7f
    mov x1, #0
    leave
6:
    mov x0, x22
    bl dev_install
    cbnz x1, 7f
    mov x1, #0
    leave
7:
    address x0, config_driver_failed
    bl puts
    mov x0, x19
    bl puts
    address x0, newline
    bl puts
    mov x1, #0
    leave
8:
    address x0, config_bad_device
    bl puts
    mov x0, x19
    bl puts
    address x0, newline
    bl puts
    mov x1, #0
    leave

// x0 = text: decimal number up to ',' or the end.
config_number:
    frame
    address x1, config_scratch
    mov x2, #0
1:
    ldrb w3, [x0, x2]
    cbz w3, 2f
    cmp w3, #','
    b.eq 2f
    cmp w3, #' '
    b.eq 2f
    strb w3, [x1, x2]
    add x2, x2, #1
    cmp x2, #15
    b.lo 1b
2:
    strb wzr, [x1, x2]
    mov x0, x1
    bl parse_unsigned
    unframe

// After AUTOEXEC: a SHELL= program other than COMMAND runs here; when it
// returns, the built-in COMMAND takes over.
config_start_shell:
    frame
    address x0, config_shell_program
    ldr x0, [x0]
    cbz x0, 1f
    address x0, config_shell_line
    bl config_run_program
1:
    unframe

.section .rodata
.balign 4
config_handlers:
    .long config_break - config_handlers
    .long config_buffers_set - config_handlers
    .long config_country - config_handlers
    .long config_device - config_handlers
    .long config_accept - config_handlers
    .long config_files_set - config_handlers
    .long config_install - config_handlers
    .long config_lastdrive_set - config_handlers
    .long config_rem - config_handlers
    .long config_shell - config_handlers
    .long config_accept - config_handlers
config_keywords:
    .asciz "BREAK"
    .asciz "BUFFERS"
    .asciz "COUNTRY"
    .asciz "DEVICE"
    .asciz "FCBS"
    .asciz "FILES"
    .asciz "INSTALL"
    .asciz "LASTDRIVE"
    .asciz "REM"
    .asciz "SHELL"
    .asciz "STACKS"
    .byte 0
config_path: .asciz "\\CONFIG.SYS"
config_unrecognized_message: .asciz "Unrecognized command in CONFIG.SYS\r\n"
config_error_line: .asciz "Error in CONFIG.SYS line "
config_bad_device: .asciz "Bad or missing "
config_driver_failed: .asciz "Device driver did not install: "
config_bad_program: .asciz "Bad or missing program: "
config_bad_country: .asciz "Invalid country code or code page\r\n"
config_country_file: .asciz "A:\\COUNTRY.SYS"
comspec_name: .asciz "COMSPEC"
kernel_image_path: .asciz "\\EFI\\BOOT\\BOOTAA64.EFI"
command_com: .asciz "COMMAND.COM"
.section .bss
.balign 16
config_text: .skip CONFIG_SIZE
config_request: .skip 96
config_install_list: .skip 64
config_install_count: .skip 8
config_shell_program: .skip 8
config_shell_line: .skip 256
config_shell_name: .skip 256
config_canon: .skip 256
config_scratch: .skip 16
config_device_count: .skip 8
config_device_tails: .skip 16 * 128
