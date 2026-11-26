// SPDX-License-Identifier: MIT
// ANSI.SYS (v4.0/src/DEV/ANSI): the extended console driver. It takes over
// CON and sees every byte written to the console and every key read from
// it. The terminal on the serial line already draws VT100 sequences, so
// ANSI.SYS passes them through while keeping DOS's meanings:
//   ESC[nA/B/C/D, ESC[r;cH/f   cursor moves (tracked for ESC[6n);
//   ESC[2J                     clears the screen and homes the cursor;
//   ESC[s, ESC[u               save and restore the cursor position;
//   ESC[6n                     device status: ESC[row;colR is typed back;
//   ESC[=7h, ESC[=7l           line wrap on / off (other modes clear);
//   ESC[key;...p               keyboard reassignment: a key code (or a
//                              quoted character) and the codes or quoted
//                              strings it types instead; ESC[keyp resets it;
//   ESC[...m, ESC[K and others go to the terminal unchanged.
// The screen is 80 by 25. Reassigned keys are the ASCII keys the serial
// line delivers (0;n extended codes are accepted and kept, but a serial
// terminal sends no scan codes), and replacement codes 1-255.
.macro address reg, name
    adrp \reg, \name
    add \reg, \reg, :lo12:\name
.endm
.equ ROWS, 25
.equ COLS, 80
.equ MAX_PARAMS, 64
.equ SEQ_MAX, 120
.equ KEYS, 16
.equ KEY_SIZE, 64
.equ KEY_BYTES, 61

