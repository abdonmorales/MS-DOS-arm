// SPDX-License-Identifier: MIT
// SD Host Controller (SDHCI 2.0/3.0) driver for the Raspberry Pi 3's Arasan
// EMMC controller at 0x3F300000: card initialisation, then single-block PIO
// reads and writes. The BCM2835 wrapper only takes 32-bit register writes,
// so every access here is a 32-bit read-modify-write. One data line and a
// clock of at most 25 MHz keep it simple and within every card's limits.
// Shared by the kernel (platform.S) and the QEMU raspi3b test (tests/pi).
// Uses x0-x15 only; no stack.
.equ SD_BLOCK_CNT, 0x04
.equ SD_ARG1, 0x08
.equ SD_CMD_TM, 0x0c
.equ SD_RESP0, 0x10
.equ SD_DATA, 0x20
.equ SD_STATUS, 0x24
.equ SD_CONTROL0, 0x28
.equ SD_CONTROL1, 0x2c
.equ SD_INTERRUPT, 0x30
.equ SD_IRPT_MASK, 0x34
.equ SD_IRPT_EN, 0x38
.equ SD_CAPS, 0x40
.equ SD_VERSION, 0xfc
.equ SD_INT_CMD_DONE, 1
.equ SD_INT_DATA_DONE, 2
.equ SD_INT_WRITE_READY, 0x10
.equ SD_INT_READ_READY, 0x20
.equ SD_INT_ERROR, 0x8000
// Command register flags (bits 16-21 of SD_CMD_TM).
.equ SD_R_NONE, 0
.equ SD_R2, 0x09                // 136 bits, CRC
.equ SD_R3, 0x02                // 48 bits, no CRC
.equ SD_R1, 0x1a                // 48 bits, CRC, index
.equ SD_R1B, 0x1b               // ... and busy
.equ SD_DATA_PRESENT, 0x20
.equ SD_ASSUMED_BASE, 250000000 // when the capabilities give no clock
.equ SD_POLL, 0x2000000

.section .text

