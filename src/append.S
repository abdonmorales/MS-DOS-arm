// SPDX-License-Identifier: MIT
// APPEND support (MS-DOS 4.0 src/CMD/APPEND): when a program opens a data file
// that is not found, the directories in the APPEND list are tried in turn.
// APPEND.EXE edits `append_state`, which 52h publishes at +112:
//   +0 flags: bit 0 a list is set, 1 /X:ON (search-first and exec too),
//      2 /PATH:ON (names with a drive or directory are retried too),
//      3 /E (the list is the APPEND environment variable);
//   +8 the list, "dir;dir;..." (NUL-terminated, 247 bytes).
.equ APPEND_ON, 1
.equ APPEND_X, 2
.equ APPEND_PATH, 4
.equ APPEND_ENV, 8
.section .text

// 3Dh with APPEND.
dos_open_append:
    address x9, dos_open
    b append_retry

// 6Ch with APPEND.
dos_extended_open_append:
    address x9, dos_extended_open
    b append_retry

// 4Eh with APPEND /X:ON.
dos_find_first_append:
    address x9, dos_find_first
    address x10, append_state
    ldr x10, [x10]
    tbz x10, #1, 1f
    b append_retry
1:
    br x9

// 4Bh with APPEND /X:ON.
dos_exec_append:
    address x9, dos_exec_call
    address x10, append_state
    ldr x10, [x10]
    tbz x10, #1, 1f
    b append_retry
1:
    br x9

// x9 = function taking a path in x0 (other arguments in x1-x5). Calls it;
// on "file/path not found" calls it again for each APPEND directory.
append_retry:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x1, x2, [sp, #-16]!
    stp x3, x4, [sp, #-16]!
    stp x5, x9, [sp, #-16]!
    mov x19, x0
    blr x9
    cbz x1, append_done
    cmp x0, #2
    b.eq 1f
    cmp x0, #3
    b.eq 1f
    cmp x0, #18                 // search-first: no match
    b.ne append_done
1:
    mov x20, x0                 // the original error
    address x21, append_state
    ldr x22, [x21]
    mov x2, #(APPEND_ON | APPEND_ENV)
    tst x22, x2
    b.eq append_fail
    // The name: a bare name, or with /PATH:ON the last component of any.
    mov x23, x19
    mov x2, x19
2:
    ldrb w3, [x2], #1
    cbz w3, 3f
    cmp w3, #'\\'
    b.eq 21f
    cmp w3, #'/'
    b.eq 21f
    cmp w3, #':'
    b.ne 2b
21:
    tbz x22, #2, append_fail
    mov x23, x2
    b 2b
3:
    ldrb w3, [x23]
    cbz w3, append_fail
    // The list.
    add x24, x21, #8
    tbz x22, #3, 4f
    address x0, append_variable
    bl env_get
    mov x24, x0
    cbz x24, append_fail
4:
    ldrb w3, [x24]
    cbz w3, append_fail
    cmp w3, #';'
    b.ne 5f
    add x24, x24, #1
    b 4b
5:
    // Build "dir\name" in append_path.
    address x0, append_path
    mov x2, #0
6:
    ldrb w3, [x24]
    cbz w3, 7f
    cmp w3, #';'
    b.eq 7f
    cmp x2, #200
    b.hs 7f
    strb w3, [x0, x2]
    add x2, x2, #1
    add x24, x24, #1
    b 6b
7:
    cbz x2, 4b
    sub x4, x2, #1
    ldrb w4, [x0, x4]
    cmp w4, #'\\'
    b.eq 8f
    cmp w4, #':'
    b.eq 8f
    mov w4, #'\\'
    strb w4, [x0, x2]
    add x2, x2, #1
8:
    mov x5, x23
81:
    ldrb w4, [x5], #1
    strb w4, [x0, x2]
    add x2, x2, #1
    cbz w4, 9f
    cmp x2, #255
    b.lo 81b
    strb wzr, [x0, x2]
9:
    ldp x1, x2, [sp, #32]
    ldp x3, x4, [sp, #16]
    ldp x5, x9, [sp]
    blr x9
    cbz x1, append_done
    b 4b
append_fail:
    mov x0, x20
    mov x1, #1
append_done:
    add sp, sp, #48
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

.section .rodata
append_variable: .asciz "APPEND"
.section .data
.balign 8
append_state: .quad APPEND_PATH
    .skip 248
.section .bss
append_path: .skip 264
.section .text
