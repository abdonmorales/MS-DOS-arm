// SPDX-License-Identifier: MIT
// Raw, polled UART output for boot checkpoints and fault dumps: no stack,
// no firmware, no console driver, only the transmit register of a UART the
// firmware has already set up (baud rate, GPIO 14/15 pin function). Shared
// by the kernel's debug output (src/debug.S) and the QEMU raspi3b test
// (tests/pi/sdtest.S), so the same code is checked on both UART models.
//
// Every routine takes x0 = UART base, x1 = type (0 PL011 / SBSA, 1 BCM2835
// mini UART at AUX+40h, 8250-style 32-bit registers).

.section .text

// x2 = NUL-terminated string. Clobbers x2-x4.
dbg_uart_puts:
1:
    ldrb w3, [x2], #1
    cbz w3, 9f
    cbnz x1, 3f
2:
    ldr w4, [x0, #0x18]         // PL011 UARTFR
    tbnz w4, #5, 2b             // TXFF: transmit FIFO full
    str w3, [x0]                // UARTDR
    b 1b
3:
    ldr w4, [x0, #0x14]         // AUX_MU_LSR
    tbz w4, #5, 3b              // transmitter can take a byte
    str w3, [x0]                // AUX_MU_IO
    b 1b
9:
    ret

// x2 = value, printed as 16 lowercase hex digits. Clobbers x2-x6.
dbg_uart_hex:
    mov x5, x2
    mov x6, #60
1:
    lsr x3, x5, x6
    and x3, x3, #15
    cmp x3, #10
    add x4, x3, #'0'
    add x3, x3, #('a' - 10)
    csel x3, x4, x3, lo
    cbnz x1, 3f
2:
    ldr w4, [x0, #0x18]
    tbnz w4, #5, 2b
    str w3, [x0]
    b 4f
3:
    ldr w4, [x0, #0x14]
    tbz w4, #5, 3b
    str w3, [x0]
4:
    subs x6, x6, #4
    b.pl 1b
    ret
