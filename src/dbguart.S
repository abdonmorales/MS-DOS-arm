// SPDX-License-Identifier: MIT
// Raw, polled UART output for boot checkpoints and fault dumps: no stack,
// no firmware, no console driver, only the transmit register of a UART the
// firmware has already set up (baud rate, GPIO 14/15 pin function). Shared
// by the kernel's debug output (src/debug.S) and the QEMU raspi3b test
// (tests/pi/sdtest.S), so the same code is checked on both UART models.
//
// Every routine takes x0 = UART base, x1 = type, as plat_uart_type: 0 PL011
// / SBSA; 1 BCM2835 mini UART at AUX+40h or a 16550 with 32-bit registers
// at stride 4; 2 16550 with byte registers at stride 1; 3 byte registers
// at stride 4.

.section .text

// x2 = NUL-terminated string. Clobbers x2-x4, x7, x8.
dbg_uart_puts:
    mov x8, x30
1:
    ldrb w3, [x2], #1
    cbz w3, 9f
    bl dbg_uart_byte
    b 1b
9:
    br x8

// x2 = value, printed as 16 lowercase hex digits. Clobbers x2-x7, x8.
dbg_uart_hex:
    mov x8, x30
    mov x5, x2
    mov x6, #60
1:
    lsr x3, x5, x6
    and x3, x3, #15
    cmp x3, #10
    add x4, x3, #'0'
    add x3, x3, #('a' - 10)
    csel x3, x4, x3, lo
    bl dbg_uart_byte
    subs x6, x6, #4
    b.pl 1b
    br x8

// w3 = byte. Clobbers x4, x7. Each wait for transmit space is bounded
// (about 2^20 status reads): a stuck or misconfigured UART drops the byte
// instead of hanging a checkpoint or a fault dump.
dbg_uart_byte:
    mov x7, #(1 << 20)
    cbnz x1, 3f
2:
    ldr w4, [x0, #0x18]         // PL011 UARTFR
    tbz w4, #5, 21f             // TXFF clear: room in the transmit FIFO
    subs x7, x7, #1
    b.ne 2b
    ret
21:
    str w3, [x0]                // UARTDR
    ret
3:
    cmp x1, #1
    b.ne 5f
4:
    ldr w4, [x0, #0x14]         // LSR (AUX_MU_LSR on the mini UART)
    tbnz w4, #5, 41f            // transmitter can take a byte
    subs x7, x7, #1
    b.ne 4b
    ret
41:
    str w3, [x0]
    ret
5:
    cmp x1, #2
    b.ne 7f
6:
    ldrb w4, [x0, #5]
    tbnz w4, #5, 61f
    subs x7, x7, #1
    b.ne 6b
    ret
61:
    strb w3, [x0]
    ret
7:
    ldrb w4, [x0, #0x14]
    tbnz w4, #5, 71f
    subs x7, x7, #1
    b.ne 7b
    ret
71:
    strb w3, [x0]
    ret
