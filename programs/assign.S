// SPDX-License-Identifier: MIT
// ASSIGN [x[:]=y[:] [...]] | ASSIGN /STATUS (MS-DOS 4.0 src/CMD/ASSIGN): sends
// requests for drive x to drive y. With no parameters every assignment is
// removed; /STATUS lists them.
.include "lib.inc"
.include "cds.inc"

main:
    enter
    mov x19, x0
    bl cds_init
    mov x0, x19
    bl skip_blanks
    mov x19, x0
    ldrb w2, [x19]
    cbz w2, clear
    cmp w2, #'/'
    b.eq status
    mov x23, #0                 // pairs set
1:
    bl next_letter
    cmn x0, #1
    b.eq 3f
    mov x20, x0
    bl next_letter
    cmn x0, #1
    b.eq bad_parm
    mov x21, x0
    address x9, cds_count
    ldr x9, [x9]
    cmp x20, x9
    b.hs bad_parm
    cmp x21, x9
    b.hs bad_parm
    mov x0, x21                 // the target must be a real drive
    bl cds_entry
    ldr x2, [x0, #DRV_FLAGS]
    tst x2, #(DF_VALID | DF_SUBST)
    b.eq bad_drive
    tbnz x2, #2, bad_drive
    mov x0, x20
    bl cds_entry
    cmp x20, x21
    csel x2, xzr, x21, eq       // x=x removes it
    add x3, x2, #1
    csel x2, xzr, x3, eq
    str x2, [x0, #DRV_ASSIGN]
    add x23, x23, #1
    b 1b
3:
    cbz x23, bad_parm
    mov x0, #0
    leave

// Parses the next drive letter from x19 (skipping blanks, ':' and '=').
// Returns x0 = drive (0-based) or -1 at the end.
next_letter:
1:
    ldrb w2, [x19]
    cbz w2, 8f
    cmp w2, #' '
    b.eq 2f
    cmp w2, #':'
    b.eq 2f
    cmp w2, #'='
    b.eq 2f
    cmp w2, #9
    b.eq 2f
    orr w2, w2, #0x20
    sub w0, w2, #'a'
    cmp w0, #26
    b.hs 9f
    add x19, x19, #1
    ret
2:
    add x19, x19, #1
    b 1b
8:
    mov x0, #-1
    ret
9:
    mov x0, #-2                 // not a letter: caught as a bad pair
    add x19, x19, #1
    ret

clear:
    mov x20, #0
1:
    address x9, cds_count
    ldr x9, [x9]
    cmp x20, x9
    b.hs 2f
    mov x0, x20
    bl cds_entry
    str xzr, [x0, #DRV_ASSIGN]
    add x20, x20, #1
    b 1b
2:
    mov x0, #0
    leave

status:
    ldrb w0, [x19, #1]
    bl toupper
    cmp w0, #'S'
    b.ne bad_parm
    mov x20, #0
1:
    address x9, cds_count
    ldr x9, [x9]
    cmp x20, x9
    b.hs 3f
    mov x0, x20
    bl cds_entry
    ldr x22, [x0, #DRV_ASSIGN]
    cbz x22, 2f
    say "Original "
    add x0, x20, #'A'
    bl putc
    say ": set to "
    add x0, x22, #('A' - 1)
    bl putc
    say ":\r\n"
2:
    add x20, x20, #1
    b 1b
3:
    mov x0, #0
    leave

bad_parm:
    say "Invalid parameter\r\n"
    mov x0, #1
    leave
bad_drive:
    say "Invalid drive specification\r\n"
    mov x0, #1
    leave
