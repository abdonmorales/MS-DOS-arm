// SPDX-License-Identifier: MIT
// ROM test program (make rom-test): FCB open (0Fh) of a file on the read-only
// ROM disk must succeed, falling back to a read-only open.
.include "lib.inc"
main:
    enter
    address x0, fcb
    dos 0x0f
    cbnz x0, 1f
    say "FCB open OK\r\n"
    b 9f
1:  say "FCB open FAILED\r\n"
9:  mov x0, #0
    leave
.data
.balign 8
fcb: .byte 1
     .ascii "README  TXT"
     .skip 64
