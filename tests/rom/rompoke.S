// SPDX-License-Identifier: MIT
// ROM test program (make rom-test): rewrites a root directory sector of A:
// through the raw sector IOCTL. The ROM disk must refuse it, and the refused
// bytes must not stay in the sector cache (DIR must still list ANSI.SYS).
.include "lib.inc"
.include "fatlib.inc"
main:
    enter
    mov x2, #1
    address x9, fl_drive
    str x2, [x9]
    bl fl_init
    cbnz x1, 90f
    flp x19, FL_ROOT_START
    mov x0, x19
    mov x1, #1
    address x2, buf
    bl fl_read
    cbnz x1, 91f
    address x2, buf
    mov w3, #'Z'
    strb w3, [x2, #32]          // second root entry's first name byte
    strb w3, [x2, #33]
    mov x0, x19
    mov x1, #1
    address x2, buf
    bl fl_write
    cbz x1, 92f
    say "write refused\r\n"
    b 99f
92: say "write ACCEPTED\r\n"
99:
    mov x0, #0
    leave
90: say "init fail\r\n"
    b 99b
91: say "read fail\r\n"
    b 99b
.section .bss
.balign 16
buf: .skip 4096