.section .text
.global efi_main
// x0 = init request (ABI.md): +72 the UART output and +80 its key poll.
efi_main:
    ldr x1, [x0, #72]
    ldr x2, [x0, #80]
    cbz x1, 9f
    cbz x2, 9f
    address x3, raw_putc
    str x1, [x3]
    address x3, raw_poll
    str x2, [x3]
    address x1, device_name
    ldr x1, [x1]
    str x1, [x0, #16]
    address x1, ansi_read
    str x1, [x0, #24]
    address x1, ansi_write
    str x1, [x0, #32]
    mov x1, #0x93               // character device, special, CON
    str x1, [x0, #40]
    mov x1, #0
    ret
9:
    mov x1, #1
    ret

// x0 = buffer, x1 = count. Returns x0 = count.
ansi_write:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    mov x20, x1
    mov x21, #0
1:
    cmp x21, x20
    b.hs 2f
    ldrb w0, [x19, x21]
    bl ansi_char
    add x21, x21, #1
    b 1b
2:
    mov x0, x20
    ldp x19, x20, [sp, #16]
    ldr x21, [sp, #32]
    ldp x29, x30, [sp], #48
    ret

// x0 = buffer, x1 = count. Non-blocking: returns x0 = 1 with a key in the
// buffer, or 0 when none is waiting.
ansi_read:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    cbz x1, 8f
    bl q_pop
    cbnz x1, 7f
    address x9, raw_poll
    ldr x9, [x9]
    blr x9
    cbz x0, 8f
    mov x20, x0
    bl key_find
    cbz x0, 6f
    ldrb w2, [x0, #2]           // a reassigned key types its replacement
    add x3, x0, #3
    mov x4, #0
1:
    cmp x4, x2
    b.hs 2f
    ldrb w0, [x3, x4]
    bl q_push
    add x4, x4, #1
    b 1b
2:
    bl q_pop
    cbz x1, 8f
    b 7f
6:
    mov x0, x20
7:
    strb w0, [x19]
    mov x0, #1
    b 9f
8:
    mov x0, #0
9:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// w0 = byte written to CON.
ansi_char:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    and w19, w0, #0xff
    address x20, state
    ldr x2, [x20]
    cmp x2, #1
    b.eq 20f
    b.hi 30f
    cmp w19, #27
    b.eq 10f
    mov w0, w19
    bl track
    mov w0, w19
    bl out
    b 99f
10:                             // ESC
    mov x2, #1
    str x2, [x20]
    address x9, seq_len
    str xzr, [x9]
    mov w0, w19
    bl seq_add
    b 99f
20:                             // after ESC
    mov w0, w19
    bl seq_add
    cmp w19, #'['
    b.ne 98f
    mov x2, #2
    str x2, [x20]
    address x9, params_count
    str xzr, [x9]
    address x9, value
    str xzr, [x9]
    address x9, has_value
    str xzr, [x9]
    address x9, in_string
    str xzr, [x9]
    address x9, after_string
    str xzr, [x9]
    address x9, prefix
    str xzr, [x9]
    b 99f
30:                             // in ESC[ ... final
    address x9, seq_len
    ldr x2, [x9]
    cmp x2, #SEQ_MAX
    b.hs 97f
    mov w0, w19
    bl seq_add
    address x9, in_string
    ldr x2, [x9]
    cbz x2, 32f
    address x10, quote
    ldr x3, [x10]
    cmp x19, x3
    b.ne 31f
    str xzr, [x9]
    address x9, after_string
    mov x2, #1
    str x2, [x9]
    b 99f
31:
    mov x0, x19
    bl param_add
    b 99f
32:
    cmp w19, #'"'
    b.eq 33f
    cmp w19, #'\''
    b.ne 34f
33:
    mov x2, #1
    str x2, [x9]
    address x10, quote
    str x19, [x10]
    b 99f
34:
    sub w2, w19, #'0'
    cmp w2, #9
    b.hi 35f
    address x9, value
    ldr x3, [x9]
    mov x4, #10
    madd x3, x3, x4, x2
    mov x4, #0xfffe
    cmp x3, x4
    csel x3, x3, x4, lo
    str x3, [x9]
    address x9, has_value
    mov x2, #1
    str x2, [x9]
    b 99f
35:
    cmp w19, #';'
    b.ne 37f
    bl value_flush
    address x9, after_string
    str xzr, [x9]
    b 99f
37:
    cmp w19, #'='
    b.eq 38f
    cmp w19, #'?'
    b.ne 39f
38:
    address x9, seq_len
    ldr x2, [x9]
    cmp x2, #3
    b.ne 97f
    address x9, prefix
    str x19, [x9]
    b 99f
39:
    cmp w19, #0x40
    b.lo 97f
    cmp w19, #0x7e
    b.hi 97f
    address x9, has_value
    ldr x2, [x9]
    cbz x2, 40f
    bl value_flush
40:
    str xzr, [x20]
    mov w0, w19
    bl dispatch
    b 99f
97:                             // not a sequence ANSI.SYS knows
    str xzr, [x20]
    bl seq_flush
    b 99f
98:
    str xzr, [x20]
    bl seq_flush
99:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ';' or the final byte: the number typed so far (or "default") becomes a
// parameter, unless a quoted string just ended it.
value_flush:
    address x9, has_value
    ldr x2, [x9]
    str xzr, [x9]
    address x10, value
    ldr x0, [x10]
    str xzr, [x10]
    cbnz x2, param_add
    address x9, after_string
    ldr x2, [x9]
    cbnz x2, 1f
    mov x0, #0xffff
    b param_add
1:
    ret

// x0 = parameter.
param_add:
    address x9, params_count
    ldr x2, [x9]
    cmp x2, #MAX_PARAMS
    b.hs 1f
    address x10, params
    strh w0, [x10, x2, lsl #1]
    add x2, x2, #1
    str x2, [x9]
1:
    ret

// x0 = index, x1 = default. Returns x0 = that parameter.
param:
    address x9, params_count
    ldr x2, [x9]
    cmp x0, x2
    b.hs 1f
    address x10, params
    ldrh w0, [x10, x0, lsl #1]
    mov x2, #0xffff
    cmp x0, x2
    b.eq 1f
    ret
1:
    mov x0, x1
    ret

// w0 = final byte.
dispatch:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov w19, w0
    address x20, row
    address x21, col
    cmp w19, #'A'
    b.ne 2f
    bl count_param
    ldr x2, [x20]
    subs x2, x2, x0
    csel x2, x2, xzr, ge
    str x2, [x20]
    b 90f
2:
    cmp w19, #'B'
    b.ne 3f
    bl count_param
    ldr x2, [x20]
    add x2, x2, x0
    mov x3, #ROWS - 1
    cmp x2, x3
    csel x2, x2, x3, lo
    str x2, [x20]
    b 90f
3:
    cmp w19, #'C'
    b.ne 4f
    bl count_param
    ldr x2, [x21]
    add x2, x2, x0
    mov x3, #COLS - 1
    cmp x2, x3
    csel x2, x2, x3, lo
    str x2, [x21]
    b 90f
4:
    cmp w19, #'D'
    b.ne 5f
    bl count_param
    ldr x2, [x21]
    subs x2, x2, x0
    csel x2, x2, xzr, ge
    str x2, [x21]
    b 90f
5:
    cmp w19, #'H'
    b.eq 51f
    cmp w19, #'f'
    b.ne 6f
51:
    mov x0, #0
    mov x1, #1
    bl param
    mov x1, #ROWS
    bl clamp
    sub x0, x0, #1
    str x0, [x20]
    mov x0, #1
    mov x1, #1
    bl param
    mov x1, #COLS
    bl clamp
    sub x0, x0, #1
    str x0, [x21]
    b 90f
6:
    cmp w19, #'J'
    b.ne 7f
    bl seq_flush
    address x0, home
    bl out_string
    str xzr, [x20]
    str xzr, [x21]
    b 99f
7:
    cmp w19, #'s'
    b.ne 8f
    ldr x2, [x20]
    address x9, saved_row
    str x2, [x9]
    ldr x2, [x21]
    address x9, saved_col
    str x2, [x9]
    address x0, save_cursor
    bl out_string
    b 99f
8:
    cmp w19, #'u'
    b.ne 9f
    address x9, saved_row
    ldr x2, [x9]
    str x2, [x20]
    address x9, saved_col
    ldr x2, [x9]
    str x2, [x21]
    address x0, restore_cursor
    bl out_string
    b 99f
9:
    cmp w19, #'n'
    b.ne 10f
    mov x0, #0
    mov x1, #0
    bl param
    cmp x0, #6
    b.ne 99f
    mov x0, #27                 // ESC[row;colR, as if typed
    bl q_push
    mov x0, #'['
    bl q_push
    ldr x0, [x20]
    add x0, x0, #1
    bl q_number
    mov x0, #';'
    bl q_push
    ldr x0, [x21]
    add x0, x0, #1
    bl q_number
    mov x0, #'R'
    bl q_push
    b 99f
10:
    cmp w19, #'h'
    b.eq 101f
    cmp w19, #'l'
    b.ne 11f
101:
    address x9, prefix
    ldr x2, [x9]
    cbz x2, 90f
    mov x0, #0
    mov x1, #0
    bl param
    cmp x0, #7
    b.ne 102f
    cmp w19, #'h'
    cset x2, eq
    address x9, wrap
    str x2, [x9]
    address x0, wrap_on
    address x1, wrap_off
    csel x0, x0, x1, eq
    bl out_string
    b 99f
102:
    cmp w19, #'h'               // a new screen mode starts cleared
    b.ne 99f
    address x0, clear_home
    bl out_string
    str xzr, [x20]
    str xzr, [x21]
    b 99f
11:
    cmp w19, #'p'
    b.ne 90f
    bl key_assign
    b 99f
90:
    bl seq_flush
99:
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x29, x30, [sp], #48
    ret

// Returns x0 = the first parameter as a count (at least 1).
count_param:
    stp x29, x30, [sp, #-16]!
    mov x0, #0
    mov x1, #1
    bl param
    cmp x0, #0
    mov x1, #1
    csel x0, x1, x0, eq
    ldp x29, x30, [sp], #16
    ret

// x0 = value, x1 = maximum. Returns x0 in 1..x1.
clamp:
    cmp x0, #1
    b.hs 1f
    mov x0, #1
1:
    cmp x0, x1
    csel x0, x0, x1, ls
    ret

// ESC[key;replacement...p
key_assign:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #-16]!
    address x9, params_count
    ldr x20, [x9]
    cbz x20, 9f
    address x10, params
    ldrh w19, [x10]             // key
    mov x2, #1
    mov x3, #0xffff
    cmp x19, x3
    b.eq 9f
    cbnz x19, 1f
    cmp x20, #2                 // 0;n: an extended key
    b.lo 9f
    ldrh w19, [x10, #2]
    add x19, x19, #0x100
    mov x2, #2
1:
    sub x20, x20, x2            // replacement length
    address x21, params
    add x21, x21, x2, lsl #1
    mov x0, x19
    bl key_find
    cbnz x0, 2f
    cbz x20, 9f
    address x0, keymap          // a free entry
    mov x3, #0
11:
    ldrh w4, [x0]
    cbz w4, 2f
    add x0, x0, #KEY_SIZE
    add x3, x3, #1
    cmp x3, #KEYS
    b.lo 11b
    b 9f
2:
    cbnz x20, 3f
    strh wzr, [x0]              // ESC[keyp: back to itself
    b 9f
3:
    mov x3, #KEY_BYTES
    cmp x20, x3
    csel x20, x20, x3, lo
    strh w19, [x0]
    strb w20, [x0, #2]
    mov x3, #0
4:
    cmp x3, x20
    b.hs 9f
    ldrh w4, [x21, x3, lsl #1]
    add x5, x0, x3
    strb w4, [x5, #3]
    add x3, x3, #1
    b 4b
9:
    ldr x21, [sp], #16
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// x0 = key. Returns x0 = its keymap entry, or 0.
key_find:
    cbz x0, 2f
    address x9, keymap
    mov x10, #0
1:
    ldrh w11, [x9]
    cmp x11, x0
    b.eq 3f
    add x9, x9, #KEY_SIZE
    add x10, x10, #1
    cmp x10, #KEYS
    b.lo 1b
2:
    mov x0, #0
    ret
3:
    mov x0, x9
    ret

// w0 = byte about to be shown: follows the cursor.
track:
    address x9, row
    address x10, col
    ldr x11, [x9]
    ldr x12, [x10]
    cmp w0, #13
    b.ne 1f
    mov x12, #0
    b 8f
1:
    cmp w0, #10
    b.ne 2f
    add x11, x11, #1
    b 8f
2:
    cmp w0, #8
    b.ne 3f
    cbz x12, 8f
    sub x12, x12, #1
    b 8f
3:
    cmp w0, #9
    b.ne 4f
    orr x12, x12, #7
    add x12, x12, #1
    mov x13, #COLS - 1
    cmp x12, x13
    csel x12, x12, x13, lo
    b 8f
4:
    cmp w0, #32
    b.lo 8f
    add x12, x12, #1
    cmp x12, #COLS
    b.lo 8f
    address x13, wrap
    ldr x13, [x13]
    cbz x13, 5f
    mov x12, #0
    add x11, x11, #1
    b 8f
5:
    mov x12, #COLS - 1
8:
    mov x13, #ROWS - 1
    cmp x11, x13
    csel x11, x11, x13, lo
    str x11, [x9]
    str x12, [x10]
    ret

// w0 = byte for the sequence buffer.
seq_add:
    address x9, seq_len
    ldr x10, [x9]
    cmp x10, #127
    b.hs 1f
    address x11, seq_buffer
    strb w0, [x11, x10]
    add x10, x10, #1
    str x10, [x9]
1:
    ret

// Sends the buffered sequence to the terminal unchanged.
seq_flush:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    address x9, seq_len
    ldr x20, [x9]
    str xzr, [x9]
    mov x19, #0
1:
    cmp x19, x20
    b.hs 2f
    address x9, seq_buffer
    ldrb w0, [x9, x19]
    bl out
    add x19, x19, #1
    b 1b
2:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// x0 = ASCIIZ string for the terminal.
out_string:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
1:
    ldrb w0, [x19], #1
    cbz w0, 2f
    bl out
    b 1b
2:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// w0 = byte to the UART.
out:
    address x9, raw_putc
    ldr x9, [x9]
    br x9

// Typed-back keys (the 6n report, reassigned keys).
// x0 = byte.
q_push:
    address x9, q_tail
    ldr x10, [x9]
    address x11, q_head
    ldr x11, [x11]
    add x12, x10, #1
    and x12, x12, #255
    cmp x12, x11
    b.eq 1f                     // full
    address x13, queue
    strb w0, [x13, x10]
    str x12, [x9]
1:
    ret
// Returns x1 = 1 with x0 = byte, or x1 = 0 when empty.
q_pop:
    address x9, q_head
    ldr x10, [x9]
    address x11, q_tail
    ldr x11, [x11]
    cmp x10, x11
    b.eq 1f
    address x13, queue
    ldrb w0, [x13, x10]
    add x10, x10, #1
    and x10, x10, #255
    str x10, [x9]
    mov x1, #1
    ret
1:
    mov x1, #0
    ret
// x0 = number: its decimal digits.
q_number:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    mov x1, #10
    cmp x0, #10
    b.lo 1f
    udiv x2, x0, x1
    msub x3, x2, x1, x0
    str x3, [sp, #16]
    mov x0, x2
    bl q_number
    ldr x0, [sp, #16]
1:
    add x0, x0, #'0'
    bl q_push
    ldp x29, x30, [sp], #32
    ret

.section .rodata
.balign 8
device_name: .ascii "CON\0\0\0\0\0"
home: .asciz "\033[H"
clear_home: .asciz "\033[2J\033[H"
save_cursor: .asciz "\0337"
restore_cursor: .asciz "\0338"
wrap_on: .asciz "\033[?7h"
wrap_off: .asciz "\033[?7l"
.section .data
.balign 8
wrap: .quad 1
.section .bss
.balign 8
raw_putc: .skip 8
raw_poll: .skip 8
state: .skip 8
seq_len: .skip 8
params_count: .skip 8
value: .skip 8
has_value: .skip 8
in_string: .skip 8
after_string: .skip 8
quote: .skip 8
prefix: .skip 8
row: .skip 8
col: .skip 8
saved_row: .skip 8
saved_col: .skip 8
q_head: .skip 8
q_tail: .skip 8
params: .skip MAX_PARAMS * 2
seq_buffer: .skip 128
queue: .skip 256
.balign 8
keymap: .skip KEYS * KEY_SIZE