// x0 = controller base. Returns x0 = 0 when a card is ready, or the step
// that failed (1 reset, 2 clock, 3 CMD0, 4 ACMD41, 5 CMD2/3, 6 CMD7, 7 CMD16,
// 8 data clock).
sd_init:
    mov x15, x30
    address x9, sd_base
    str x0, [x9]
    mov x10, x0
    ldr w1, [x10, #SD_CONTROL1] // reset the whole controller
    orr w1, w1, #(1 << 24)
    str w1, [x10, #SD_CONTROL1]
    mov x2, #SD_POLL
1:
    ldr w1, [x10, #SD_CONTROL1]
    tst w1, #(7 << 24)
    b.eq 2f
    subs x2, x2, #1
    b.ne 1b
    mov x0, #1
    br x15
2:
    mov w1, #0x0f00             // 3.3 V bus power
    str w1, [x10, #SD_CONTROL0]
    movz x0, #(400000 & 0xffff) // identification clock
    movk x0, #(400000 >> 16), lsl #16
    bl sd_clock
    cbz x0, 3f
    mov x0, #2
    br x15
3:
    mov w1, #-1
    str w1, [x10, #SD_IRPT_MASK] // every status bit visible, no interrupts
    str wzr, [x10, #SD_IRPT_EN]
    str w1, [x10, #SD_INTERRUPT]
    mov x0, #0x20000
4:
    subs x0, x0, #1             // let the card power up (74+ clocks)
    b.ne 4b
    mov x0, #0                  // CMD0: idle
    mov x1, #0
    mov x2, #SD_R_NONE
    bl sd_command
    cbz x0, 5f
    mov x0, #3
    br x15
5:
    mov x0, #8                  // CMD8: 2.7-3.6 V, check pattern AAh
    mov x1, #0x1aa
    mov x2, #SD_R1
    bl sd_command
    mov x13, #0                 // HCS: only for version 2 cards
    cbnz x0, 6f
    and w1, w1, #0xfff
    cmp w1, #0x1aa
    b.ne 6f
    mov x13, #(1 << 30)
6:
    mov x14, #2000              // ACMD41 until the card is no longer busy
7:
    mov x0, #55
    mov x1, #0
    mov x2, #SD_R1
    bl sd_command
    cbnz x0, 8f
    mov x0, #41
    mov x1, #0xff8000           // 2.7-3.6 V
    orr x1, x1, x13
    mov x2, #SD_R3
    bl sd_command
    cbnz x0, 8f
    tbnz w1, #31, 9f
    mov x0, #0x10000
71:
    subs x0, x0, #1
    b.ne 71b
    subs x14, x14, #1
    b.ne 7b
8:
    mov x0, #4
    br x15
9:
    ubfx x1, x1, #30, #1        // CCS: block-addressed (SDHC/SDXC)
    address x9, sd_block_addressing
    str x1, [x9]
    mov x0, #2                  // CMD2: CID
    mov x1, #0
    mov x2, #SD_R2
    bl sd_command
    cbnz x0, 10f
    mov x0, #3                  // CMD3: relative card address
    mov x1, #0
    mov x2, #SD_R1
    bl sd_command
    cbz x0, 11f
10:
    mov x0, #5
    br x15
11:
    lsr w1, w1, #16
    lsl w1, w1, #16
    address x9, sd_rca
    str x1, [x9]
    mov x0, #7                  // CMD7: select
    mov x2, #SD_R1B
    bl sd_command
    cbz x0, 12f
    mov x0, #6
    br x15
12:
    mov x0, #16                 // CMD16: 512-byte blocks
    mov x1, #512
    mov x2, #SD_R1
    bl sd_command
    cbz x0, 13f
    mov x0, #7
    br x15
13:
    movz x0, #(25000000 & 0xffff)
    movk x0, #(25000000 >> 16), lsl #16
    bl sd_clock
    cbz x0, 14f
    mov x0, #8
    br x15
14:
    mov x0, #0
    br x15

// x0 = wanted SD clock in Hz: programs the divider for at most that, from
// the base clock in the capabilities. Returns x0 = 0, or 1 if it never
// became stable.
sd_clock:
    address x9, sd_base
    ldr x10, [x9]
    ldr w1, [x10, #SD_CONTROL1] // clock off first
    bic w1, w1, #4
    str w1, [x10, #SD_CONTROL1]
    ldr w2, [x10, #SD_CAPS]
    ubfx w2, w2, #8, #8         // base clock in MHz (SDHCI 3.0 uses 8 bits)
    movz x3, #(1000000 & 0xffff)
    movk x3, #(1000000 >> 16), lsl #16
    mul x2, x2, x3
    cbnz x2, 1f
    movz x2, #(SD_ASSUMED_BASE & 0xffff)
    movk x2, #(SD_ASSUMED_BASE >> 16), lsl #16
1:
    ldr w4, [x10, #SD_VERSION]
    ubfx w4, w4, #16, #8        // specification version: 2 means 3.00
    cmp w4, #2
    b.lo 3f
    // SDHCI 3.0: 10-bit divider N, clock = base / (2N).
    add x5, x0, x0
    add x6, x2, x5
    sub x6, x6, #1
    udiv x6, x6, x5             // N = ceil(base / (2 * wanted))
    mov x7, #0x3ff
    cmp x6, x7
    csel x6, x6, x7, ls
    and x7, x6, #0xff
    lsl w8, w7, #8
    ubfx x7, x6, #8, #2
    orr w8, w8, w7, lsl #6
    b 4f
3:
    // SDHCI 2.0: power-of-two divider 2^k (k = 0..8), field = 2^(k-1).
    mov x6, #1
31:
    udiv x7, x2, x6
    cmp x7, x0
    b.ls 32f
    lsl x6, x6, #1
    cmp x6, #256
    b.lo 31b
32:
    lsr x6, x6, #1
    lsl w8, w6, #8
4:
    ldr w1, [x10, #SD_CONTROL1]
    mov w3, #0xffff
    bic w1, w1, w3
    bic w1, w1, #(0xf << 16)
    orr w1, w1, #(0xe << 16)    // data timeout: the longest
    orr w1, w1, w8
    orr w1, w1, #1              // internal clock on
    str w1, [x10, #SD_CONTROL1]
    mov x2, #SD_POLL
5:
    ldr w1, [x10, #SD_CONTROL1]
    tbnz w1, #1, 6f             // stable
    subs x2, x2, #1
    b.ne 5b
    mov x0, #1
    ret
6:
    orr w1, w1, #4              // SD clock on
    str w1, [x10, #SD_CONTROL1]
    mov x0, #0x10000
7:
    subs x0, x0, #1
    b.ne 7b
    ret

// x0 = command index, x1 = argument, x2 = response flags (with
// SD_DATA_PRESENT and transfer mode bits 0-15 for data commands).
// Returns x0 = 0 with x1 = response word 0, or x0 = 1 on an error/timeout.
sd_command:
    address x9, sd_base
    ldr x10, [x9]
    mov x3, #SD_POLL
1:
    ldr w4, [x10, #SD_STATUS]   // command (and data) lines free
    tst w4, #3
    b.eq 2f
    subs x3, x3, #1
    b.ne 1b
    b 9f
2:
    mov w4, #-1
    str w4, [x10, #SD_INTERRUPT]
    str w1, [x10, #SD_ARG1]
    lsl w4, w0, #24
    orr w4, w4, w2, lsl #16
    str w4, [x10, #SD_CMD_TM]
    mov x3, #SD_POLL
3:
    ldr w4, [x10, #SD_INTERRUPT]
    tst w4, #SD_INT_ERROR
    b.ne 8f
    tbnz w4, #0, 4f
    subs x3, x3, #1
    b.ne 3b
    b 8f
4:
    mov w5, #SD_INT_CMD_DONE
    str w5, [x10, #SD_INTERRUPT]
    and x5, x2, #3
    cmp x5, #3                  // R1b: wait for the busy signal to end
    b.ne 6f
    mov x3, #SD_POLL
5:
    ldr w4, [x10, #SD_INTERRUPT]
    tbnz w4, #1, 51f
    ldr w4, [x10, #SD_STATUS]
    tbz w4, #20, 51f            // DAT0 high: not busy
    subs x3, x3, #1
    b.ne 5b
51:
    mov w5, #SD_INT_DATA_DONE
    str w5, [x10, #SD_INTERRUPT]
6:
    ldr w1, [x10, #SD_RESP0]
    mov x0, #0
    ret
8:
    // A failed command leaves the CMD (and DAT) circuits to be reset.
    ldr w4, [x10, #SD_CONTROL1]
    orr w4, w4, #(6 << 24)
    str w4, [x10, #SD_CONTROL1]
    mov x3, #SD_POLL
81:
    ldr w4, [x10, #SD_CONTROL1]
    tst w4, #(6 << 24)
    b.eq 9f
    subs x3, x3, #1
    b.ne 81b
9:
    mov w4, #-1
    str w4, [x10, #SD_INTERRUPT]
    mov x0, #1
    ret

// x0 = card sector, x1 = 512-byte buffer (4-byte aligned), x2 = 0 read /
// 1 write. Returns x0 = 0 or 1 on an error.
sd_block:
    mov x12, x30
    mov x11, x1
    mov x13, x2
    address x9, sd_block_addressing
    ldr x3, [x9]
    cbnz x3, 1f
    lsl x0, x0, #9              // standard capacity: byte addresses
1:
    address x9, sd_base
    ldr x10, [x9]
    movz w3, #512
    movk w3, #1, lsl #16        // one block of 512 bytes
    str w3, [x10, #SD_BLOCK_CNT]
    mov x1, x0
    mov x0, #17                 // READ_SINGLE_BLOCK
    cbz x13, 2f
    mov x0, #24                 // WRITE_BLOCK
2:
    mov x2, #(SD_R1 | SD_DATA_PRESENT)
    bl sd_command_data
    cbnz x0, 9f
    mov x3, #SD_POLL
    mov w5, #SD_INT_READ_READY
    cbz x13, 4f
    mov w5, #SD_INT_WRITE_READY
4:
    ldr w4, [x10, #SD_INTERRUPT]
    tst w4, #SD_INT_ERROR
    b.ne 8f
    tst w4, w5
    b.ne 5f
    subs x3, x3, #1
    b.ne 4b
    b 8f
5:
    str w5, [x10, #SD_INTERRUPT]
    mov x6, #0
6:
    cbnz x13, 61f
    ldr w7, [x10, #SD_DATA]
    str w7, [x11, x6]
    b 62f
61:
    ldr w7, [x11, x6]
    str w7, [x10, #SD_DATA]
62:
    add x6, x6, #4
    cmp x6, #512
    b.lo 6b
    mov x3, #SD_POLL
7:
    ldr w4, [x10, #SD_INTERRUPT]
    tst w4, #SD_INT_ERROR
    b.ne 8f
    tbnz w4, #1, 71f
    subs x3, x3, #1
    b.ne 7b
    b 8f
71:
    mov w4, #-1
    str w4, [x10, #SD_INTERRUPT]
    mov x0, #0
    br x12
8:
    mov w4, #-1
    str w4, [x10, #SD_INTERRUPT]
9:
    mov x0, #1
    br x12

// A data command: x0 = index, x1 = argument, x2 = response flags, x13 =
// 0 to read (card to host) or 1 to write. Single block, no DMA. Returns as
// sd_command.
sd_command_data:
    cmp x13, #0
    lsl x2, x2, #16
    mov x4, #0x10               // transfer mode: read
    csel x4, x4, xzr, eq
    orr x2, x2, x4
    address x9, sd_base
    ldr x10, [x9]
    mov x3, #SD_POLL
1:
    ldr w4, [x10, #SD_STATUS]
    tst w4, #3
    b.eq 2f
    subs x3, x3, #1
    b.ne 1b
    b 9f
2:
    mov w4, #-1
    str w4, [x10, #SD_INTERRUPT]
    str w1, [x10, #SD_ARG1]
    lsl w4, w0, #24
    orr w4, w4, w2
    str w4, [x10, #SD_CMD_TM]
    mov x3, #SD_POLL
3:
    ldr w4, [x10, #SD_INTERRUPT]
    tst w4, #SD_INT_ERROR
    b.ne 8f
    tbnz w4, #0, 4f
    subs x3, x3, #1
    b.ne 3b
    b 8f
4:
    mov w5, #SD_INT_CMD_DONE
    str w5, [x10, #SD_INTERRUPT]
    ldr w1, [x10, #SD_RESP0]
    mov x0, #0
    ret
8:
    mov w4, #-1
    str w4, [x10, #SD_INTERRUPT]
9:
    mov x0, #1
    ret

// x0 = partition-relative LBA, x1 = count, x2 = buffer, x3 = 0 read /
// 1 write (as vio_rw). Returns x0 = 0, or 1 on a device error.
sd_rw:
    mov x14, x30
    address x9, sd_part_lba
    ldr x9, [x9]
    add x0, x0, x9
    mov x15, x0
    address x9, sd_count
    str x1, [x9]
    address x9, sd_buffer_ptr
    str x2, [x9]
    address x9, sd_write
    str x3, [x9]
1:
    address x9, sd_count
    ldr x1, [x9]
    cbz x1, 8f
    mov x0, x15
    address x9, sd_buffer_ptr
    ldr x1, [x9]
    address x9, sd_write
    ldr x2, [x9]
    bl sd_block
    cbnz x0, 9f
    add x15, x15, #1
    address x9, sd_buffer_ptr
    ldr x1, [x9]
    add x1, x1, #512
    str x1, [x9]
    address x9, sd_count
    ldr x1, [x9]
    sub x1, x1, #1
    str x1, [x9]
    b 1b
8:
    mov x0, #0
9:
    br x14

.section .bss
.balign 8
sd_base: .skip 8
sd_rca: .skip 8
sd_block_addressing: .skip 8
sd_part_lba: .skip 8
sd_count: .skip 8
sd_buffer_ptr: .skip 8
sd_write: .skip 8
.section .text
