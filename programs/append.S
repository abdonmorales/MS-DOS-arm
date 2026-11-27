// SPDX-License-Identifier: MIT
// APPEND [d:]path[;[d:]path...] | APPEND ; | APPEND [/X[:ON|:OFF]]
// [/PATH:ON|/PATH:OFF] [/E] (v4.0/src/CMD/APPEND): the directories searched
// for data files that are not found. /X:ON extends it to search-first and
// exec, /PATH:OFF limits it to names without a drive or directory, /E keeps
// the list in the APPEND environment variable. The state lives in the
// kernel (52h +112), so it outlasts this program as the TSR's did.
.include "lib.inc"
.equ APPEND_ON, 1
.equ APPEND_X, 2
.equ APPEND_PATH, 4
.equ APPEND_ENV, 8

main:
    enter
    mov x19, x0
    dos 0x52
    ldr x20, [x0, #112]         // the kernel's APPEND state
    ldr x2, [x0, #120]
    address x9, env_capacity
    str x2, [x9]
    ldr x21, [x20]              // flags
    mov x22, #0                 // a list was given
    mov x23, #0                 // anything was given
1:
    mov x0, x19
    bl skip_blanks
    mov x19, x0
    ldrb w2, [x19]
    cbz w2, 5f
    mov x23, #1
    cmp w2, #'/'
    b.eq 3f
    // The list: up to a blank or a switch.
    cbnz x22, bad_parm
    mov x22, #1
    address x24, list
    mov x3, #0
2:
    ldrb w2, [x19]
    cbz w2, 21f
    cmp w2, #' '
    b.eq 21f
    cmp w2, #9
    b.eq 21f
    cmp w2, #'/'
    b.eq 21f
    cmp x3, #246
    b.hs bad_parm
    mov w0, w2
    bl toupper
    strb w0, [x24, x3]
    add x3, x3, #1
    add x19, x19, #1
    b 2b
21:
    strb wzr, [x24, x3]
    b 1b
3:
    // A switch: up to a blank or the next '/'.
    add x19, x19, #1
    address x24, word
    mov x3, #0
31:
    ldrb w2, [x19]
    cbz w2, 32f
    cmp w2, #' '
    b.eq 32f
    cmp w2, #'/'
    b.eq 32f
    cmp x3, #15
    b.hs bad_parm
    mov w0, w2
    bl toupper
    strb w0, [x24, x3]
    add x3, x3, #1
    add x19, x19, #1
    b 31b
32:
    strb wzr, [x24, x3]
    mov x0, x24
    address x1, sw_x
    bl strcmp
    cbz x0, 41f
    mov x0, x24
    address x1, sw_x_on
    bl strcmp
    cbz x0, 41f
    mov x0, x24
    address x1, sw_x_off
    bl strcmp
    cbz x0, 42f
    mov x0, x24
    address x1, sw_path_on
    bl strcmp
    cbz x0, 43f
    mov x0, x24
    address x1, sw_path_off
    bl strcmp
    cbz x0, 44f
    mov x0, x24
    address x1, sw_e
    bl strcmp
    cbz x0, 45f
    b bad_parm
41:
    orr x21, x21, #APPEND_X
    b 1b
42:
    bic x21, x21, #APPEND_X
    b 1b
43:
    orr x21, x21, #APPEND_PATH
    b 1b
44:
    bic x21, x21, #APPEND_PATH
    b 1b
45:
    orr x21, x21, #APPEND_ENV
    b 1b
5:
    cbnz x23, 6f
    // No parameters: the current list.
    bl current_list
    cbz x0, 51f
    mov x24, x0
    say "APPEND="
    mov x0, x24
    bl puts
    bl crlf
    b 9f
51:
    say "No Append\r\n"
    b 9f
6:
    cbz x22, 8f
    address x24, list
    ldrb w2, [x24]
    cmp w2, #';'
    b.ne 7f
    ldrb w2, [x24, #1]
    cbnz w2, 7f
    strb wzr, [x24]             // "APPEND ;" clears the list
7:
    ldrb w2, [x24]
    cbz w2, 71f
    orr x21, x21, #APPEND_ON
    b 72f
71:
    bic x21, x21, #APPEND_ON
72:
    mov x0, x24
    add x1, x20, #8
    bl strcpy
    tbz x21, #3, 8f             // /E: the variable holds the list
    address x0, var_name
    mov x1, x24
    bl set_variable
    cbnz x0, env_full
8:
    str x21, [x20]
9:
    mov x0, #0
    leave
bad_parm:
    say "Invalid parameter\r\n"
    mov x0, #1
    leave
env_full:
    str x21, [x20]
    say "Out of environment space\r\n"
    mov x0, #1
    leave

// Returns x0 = the active list, or 0.
current_list:
    frame
    ldr x2, [x20]
    tbz x2, #3, 1f
    address x0, var_name
    bl getenv
    cbz x0, 2f
    ldrb w2, [x0]
    cbz w2, 2f
    unframe
1:
    tbz x2, #0, 2f
    add x0, x20, #8
    unframe
2:
    mov x0, #0
    unframe

// x0 = name, x1 = value (empty removes). Edits the environment block in
// place. Returns x0 = 0, or 1 when it is full.
set_variable:
    enter
    mov x19, x0
    mov x20, x1
    bl get_environment
    mov x21, x0                 // the block
    // Remove "NAME=..." if present.
    mov x22, x21
1:
    ldrb w2, [x22]
    cbz w2, 4f
    mov x3, x22
    mov x4, x19
2:
    ldrb w5, [x4], #1
    ldrb w6, [x3], #1
    cbz w5, 3f
    cmp w5, w6
    b.eq 2b
    b 31f
3:
    cmp w6, #'='
    b.ne 31f
    // Move everything after this string down over it.
    mov x3, x22
32:
    ldrb w5, [x3], #1
    cbnz w5, 32b
    mov x4, x22
33:
    ldrb w5, [x3]
    cbz w5, 34f
331:
    ldrb w5, [x3], #1
    strb w5, [x4], #1
    cbnz w5, 331b
    b 33b
34:
    strb wzr, [x4]
    b 1b
31:
    ldrb w5, [x22], #1
    cbnz w5, 31b
    b 1b
4:
    // x22 = the terminating empty string.
    ldrb w2, [x20]
    cbz w2, 8f
    mov x0, x19
    bl strlen
    mov x23, x0
    mov x0, x20
    bl strlen
    add x2, x23, x0
    add x2, x2, #3
    sub x3, x22, x21
    add x3, x3, x2
    address x9, env_capacity
    ldr x4, [x9]
    cmp x3, x4
    b.hi 9f
    mov x0, x19
    mov x1, x22
    bl strcpy
    mov w2, #'='
    strb w2, [x0], #1
    mov x1, x0
    mov x0, x20
    bl strcpy
    strb wzr, [x0, #1]
8:
    mov x0, #0
    leave
9:
    mov x0, #1
    leave

.section .rodata
var_name: .asciz "APPEND"
sw_x: .asciz "X"
sw_x_on: .asciz "X:ON"
sw_x_off: .asciz "X:OFF"
sw_path_on: .asciz "PATH:ON"
sw_path_off: .asciz "PATH:OFF"
sw_e: .asciz "E"
.section .bss
.balign 8
env_capacity: .skip 8
word: .skip 16
list: .skip 256
