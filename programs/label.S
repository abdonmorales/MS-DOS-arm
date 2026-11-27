// SPDX-License-Identifier: MIT
// LABEL [d:][label] (MS-DOS 4.0 src/CMD/LABEL): shows, sets or deletes the volume
// label, both the root directory's volume entry and the boot record copy.
.include "lib.inc"
.include "fatlib.inc"

main:
    enter
    bl skip_blanks
    mov x19, x0
    ldrb w2, [x19]
    cbz w2, 1f
    ldrb w3, [x19, #1]
    cmp w3, #':'
    b.ne 1f
    mov w0, w2
    bl toupper
    sub x2, x0, #('A' - 1)
    cmp x2, #26
    b.hi bad_drive
    address x9, fl_drive
    str x2, [x9]
    add x0, x19, #2
    bl skip_blanks
    mov x19, x0
1:
    mov x0, x19
    bl rtrim
    address x9, fl_drive        // the drive's letter for the messages
    ldr x0, [x9]
    cbnz x0, 11f
    dos 0x19
    add x0, x0, #1
    address x9, fl_drive
    str x0, [x9]
11:
    add x0, x0, #('A' - 1)
    address x9, drive_letter
    strb w0, [x9]
    bl fl_init
    cbnz x1, bad_drive
    mov x0, #0
    address x9, fl_drive
    ldr x1, [x9]
    address x2, media
    dos 0x69
    cbnz x1, disk_error
    // Current label from the root directory (it is authoritative).
    mov x0, #0
    address x1, dir
    mov x2, #65536
    bl fl_dir_load
    cbnz x1, disk_error
    mov x20, x0
    bl find_label
    mov x21, x0                 // entry or 0
    ldrb w2, [x19]              // a label given: set it without a word
    cbnz w2, 5f
    say "Volume in drive "
    address x0, drive_letter
    bl puts
    mov x0, #' '
    bl putc
    cbz x21, 2f
    say "is "
    mov x0, x21
    address x1, text
    bl copy_label
    address x0, text
    bl puts
    bl crlf
    b 3f
2:
    say "has no label\r\n"
3:
    say "Volume Serial Number is "
    address x0, media
    ldrh w0, [x0, #4]
    mov x1, #4
    bl put_hex
    mov x0, #'-'
    bl putc
    address x0, media
    ldrh w0, [x0, #2]
    mov x1, #4
    bl put_hex
    bl crlf
    ldrb w2, [x19]
    cbnz w2, 5f
4:
    say "Volume label (11 characters, ENTER for none)? "
    address x0, line
    mov w2, #12
    strb w2, [x0]
    bl read_console_line
    bl skip_blanks
    mov x19, x0
    bl rtrim
    ldrb w2, [x19]
    cbnz w2, 5f
    cbz x21, done
    address x0, delete_question
    bl ask_yn
    cbz x0, done
    mov w2, #0xe5
    strb w2, [x21]
    address x0, dir
    bl fl_dir_write
    cbnz x1, disk_error
    address x0, no_name
    bl set_boot_label
    b done
5:
    // Validate and pad to 11 characters.
    mov x0, x19
    bl strupr
    mov x0, x19
    bl strlen
    cmp x0, #11
    b.hi too_long
    address x22, new_label
    mov x2, #0
6:
    cmp x2, #11
    b.hs 8f
    ldrb w3, [x19, x2]
    cbz w3, 7f
    address x9, invalid_chars
61:
    ldrb w4, [x9], #1
    cbz w4, 62f
    cmp w3, w4
    b.eq invalid
    b 61b
62:
    strb w3, [x22, x2]
    add x2, x2, #1
    b 6b
7:
    mov w3, #' '
71:
    strb w3, [x22, x2]
    add x2, x2, #1
    cmp x2, #11
    b.lo 71b
8:
    cbnz x21, 9f
    bl free_entry
    cbz x0, root_full
    mov x21, x0
    mov x2, #0
81:
    strb wzr, [x21, x2]
    add x2, x2, #1
    cmp x2, #32
    b.lo 81b
    mov w2, #0x08
    strb w2, [x21, #11]
    dos 0x2c                    // time and date of the label
    lsl w4, w0, #11
    orr w4, w4, w2, lsl #5
    lsr w3, w3, #1
    orr w4, w4, w3
    strh w4, [x21, #22]
    dos 0x2a
    sub w0, w0, #1980
    lsl w4, w0, #9
    orr w4, w4, w2, lsl #5
    orr w4, w4, w3
    strh w4, [x21, #24]
9:
    mov x2, #0
91:
    ldrb w3, [x22, x2]
    strb w3, [x21, x2]
    add x2, x2, #1
    cmp x2, #11
    b.lo 91b
    address x0, dir
    bl fl_dir_write
    cbnz x1, disk_error
    mov x0, x22
    bl set_boot_label
done:
    mov x0, #0
    leave
too_long:
    say "Label too long\r\n"
    b 4b
invalid:
    say "Invalid characters in volume label\r\n"
    b 4b
root_full:
    say "Cannot make directory entry\r\n"
    mov x0, #1
    leave
bad_drive:
    say "Invalid drive specification\r\n"
    mov x0, #1
    leave
disk_error:
    say "Disk error\r\n"
    mov x0, #1
    leave

// Returns x0 = the volume-label entry in `dir` (x20 bytes), or 0.
find_label:
    address x0, dir
    add x1, x0, x20
1:
    cmp x0, x1
    b.hs 3f
    ldrb w2, [x0]
    cbz w2, 3f
    cmp w2, #0xe5
    b.eq 2f
    ldrb w3, [x0, #11]
    cmp w3, #0x0f
    b.eq 2f
    tbz w3, #3, 2f
    ret
2:
    add x0, x0, #32
    b 1b
3:
    mov x0, #0
    ret

// Returns x0 = a free entry in `dir`, or 0.
free_entry:
    address x0, dir
    add x1, x0, x20
1:
    cmp x0, x1
    b.hs 3f
    ldrb w2, [x0]
    cbz w2, 2f
    cmp w2, #0xe5
    b.eq 2f
    add x0, x0, #32
    b 1b
2:
    ret
3:
    mov x0, #0
    ret

// x0 = entry, x1 = output: the label without trailing blanks.
copy_label:
    mov x2, #0
1:
    ldrb w3, [x0, x2]
    strb w3, [x1, x2]
    add x2, x2, #1
    cmp x2, #11
    b.lo 1b
    strb wzr, [x1, #11]
    mov x0, x1
    b rtrim

// x0 = 11-byte label: copies it into the boot record (69h).
set_boot_label:
    frame
    mov x1, x0
    address x2, media
    add x2, x2, #6
    mov x3, #0
1:
    ldrb w4, [x1, x3]
    strb w4, [x2, x3]
    add x3, x3, #1
    cmp x3, #11
    b.lo 1b
    mov x0, #1
    address x9, fl_drive
    ldr x1, [x9]
    address x2, media
    dos 0x69
    unframe

.section .rodata
delete_question: .asciz "\r\nDelete current volume label (Y/N)? "
no_name: .ascii "NO NAME    "
invalid_chars: .asciz "*?/\\|.,;:+=<>[]\"\t"
.section .bss
.balign 8
media: .skip 32
new_label: .skip 16
text: .skip 16
line: .skip 16
dir: .skip 65536
.section .data
drive_letter: .asciz "A"
