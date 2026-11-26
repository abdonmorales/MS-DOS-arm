// SPDX-License-Identifier: MIT
// DOSTEST.EXE: exercises the DOS function set from a separately loaded
// native program. Prints "DOSTEST PASS" or "DOSTEST FAIL <step>".
// Arguments: (none) full test; "tsr" stays resident with code 5;
// "wait" reads a key (used for the Ctrl-C test); "ctrlc" runs "wait" as a
// child and checks that it ended with termination type 1.
.macro address reg, name
    adrp \reg, \name
    add \reg, \reg, :lo12:\name
.endm
.macro dos fn
    mov w8, #\fn
    blr x19
.endm
.macro ok
    cbnz x1, fail
.endm
.macro err code
    cmp x1, #1
    b.ne fail
    cmp x0, #\code
    b.ne fail
.endm
.macro step n
    mov x27, #\n
.endm
.macro expect reg, val
    mov x9, #\val
    cmp \reg, x9
    b.ne fail
.endm
.macro expectb base, off, val
    ldrb w12, [\base, #\off]
    cmp w12, #\val
    b.ne fail
.endm

.section .text
.global efi_main
efi_main:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x27, #0
    cbz x0, fail
    mov x28, x0                 // descriptor
    ldr x19, [x0, #24]
    ldr x20, [x0, #32]          // command tail
    ldrb w0, [x20]
    cmp w0, #'t'
    b.eq mode_tsr
    cmp w0, #'w'
    b.eq mode_wait
    cmp w0, #'c'
    b.eq mode_ctrlc

    step 1                      // 59h after a failed open
    address x0, missing_name
    mov x1, #0
    dos 0x3d
    err 2
    dos 0x59
    expect x0, 2
    expect x2, 8
    expect x4, 2

    step 2                      // 33h break flag and boot drive
    mov x0, #1
    mov x1, #1
    dos 0x33
    ok
    mov x0, #0
    dos 0x33
    expect x2, 1
    mov x0, #1
    mov x1, #0
    dos 0x33
    mov x0, #5
    dos 0x33
    expect x2, 1

    step 3                      // 2Eh / 54h verify
    mov x0, #1
    dos 0x2e
    dos 0x54
    expect x0, 1
    mov x0, #0
    dos 0x2e
    dos 0x54
    expect x0, 0

    step 4                      // 37h switch character
    mov x0, #0
    dos 0x37
    ok
    expect x2, '/'

    step 5                      // 25h / 35h vectors
    mov x0, #0x60
    address x1, efi_main
    dos 0x25
    ok
    mov x0, #0x60
    dos 0x35
    ok
    address x1, efi_main
    cmp x0, x1
    b.ne fail
    mov x0, #0x60
    mov x1, #0
    dos 0x25

    step 6                      // 34h InDOS is clear while a program runs
    dos 0x34
    ok
    cbz x0, fail
    expectb x0, 0, 0

    step 7                      // 51h / 62h return this descriptor
    dos 0x62
    ok
    cmp x0, x28
    b.ne fail
    dos 0x51
    cmp x0, x28
    b.ne fail

    step 8                      // 38h country information
    address x21, buffer
    mov x0, x21
    mov x1, #0
    dos 0x38
    ok
    expect x0, 1
    expectb x21, 2, '$'
    expectb x21, 9, '.'
    mov x0, #0                  // select Germany
    mov x1, #49
    dos 0x38
    ok
    mov x0, x21
    mov x1, #0
    dos 0x38
    expect x0, 49
    expectb x21, 9, ','
    mov x0, #0
    mov x1, #1
    dos 0x38
    mov x0, x21
    mov x1, #999
    dos 0x38
    err 2

    step 9                      // 65h extended country information
    mov x0, #1
    mov x1, #0xffff
    mov x2, #0xffff
    mov x3, x21
    mov x4, #64
    dos 0x65
    ok
    expect x0, 41
    expectb x21, 0, 1
    expectb x21, 3, 1
    mov x0, #0x20
    mov x1, #'a'
    dos 0x65
    expect x0, 'A'
    mov x0, #0x20
    mov x1, #0x81
    dos 0x65
    expect x0, 0x9a
    mov x0, #0x23
    mov x1, #'y'
    dos 0x65
    expect x0, 1
    mov x0, #2
    mov x1, #0xffff
    mov x2, #0xffff
    mov x3, x21
    mov x4, #16
    dos 0x65
    ok
    ldur x0, [x21, #1]
    ldrh w0, [x0]
    expect x0, 128

    step 10                     // 66h code page, 63h DBCS
    mov x0, #1
    dos 0x66
    ok
    expect x2, 437
    mov x0, #2                  // COUNTRY.SYS has US 850, not 865
    mov x1, #850
    dos 0x66
    ok
    mov x0, #1
    dos 0x66
    ok
    expect x2, 850
    mov x0, #2
    mov x1, #865
    dos 0x66
    err 2
    mov x0, #2
    mov x1, #437
    dos 0x66
    ok
    mov x0, #0
    dos 0x63
    ok
    cbz x0, fail

    step 11                     // 58h allocation strategy
    mov x0, #0
    dos 0x58
    expect x0, 0
    mov x0, #1
    mov x1, #2
    dos 0x58
    ok
    mov x0, #0x10000
    dos 0x48
    ok
    mov x22, x0
    mov x0, #1
    mov x1, #0
    dos 0x58
    mov x0, #0x10000
    dos 0x48
    ok
    dos 0x49
    mov x0, x22
    dos 0x49
    ok
    mov x0, #1
    mov x1, #3
    dos 0x58
    err 1

    step 12                     // 1Ch allocation information, 32h DPB
    mov x0, #1
    dos 0x1c
    ok
    expect x2, 512
    cbz x0, fail
    cbz x3, fail
    mov x0, #17                 // Q: is not a drive
    dos 0x1c
    err 15
    mov x0, #0
    dos 0x32
    ok
    mov x22, x0
    expectb x22, 2, 0
    expectb x22, 3, 2
    ldr w9, [x22, #56]
    cmp w9, #12
    b.lo fail
    cmp w9, #32
    b.hi fail

    step 13                     // 52h list of lists, 69h media ID
    dos 0x52
    ok
    ldr x9, [x0, #24]
    cbz x9, fail
    ldr x9, [x0, #8]
    cbz x9, fail
    mov x0, #0
    mov x1, #0
    mov x2, x21
    dos 0x69
    ok
    expectb x21, 0, 0
    expectb x21, 17, 'F'
    expectb x21, 18, 'A'
    expectb x21, 19, 'T'

    step 14                     // NUL device
    address x0, nul_name
    mov x1, #2
    dos 0x3d
    ok
    mov x22, x0
    mov x1, x21
    mov x2, #5
    dos 0x40
    ok
    expect x0, 5
    mov x0, x22
    mov x1, x21
    mov x2, #5
    dos 0x3f
    ok
    expect x0, 0
    mov x0, x22
    mov x1, #0
    dos 0x44
    ok
    expect x0, 0xc4
    mov x0, x22
    dos 0x3e
    ok
    address x0, nul_ext_name    // "\X\NUL.TXT" is still NUL
    mov x1, #1
    dos 0x3d
    ok
    dos 0x3e
    address x0, nul_name
    dos 0x41
    err 5

    step 15                     // CON and CLOCK$ devices, console dup
    address x0, con_name
    mov x1, #1
    dos 0x3d
    ok
    mov x22, x0
    mov x1, #0
    dos 0x44
    expect x0, 0xd3
    mov x0, x22
    dos 0x3e
    address x0, clock_name
    mov x1, #0
    dos 0x3d
    ok
    mov x22, x0
    mov x1, x21
    mov x2, #6
    dos 0x3f
    ok
    expect x0, 6
    ldrh w9, [x21]
    cbz w9, fail                // days since 1980
    mov x0, x22
    dos 0x3e
    mov x0, #1                  // duplicate standard output
    dos 0x45
    ok
    mov x22, x0
    address x1, dup_text
    mov x2, #0
    dos 0x40
    ok
    mov x0, x22
    dos 0x3e
    ok

    step 16                     // 6Ch extended open/create
    address x0, temp_name
    mov x1, #2
    mov x2, #0
    mov x3, #0x10               // create only
    dos 0x6c
    ok
    expect x2, 2
    mov x22, x0
    address x1, sixteen
    mov x2, #16
    dos 0x40
    ok
    mov x0, x22
    dos 0x3e
    address x0, temp_name
    mov x1, #0
    mov x2, #0
    mov x3, #0x10
    dos 0x6c
    err 80                      // exists and the action says fail
    step 17
    address x0, temp_name
    mov x1, #0
    mov x2, #0
    mov x3, #0x01
    dos 0x6c
    ok
    expect x2, 1
    dos 0x3e
    address x0, temp_name
    mov x1, #2
    mov x2, #0
    mov x3, #0x12
    dos 0x6c
    ok
    expect x2, 3
    mov x22, x0
    mov x1, #0
    mov x2, #2
    dos 0x42
    ok
    expect x0, 0
    mov x0, x22
    address x1, sixteen
    mov x2, #16
    dos 0x40
    mov x0, x22
    dos 0x3e

    step 18                     // sharing modes
    address x0, temp_name
    mov x1, #0x20               // read, deny write
    dos 0x3d
    ok
    mov x22, x0
    address x0, temp_name
    mov x1, #0x01               // write: refused
    dos 0x3d
    err 32
    address x0, temp_name
    mov x1, #0x40               // read, deny none: allowed
    dos 0x3d
    ok
    mov x23, x0
    address x0, temp_name
    dos 0x41                    // delete while open: denied
    err 5
    address x0, temp_name
    address x1, temp_name2
    dos 0x56
    err 5
    mov x0, x23
    dos 0x3e
    mov x0, x22
    dos 0x3e
    address x0, temp_name
    mov x1, #0x10               // read, deny all
    dos 0x3d
    ok
    mov x22, x0
    address x0, temp_name
    mov x1, #0
    dos 0x3d
    err 32
    mov x0, x22
    dos 0x3e
    address x0, temp_name
    mov x1, #0x08               // reserved bit
    dos 0x3d
    err 12

    step 19                     // 5Ch record locks
    address x0, temp_name
    mov x1, #2
    dos 0x3d
    ok
    mov x22, x0
    mov x0, #0
    mov x1, x22
    mov x2, #0
    mov x3, #8
    dos 0x5c
    ok
    mov x0, #0
    mov x1, x22
    mov x2, #4
    mov x3, #8
    dos 0x5c
    err 33
    address x0, temp_name
    mov x1, #0
    dos 0x3d
    ok
    mov x23, x0
    mov x1, x21
    mov x2, #4
    dos 0x3f                    // another handle reads a locked region
    err 33
    mov x0, x23
    mov x1, #8
    mov x2, #0
    dos 0x42
    mov x0, x23
    mov x1, x21
    mov x2, #4
    dos 0x3f                    // outside the lock is fine
    ok
    expect x0, 4
    mov x0, #1
    mov x1, x22
    mov x2, #0
    mov x3, #8
    dos 0x5c
    ok
    mov x0, #1
    mov x1, x22
    mov x2, #0
    mov x3, #8
    dos 0x5c
    err 33
    mov x0, x23
    dos 0x3e
    mov x0, x22
    dos 0x3e

    step 20                     // 60h TRUENAME
    address x0, temp_lower
    mov x1, x21
    dos 0x60
    ok
    mov x0, x21
    address x1, temp_true
    bl strcmp
    cbnz x0, fail
    address x0, nul_name
    mov x1, x21
    dos 0x60
    ok
    mov x0, x21
    address x1, nul_true
    bl strcmp
    cbnz x0, fail
    address x0, temp_name
    dos 0x41
    ok

    step 21                     // 5Ah temporary file
    address x0, root_dir
    mov x1, x21
    bl strcpy
    mov x0, x21
    mov x1, #0
    dos 0x5a
    ok
    dos 0x3e
    ok
    ldrb w9, [x21, #1]
    cbz w9, fail
    mov x0, x21
    dos 0x41
    ok

    step 22                     // 29h parse filename
    address x0, parse1
    address x1, fcb
    mov x2, #1
    dos 0x29
    ok
    expect x0, 0
    address x0, fcb
    address x1, fcb_readme
    mov x2, #12
    bl memcmp
    cbnz x0, fail
    address x0, parse2
    address x1, fcb
    mov x2, #0
    dos 0x29
    expect x0, 1
    address x9, fcb
    expectb x9, 1, 'A'
    expectb x9, 2, '?'
    expectb x9, 8, '?'
    expectb x9, 9, 'T'
    expectb x9, 10, '?'
    expectb x9, 11, ' '
    ldrb w9, [x2]
    cmp w9, #' '
    b.ne fail
    address x0, parse3
    address x1, fcb
    mov x2, #0
    dos 0x29
    expect x0, 255

    step 23                     // FCB create, block write/read
    address x0, buffer
    mov x1, #512
    dos 0x1a
    address x0, fcb_create
    address x1, fcb
    mov x2, #37
    bl memcpy
    address x0, fcb
    dos 0x16
    expect x0, 0
    address x9, fcb
    str wzr, [x9, #33]          // random record 0
    address x0, fcb
    mov x1, #2
    dos 0x28
    expect x0, 0
    expect x2, 2
    address x0, fcb
    dos 0x10
    expect x0, 0
    address x0, fcb
    dos 0x0f
    expect x0, 0
    address x9, fcb
    ldr w9, [x9, #16]
    cmp w9, #256
    b.ne fail
    address x9, fcb
    str wzr, [x9, #33]
    address x0, fcb
    mov x1, #2
    dos 0x27
    expect x0, 0
    expect x2, 2
    address x0, fcb
    mov x1, #1
    dos 0x27
    expect x0, 1
    expect x2, 0
    address x9, fcb
    mov w10, #1
    str w10, [x9, #33]
    address x0, fcb
    mov x1, #0
    dos 0x28                    // truncate to one record
    expect x0, 0
    address x0, fcb
    dos 0x10

    step 24                     // FCB search, rename, wildcard delete
    address x0, fcb_search
    dos 0x11
    expect x0, 0
    address x9, buffer
    expectb x9, 0, 1
    expectb x9, 1, 'F'
    expectb x9, 7, 'T'
    expectb x9, 8, ' '
    expectb x9, 9, 'D'
    ldr w10, [x9, #29]
    cmp w10, #128
    b.ne fail
    dos 0x12
    expect x0, 255
    address x0, xfcb_search     // extended FCB result
    dos 0x11
    expect x0, 0
    address x9, buffer
    expectb x9, 0, 0xff
    expectb x9, 7, 1
    expectb x9, 8, 'F'
    address x0, fcb_rename
    dos 0x17
    expect x0, 0
    address x0, fcb_search
    dos 0x11
    expect x0, 255
    address x0, fcb_wild
    dos 0x13
    expect x0, 0
    address x0, fcb_wild
    dos 0x11
    expect x0, 255
    // Drive bytes other than A: (B: is a RAM drive from CONFIG.SYS).
    address x0, parse4
    address x1, fcb
    mov x2, #0
    dos 0x29
    expect x0, 0
    address x9, fcb
    expectb x9, 0, 2
    address x0, fcb_create
    address x1, fcb
    mov x2, #37
    bl memcpy
    address x9, fcb
    mov w10, #2
    strb w10, [x9]
    address x0, fcb
    dos 0x16
    expect x0, 0
    address x0, fcb
    dos 0x10
    address x0, own_on_b        // it is on B:, not A:
    mov x1, #0
    dos 0x3d
    ok
    dos 0x3e
    address x0, fcb_search
    address x1, fcb
    mov x2, #37
    bl memcpy
    address x0, fcb
    mov w10, #2
    strb w10, [x0]
    dos 0x11
    expect x0, 0
    address x9, buffer
    expectb x9, 0, 2
    address x0, fcb_search      // and not on A:
    dos 0x11
    expect x0, 255
    // 17h and 13h with drive byte 2 act on B:, not on A:'s file.
    address x0, own_on_a
    mov x1, #0
    dos 0x3c
    ok
    dos 0x3e
    address x0, fcb_rename_b
    address x1, fcb
    mov x2, #37
    bl memcpy
    address x0, fcb
    dos 0x17
    expect x0, 0
    address x0, renamed_on_b
    mov x1, #0
    dos 0x3d
    ok
    dos 0x3e
    address x0, fcb_search
    address x1, fcb
    mov x2, #37
    bl memcpy
    address x0, fcb
    mov w10, #2
    strb w10, [x0]
    mov w10, #'?'
    strb w10, [x0, #8]          // FCBTEST? ???: the renamed file
    dos 0x13
    expect x0, 0
    address x0, renamed_on_b
    mov x1, #0
    dos 0x3d
    cbz x1, fail
    address x0, own_on_a        // A:'s file is untouched
    dos 0x41
    ok

    step 25                     // 4Bh mode 1 load only
    address x0, own_name
    address x1, empty
    mov x2, #1
    dos 0x4b
    ok
    cbz x0, fail
    cmp x2, x0
    b.ls fail
    add x9, x0, x3
    cmp x2, x9
    b.hs fail
    ldrh w9, [x0]
    mov w10, #0x5a4d            // headers are loaded too
    cmp w9, w10
    b.ne fail
    dos 0x49
    ok

    step 26                     // 5Dh 0Ah sets the extended error
    mov x0, #0x0a
    mov x1, #19
    mov x2, #11
    mov x3, #7
    mov x4, #2
    dos 0x5d
    ok
    dos 0x59
    expect x0, 19
    expect x2, 11
    expect x3, 7
    mov x0, #0
    dos 0x5e
    ok
    expect x2, 0

    step 27                     // IOCTL drive calls
    mov x0, #1
    mov x1, #8
    dos 0x44
    ok
    expect x0, 1
    mov x0, #1
    mov x1, #0x0e
    dos 0x44
    ok
    mov x0, #1
    mov x1, #0x0d
    mov x2, #0x0866
    mov x3, x21
    dos 0x44
    ok
    expectb x21, 17, 'F'
    mov x0, #4                  // PRN: set raw mode
    mov x1, #1
    mov x2, #0x20
    dos 0x44
    ok
    expect x0, 0xe0
    mov x0, #4
    mov x1, #1
    mov x2, #0x100              // DH must be zero
    dos 0x44
    err 1
    step 28                     // 31h stay resident, via a child
    address x0, own_name
    address x1, tsr_arg
    mov x2, #0
    dos 0x4b
    ok
    dos 0x4d
    expect x0, 0x0305

    step 29                     // 67h, 00h unavailable at top level
    mov x0, #20
    dos 0x67
    ok
    mov x0, #64
    dos 0x67
    err 8

    address x0, pass_message
    dos 0x09
    mov x0, #0
    dos 0x4c

mode_tsr:
    mov x0, #5
    mov x1, #4096
    dos 0x31
    b fail
mode_wait:
    address x0, wait_message
    dos 0x09
    dos 0x08
    mov x0, #9
    dos 0x4c
mode_ctrlc:
    step 30
    address x0, own_name
    address x1, wait_arg
    mov x2, #0
    dos 0x4b
    ok
    dos 0x4d
    expect x0, 0x0100
    address x0, ctrlc_message
    dos 0x09
    mov x0, #0
    dos 0x4c

fail:
    address x0, fail_message
    dos 0x09
    mov x0, x27
    mov x9, #10
    udiv x10, x0, x9
    msub x26, x10, x9, x0       // DOS calls may change x0-x17
    cbz x10, 1f
    add x0, x10, #'0'
    dos 0x02
1:
    add x0, x26, #'0'
    dos 0x02
    mov x0, #13
    dos 0x02
    mov x0, #10
    dos 0x02
    mov x0, #1
    dos 0x4c
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

strcmp:
    ldrb w2, [x0], #1
    ldrb w3, [x1], #1
    cmp w2, w3
    b.ne 1f
    cbnz w2, strcmp
    mov x0, #0
    ret
1:
    mov x0, #1
    ret
strcpy:
    ldrb w2, [x0], #1
    strb w2, [x1], #1
    cbnz w2, strcpy
    ret
memcmp:
    cbz x2, 1f
    ldrb w3, [x0], #1
    ldrb w4, [x1], #1
    cmp w3, w4
    b.ne 2f
    sub x2, x2, #1
    b memcmp
1:
    mov x0, #0
    ret
2:
    mov x0, #1
    ret
memcpy:
    cbz x2, 1f
    ldrb w3, [x0], #1
    strb w3, [x1], #1
    sub x2, x2, #1
    b memcpy
1:
    ret

.section .rodata
missing_name: .asciz "\\NOFILE.XYZ"
nul_name: .asciz "nul"
nul_ext_name: .asciz "\\X\\NUL.TXT"
con_name: .asciz "CON"
clock_name: .asciz "CLOCK$"
dup_text: .asciz ""
temp_name: .asciz "\\DOSTEST.TMP"
temp_name2: .asciz "\\DOSTEST.TM2"
temp_lower: .asciz "dostest.tmp"
temp_true: .asciz "A:\\DOSTEST.TMP"
nul_true: .asciz "A:/NUL"
root_dir: .asciz "\\"
sixteen: .ascii "0123456789ABCDEF"
parse1: .asciz "  readme.txt rest"
parse2: .asciz "a*.t? x"
parse3: .asciz "q:FILE"
parse4: .asciz "b:FCBTEST.DAT"
own_on_b: .asciz "B:\\FCBTEST.DAT"
own_on_a: .asciz "A:\\FCBTEST.DAT"
renamed_on_b: .asciz "B:\\FCBTESTB.DAT"
fcb_rename_b: .byte 2
    .ascii "FCBTEST DAT"
    .skip 5
    .ascii "FCBTESTBDAT"
    .skip 9
fcb_readme: .ascii "\0README  TXT"
fcb_create: .byte 0
    .ascii "FCBTEST DAT"
    .skip 25
fcb_search: .byte 0
    .ascii "FCBTEST ???"
    .skip 25
xfcb_search: .byte 0xff, 0, 0, 0, 0, 0, 0
    .byte 0
    .ascii "FCB?????DAT"
    .skip 25
fcb_rename: .byte 0
    .ascii "FCBTEST DAT"
    .skip 4
    .byte 0
    .ascii "FCBNEW  ???"
    .skip 9
fcb_wild: .byte 0
    .ascii "FCB?????DAT"
    .skip 25
own_name: .asciz "\\DOSTEST.EXE"
empty: .asciz ""
tsr_arg: .asciz "tsr"
wait_arg: .asciz "wait"
pass_message: .asciz "DOSTEST PASS\r\n$"
fail_message: .asciz "DOSTEST FAIL $"
wait_message: .asciz "WAIT>$"
ctrlc_message: .asciz "\r\nCTRL-C OK\r\n$"

.section .bss
.balign 16
buffer: .skip 512
fcb: .skip 64
