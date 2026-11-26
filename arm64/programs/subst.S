// SPDX-License-Identifier: MIT
// SUBST [d: [d:]path] | SUBST d: /D (v4.0/src/CMD/SUBST): makes drive d:
// name a directory; /D removes it; no parameters lists the substitutions.
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
    mov x20, x0                 // the virtual drive
    mov x0, x19
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, bad_count
    mov x21, x0
    ldrb w2, [x21]
    cmp w2, #'/'
    b.eq remove
    mov x0, x19                 // nothing may follow the path
    bl next_arg
    ldrb w2, [x0]
    cbnz w2, bad_count
    // The drive must be free and within LASTDRIVE.
    address x9, cds_lastdrive
    ldr x9, [x9]
    cmp x20, x9
    b.hs bad_drive
    mov x0, x20
    bl cds_entry
    mov x22, x0
    ldr x2, [x22, #DRV_FLAGS]
    cbnz x2, bad_parm
    // The path: an existing directory, in its true form.
    mov x0, x21
    bl strupr
    mov x0, x21
    address x1, truename
    dos 0x60
    cbnz x1, path_not_found
    mov x0, x21
    mov x1, #0
    dos 0x43
    cbnz x1, path_not_found
    tbz x0, #4, path_not_found
    address x23, truename
    ldrb w2, [x23]
    sub x24, x2, #'A'           // the target drive
    cmp x24, x20
    b.eq bad_parm
    add x0, x23, #2             // "\DIR" without a trailing '\'
    add x1, x22, #DRV_PATH
    bl strcpy
    add x0, x22, #DRV_PATH
    bl strlen
    cmp x0, #1
    b.ne 1f
    strb wzr, [x22, #DRV_PATH]  // the root: no prefix at all
1:
    mov w2, #'\\'
    strh w2, [x22, #DRV_CWD]
    str x24, [x22, #DRV_TARGET]
    str xzr, [x22, #DRV_ASSIGN]
    mov x2, #DF_SUBST
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
    mov x22, x0
    ldr x2, [x22, #DRV_FLAGS]
    cmp x2, #DF_SUBST
    b.ne bad_parm
    dos 0x19                    // not the current drive
    cmp x0, x20
    b.eq bad_parm
    str xzr, [x22, #DRV_FLAGS]
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
    cmp x2, #DF_SUBST
    b.ne 2f
    add x0, x20, #'A'
    bl putc
    say ": => "
    ldr x0, [x22, #DRV_TARGET]
    add x0, x0, #'A'
    bl putc
    mov x0, #':'
    bl putc
    ldrb w2, [x22, #DRV_PATH]
    cbnz w2, 11f
    mov x0, #'\\'
    bl putc
    b 12f
11:
    add x0, x22, #DRV_PATH
    bl puts
12:
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
path_not_found:
    say "Path not found - "
    mov x0, x21
    bl puts
    bl crlf
    mov x0, #1
    leave

.section .bss
truename: .skip 128
