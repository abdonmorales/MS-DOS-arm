// SPDX-License-Identifier: MIT
// JOIN [d: [d:]path] | JOIN d: /D (MS-DOS 4.0 src/CMD/JOIN): makes drive d:
// appear as an empty directory of another drive; /D undoes it; with no
// parameters the joins are listed. A joined drive cannot be named itself.
.include "lib.inc"
.include "cds.inc"

main:
    enter
    mov x19, x0
    bl cds_init
    mov x0, x19
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, list
    mov x1, #0
    bl cds_parse_drive
    cmn x0, #1
    b.eq bad_parm
    mov x20, x0                 // the drive being joined
    mov x0, x19
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, bad_count
    mov x21, x0
    cmp w2, #'/'
    b.eq remove
    mov x0, x19
    bl next_arg
    ldrb w2, [x0]
    cbnz w2, bad_count
    // A physical drive that is not current, substituted or joined.
    address x9, cds_count
    ldr x9, [x9]
    cmp x20, x9
    b.hs bad_drive
    mov x0, x20
    bl cds_entry
    mov x22, x0
    ldr x2, [x22, #DRV_FLAGS]
    cmp x2, #DF_VALID
    b.ne bad_parm
    dos 0x19
    cmp x0, x20
    b.eq bad_parm
    // The directory: on another physical drive, not its root, empty.
    mov x0, x21
    bl strupr
    mov x0, x21
    address x1, truename
    dos 0x60
    cbnz x1, bad_parm
    address x23, truename
    ldrb w2, [x23]
    sub x24, x2, #'A'
    cmp x24, x20
    b.eq bad_parm
    ldrb w2, [x23, #3]
    cbz w2, bad_parm            // not the root
    mov x0, x24
    bl cds_entry
    ldr x2, [x0, #DRV_FLAGS]
    cmp x2, #DF_VALID
    b.ne bad_parm
    mov x0, x23
    mov x1, #0
    dos 0x43
    cbz x1, 1f
    mov x0, x23                 // created when missing, as DOS did
    dos 0x39
    cbnz x1, bad_parm
    b 3f
1:
    tbz x0, #4, bad_parm
    mov x0, x23
    address x1, star
    address x2, pattern
    bl join_path
    address x0, dta
    mov x1, #280
    dos 0x1a
    address x0, pattern
    mov x1, #0x16
    dos 0x4e
2:
    cbnz x1, 3f
    address x9, dta
    ldrb w2, [x9, #24]
    cmp w2, #'.'
    b.ne not_empty
    dos 0x4f
    b 2b
3:
    add x0, x23, #2
    add x1, x22, #DRV_PATH
    bl strcpy
    str x24, [x22, #DRV_TARGET]
    mov x2, #(DF_VALID | DF_JOINED)
    str x2, [x22, #DRV_FLAGS]
    mov x0, #0
    leave

remove:
    ldrb w0, [x21, #1]
    bl toupper
    cmp w0, #'D'
    b.ne bad_parm
    ldrb w2, [x21, #2]
    cbnz w2, bad_parm
    mov x0, x20
    bl cds_entry
    ldr x2, [x0, #DRV_FLAGS]
    tbz x2, #2, bad_parm
    bic x2, x2, #DF_JOINED
    str x2, [x0, #DRV_FLAGS]
    mov x0, #0
    leave

list:
    mov x20, #0
1:
    address x9, cds_count
    ldr x9, [x9]
    cmp x20, x9
    b.hs 3f
    mov x0, x20
    bl cds_entry
    mov x22, x0
    ldr x2, [x22, #DRV_FLAGS]
    tbz x2, #2, 2f
    add x0, x20, #'A'
    bl putc
    say ": => "
    ldr x0, [x22, #DRV_TARGET]
    add x0, x0, #'A'
    bl putc
    mov x0, #':'
    bl putc
    add x0, x22, #DRV_PATH
    bl puts
    bl crlf
2:
    add x20, x20, #1
    b 1b
3:
    mov x0, #0
    leave

bad_count:
    say "Incorrect number of parameters\r\n"
    mov x0, #1
    leave
bad_parm:
    say "Invalid parameter\r\n"
    mov x0, #1
    leave
bad_drive:
    say "Invalid drive specification\r\n"
    mov x0, #1
    leave
not_empty:
    say "Directory not empty\r\n"
    mov x0, #1
    leave

.section .rodata
star: .asciz "*.*"
.section .bss
.balign 8
dta: .skip 280
truename: .skip 128
pattern: .skip 160
