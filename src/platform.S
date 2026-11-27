// SPDX-License-Identifier: MIT
// Platform layer. UEFI is only the boot loader: once the runtime has found a
// console UART (ACPI SPCR) and the boot disk on virtio-blk (ACPI MCFG + PCI
// ECAM), it reserves its memory, calls ExitBootServices and from then on owns
// the machine: its own exception vectors, polled PL011 console, virtio-blk
// driver, memory arena and program loader. On boards without those drivers it
// stays in firmware mode and uses UEFI services instead.

.equ PLAT_ARENA_BYTES, 0x2000000        // 32 MiB DOS memory arena
.equ PLAT_GRANULE_SHIFT, 16             // 64 KiB arena granules
.equ PLAT_GRANULES, 512
.equ VQ_SIZE, 8
.equ PI_EMMC, 0x3f300000              // BCM2837 Arasan SDHCI

.section .text

// ---------------------------------------------------------------------------
// Console

// w0 = byte.
plat_putc:
    adrp x1, platform_native
    ldr x1, [x1, :lo12:platform_native]
    cbz x1, 2f
    ldv x1, plat_uart
    adrp x2, plat_uart_type
    ldr x2, [x2, :lo12:plat_uart_type]
    cbnz x2, 4f
1:
    ldr w2, [x1, #0x18]         // UARTFR
    tbnz w2, #5, 1b             // TXFF
    and w0, w0, #0xff
    str w0, [x1]
    ret
4:
    cmp x2, #1
    b.ne 8f
41:
    ldr w2, [x1, #0x14]         // 16550 / mini UART LSR: transmitter empty
    tbz w2, #5, 41b
    and w0, w0, #0xff
    str w0, [x1]
    ret
8:
    cmp x2, #2                  // byte registers: LSR at 5 or 5 * 4
    mov x3, #5
    mov x4, #0x14
    csel x3, x3, x4, eq
81:
    ldrb w2, [x1, x3]
    tbz w2, #5, 81b
    strb w0, [x1]
    ret
2:
    // The UEFI console shows ESC as '?', so ANSI sequences (from ANSI.SYS)
    // become ConOut calls: ESC[2J clear, ESC[r;cH/f position, ESC[..m
    // colours. Other sequences are dropped.
    and w0, w0, #0xff
    address x9, fw_esc_state
    ldr x10, [x9]
    cbnz x10, 5f
    cmp w0, #27
    b.ne plat_fw_output
    mov x10, #1
    str x10, [x9]
    str xzr, [x9, #8]           // parameter count
    stp xzr, xzr, [x9, #16]     // parameters
    stp xzr, xzr, [x9, #32]
    ret
5:
    cmp x10, #1
    b.ne 6f
    cmp w0, #'['
    csel x10, xzr, x10, ne      // ESC 7, ESC 8 and the like: dropped
    mov x11, #2
    csel x10, x11, x10, eq
    str x10, [x9]
    ret
6:
    sub w11, w0, #'0'
    cmp w11, #9
    b.hi 7f
    ldr x12, [x9, #8]           // a digit of the current parameter
    cmp x12, #3
    b.hi 61f
    add x13, x9, #16
    ldr x14, [x13, x12, lsl #3]
    mov x15, #10
    madd x14, x14, x15, x11
    str x14, [x13, x12, lsl #3]
61:
    ret
7:
    cmp w0, #';'
    b.ne 71f
    ldr x12, [x9, #8]
    add x12, x12, #1
    str x12, [x9, #8]
    ret
71:
    cmp w0, #'='                // ESC[=7h and ESC[?..: parameters too
    b.eq 61b
    cmp w0, #'?'
    b.eq 61b
    str xzr, [x9]               // the final letter
    address x10, system_table
    ldr x10, [x10]
    ldr x10, [x10, #64]         // ConOut
    cmp w0, #'J'
    b.ne 72f
    ldr x2, [x10, #48]          // ClearScreen
    mov x0, x10
    br x2
72:
    cmp w0, #'H'
    b.eq 73f
    cmp w0, #'f'
    b.ne 74f
73:
    ldp x11, x12, [x9, #16]     // row, column (1-based; 0 means 1)
    subs x11, x11, #1
    csel x11, xzr, x11, lo
    subs x12, x12, #1
    csel x12, xzr, x12, lo
    mov x0, x10
    mov x1, x12
    mov x2, x11
    ldr x3, [x10, #56]          // SetCursorPosition(column, row)
    br x3
74:
    cmp w0, #'m'
    b.ne 79f
    address x11, fw_attribute
    ldr x12, [x11]
    ldr x13, [x9, #8]
    add x13, x13, #1            // parameters given
    mov x14, #0
75:
    add x15, x9, #16
    ldr x15, [x15, x14, lsl #3]
    cbnz x15, 751f
    mov x12, #0x07              // 0: normal
    b 76f
751:
    cmp x15, #1
    b.ne 752f
    orr x12, x12, #0x08         // bold: bright
    b 76f
752:
    sub x16, x15, #30
    cmp x16, #7
    b.hi 753f
    address x17, fw_ansi_colour
    ldrb w16, [x17, x16]
    and x12, x12, #0xf8
    orr x12, x12, x16
    b 76f
753:
    sub x16, x15, #40
    cmp x16, #7
    b.hi 76f
    address x17, fw_ansi_colour
    ldrb w16, [x17, x16]
    bic x12, x12, #0x70
    orr x12, x12, x16, lsl #4
76:
    add x14, x14, #1
    cmp x14, x13
    b.hs 77f
    cmp x14, #4
    b.lo 75b
77:
    str x12, [x11]
    mov x0, x10
    mov x1, x12
    ldr x2, [x10, #40]          // SetAttribute
    br x2
79:
    ret
plat_fw_output:
    frame
    sub sp, sp, #16
    strh w0, [sp]
    strh wzr, [sp, #2]
    mov x1, sp
    address x0, system_table
    ldr x0, [x0]
    ldr x0, [x0, #64]
    ldr x2, [x0, #8]            // ConOut->OutputString
    blr x2
    add sp, sp, #16
    unframe

// Non-blocking. Returns x0 = byte, or 0 when no key is waiting.
plat_poll_key:
    adrp x1, platform_native
    ldr x1, [x1, :lo12:platform_native]
    cbz x1, 2f
    ldv x1, plat_uart
    adrp x2, plat_uart_type
    ldr x2, [x2, :lo12:plat_uart_type]
    cbz x2, 5f
    cmp x2, #1
    b.ne 7f
    ldr w2, [x1, #0x14]         // 16550 / mini UART LSR: data ready
    tbz w2, #0, 1f
    b 6f
7:
    cmp x2, #2                  // byte registers: LSR at 5 or 5 * 4
    mov x3, #5
    mov x4, #0x14
    csel x3, x3, x4, eq
    ldrb w2, [x1, x3]
    tbz w2, #0, 1f
    ldrb w0, [x1]
    b 66f
5:
    ldr w2, [x1, #0x18]
    tbnz w2, #4, 1f             // RXFE
6:
    ldr w0, [x1]
    and w0, w0, #0xff
66:
    cmp w0, #0x7f               // terminals send DEL for backspace
    b.ne 3f
    mov w0, #8
3:
    cbz w0, 1f
    ret
1:
    mov x0, #0
    ret
2:
    frame
    sub sp, sp, #16
4:
    address x0, system_table
    ldr x0, [x0]
    ldr x0, [x0, #48]
    mov x1, sp
    ldr x3, [x0, #8]            // ConIn->ReadKeyStroke
    blr x3
    cbnz x0, 5f
    ldrh w0, [sp, #2]
    cbz w0, 4b                  // scan-only keys have no ASCII form
    add sp, sp, #16
    unframe
5:
    mov x0, #0
    add sp, sp, #16
    unframe

// Blocking. Returns x0 = byte.
plat_read_key:
    frame
1:
    bl plat_poll_key
    cbnz x0, 2f
    yield
    b 1b
2:
    unframe

// Discard type-ahead.
plat_flush_input:
    frame
1:
    bl plat_poll_key
    cbnz x0, 1b
    unframe

plat_clear_screen:
    frame
    address x1, dev_objects     // a CON driver (ANSI.SYS) clears the screen
    ldr x1, [x1, #DEV_DRV_WRITE]
    cbnz x1, 2f
    adrp x1, platform_native
    ldr x1, [x1, :lo12:platform_native]
    cbz x1, 1f
2:
    address x0, plat_cls_sequence
    bl puts
    unframe
1:
    address x0, system_table
    ldr x0, [x0]
    ldr x0, [x0, #64]
    ldr x1, [x0, #48]           // ConOut->ClearScreen
    blr x1
    unframe

// Power off (native) or return status to firmware (caller's job otherwise).
plat_shutdown:
    address x0, system_table
    ldr x0, [x0]
    ldr x0, [x0, #88]           // RuntimeServices stay callable after exit
    ldr x4, [x0, #104]          // ResetSystem
    mov x0, #2                  // EfiResetShutdown
    mov x1, #0
    mov x2, #0
    mov x3, #0
    blr x4
1:
    wfi
    b 1b

// ---------------------------------------------------------------------------
// Memory: 64 KiB granules from one region reserved before ExitBootServices.
// Firmware mode uses AllocatePool.

// x0 = bytes. Returns x0 = pointer or 0. Always at least 4 KiB aligned:
// native programs use ADRP, so images must keep their link-time page offset.
plat_alloc:
    adrp x1, platform_native
    ldr x1, [x1, :lo12:platform_native]
    cbnz x1, 3f
    frame
    mov x1, #0xfff
    add x0, x0, x1
    lsr x0, x0, #12
    bl plat_alloc_pages
    unframe
3:
    mov x1, #0xffff
    add x0, x0, x1
    lsr x0, x0, #PLAT_GRANULE_SHIFT     // granules needed
    cbz x0, 9f
    // Walk the free runs and pick one by the 58h strategy:
    // 0 first fit, 1 best fit (smallest run that fits), 2 last fit.
    address x1, plat_granule_map
    ldv x6, plat_alloc_strategy
    mov x7, #-1                 // chosen start
    mov x8, #-1                 // chosen run length (best fit)
    mov x4, #0
4:
    cmp x4, #PLAT_GRANULES
    b.hs 6f
    ldrh w5, [x1, x4, lsl #1]
    cbz w5, 41f
    add x4, x4, #1
    b 4b
41:
    mov x2, x4                  // run start
42:
    add x4, x4, #1
    cmp x4, #PLAT_GRANULES
    b.hs 43f
    ldrh w5, [x1, x4, lsl #1]
    cbz w5, 42b
43:
    sub x3, x4, x2              // run length
    cmp x3, x0
    b.lo 4b
    cmp x6, #1
    b.eq 44f
    b.hi 45f
    mov x7, x2                  // first fit: take it
    b 6f
44:
    cmp x3, x8
    b.hs 4b
    mov x8, x3
    mov x7, x2
    b 4b
45:
    sub x7, x4, x0              // last fit: top of the highest run
    b 4b
6:
    cmn x7, #1
    b.eq 9f
    mov x2, x7
    add x3, x2, x0
7:
    // Mark the run: first granule holds the count, the rest hold 0xffff.
    strh w0, [x1, x2, lsl #1]
    add x4, x2, #1
    mov w5, #0xffff
8:
    cmp x4, x3
    b.hs 10f
    strh w5, [x1, x4, lsl #1]
    add x4, x4, #1
    b 8b
10:
    ldv x1, plat_arena
    add x0, x1, x2, lsl #PLAT_GRANULE_SHIFT
    ret
9:
    mov x0, #0
    ret

// x0 = pointer from plat_alloc, x1 = bytes requested. Returns x0 = 0 on success.
plat_free:
    adrp x2, platform_native
    ldr x2, [x2, :lo12:platform_native]
    cbnz x2, 2f
    frame
    mov x2, #0xfff
    add x1, x1, x2
    lsr x1, x1, #12
    address x3, boot_services
    ldr x3, [x3]
    ldr x3, [x3, #48]           // FreePages
    blr x3
    unframe
2:
    ldv x1, plat_arena
    subs x2, x0, x1
    b.lo 9f
    tst x2, #0xffff
    b.ne 9f
    lsr x2, x2, #PLAT_GRANULE_SHIFT
    cmp x2, #PLAT_GRANULES
    b.hs 9f
    address x1, plat_granule_map
    ldrh w3, [x1, x2, lsl #1]
    cbz w3, 9f
    mov w4, #0xffff
    cmp w3, w4
    b.eq 9f
    add x3, x2, x3
3:
    strh wzr, [x1, x2, lsl #1]
    add x2, x2, #1
    cmp x2, x3
    b.lo 3b
    mov x0, #0
    ret
9:
    mov x0, #1
    ret

// x0 = start, x1 = length: make freshly written code visible to fetch.
plat_sync_code:
    mrs x2, ctr_el0
    ubfx x3, x2, #16, #4        // DminLine (log2 words)
    mov x4, #4
    lsl x4, x4, x3
    add x1, x0, x1
    sub x5, x4, #1
    bic x0, x0, x5
1:
    dc cvau, x0
    add x0, x0, x4
    cmp x0, x1
    b.lo 1b
    dsb ish
    ic iallu
    dsb ish
    isb
    ret

// ---------------------------------------------------------------------------
// Leaving firmware.

// Returns x0 = 0 when the runtime now owns the machine.
platform_go_native:
    enter
.ifdef ROM_BUILD
    b plat_rom_native
.endif
    ldv x2, fat_mounted         // the native disk path needs the FAT driver
    cbz x2, plat_fail
    ldv x2, fat_bps
    cmp x2, #512
    b.ne plat_fail
    bl plat_find_acpi
    cbnz x0, plat_fail
    ldv x2, plat_uart
    cbz x2, plat_fail
    ldv x2, plat_ecam
    cbnz x2, 11f
    bl plat_pi_check            // no PCI: a Raspberry Pi 3 that opted in?
    cbnz x0, plat_fail
    mov x2, #1
    stv x2, plat_disk_kind, x3
    b 11f
.ifdef ROM_BUILD
// ROM builds: A: is in memory, so leaving firmware takes only a console
// UART (ACPI SPCR, else the device tree's /chosen stdout-path) and memory,
// on any board. It is opt-in: the ROM disk must hold \NATIVE.ON
// (tools/romdisk.py --native); otherwise the firmware keeps the console.
plat_rom_native:
    address x0, plat_pi_marker  // "A:\NATIVE.ON"
    mov x1, #0
    bl dos_open
    cbnz x1, plat_fail
    bl dos_close
    bl plat_find_acpi           // no ACPI is fine: try the device tree
    ldv x2, plat_uart
    cbnz x2, 10f
    bl plat_find_fdt
    cbz x0, plat_fail
    bl plat_fdt_console
    cbz x0, plat_fail
    stv x0, plat_uart, x2
    stv x1, plat_uart_type, x2
10:
    mov x2, #2                  // no disk driver: A: is the ROM disk
    stv x2, plat_disk_kind, x3
.endif
11:
    // Memory the runtime keeps after firmware is gone.
    mov x0, #(PLAT_ARENA_BYTES >> 12)
    bl plat_alloc_pages
    cbz x0, plat_fail
    stv x0, plat_arena, x2
    ldv x2, plat_disk_kind
    cmp x2, #2                  // ROM disk: no disk driver pages
    b.eq 12f
    mov x0, #1
    bl plat_alloc_pages
    cbz x0, plat_fail
    stv x0, vio_queue, x2
    ldv x2, plat_disk_kind
    cbnz x2, 12f
    bl plat_find_disk
    cbnz x0, plat_fail
12:
    bl mmu_reserve              // the kernel's own page tables, if possible
    // ExitBootServices needs the current memory map key; retry once if the
    // map changed between the two calls.
    mov x19, #2
1:
    address x0, plat_map_size
    mov x1, #16384
    str x1, [x0]
    address x1, plat_memory_map
    address x2, plat_map_key
    address x3, plat_desc_size
    address x4, plat_desc_version
    address x5, boot_services
    ldr x5, [x5]
    ldr x5, [x5, #56]           // GetMemoryMap
    blr x5
    cbnz x0, plat_fail
    address x0, image_handle
    ldr x0, [x0]
    ldv x1, plat_map_key
    address x5, boot_services
    ldr x5, [x5]
    ldr x5, [x5, #232]          // ExitBootServices
    blr x5
    cbz x0, 2f
    subs x19, x19, #1
    b.ne 1b
    b plat_fail
2:
    // Firmware is gone. Nothing below may call boot services.
    mov x2, #1
    stv x2, platform_native, x3
    msr daifset, #0xf
    address x0, plat_vectors
    mrs x1, CurrentEL
    cmp x1, #8
    b.eq 3f
    msr vbar_el1, x0
    b 4f
3:
    msr vbar_el2, x0
4:
    isb
    bl mmu_init                 // own tables; drops EL2 to EL1
    ldv x2, plat_disk_kind
    cbnz x2, 5f
    // The firmware's virtio driver reset the device on exit; start ours.
    bl vio_init
    cbnz x0, plat_dead
    mov x0, #0
    leave
5:
    cmp x2, #2                  // ROM disk: nothing to restart
    b.ne 51f
    mov x0, #0
    leave
51:
    // Raspberry Pi 3: the SD card on the Arasan controller, from scratch.
    movz x0, #(PI_EMMC & 0xffff)
    movk x0, #(PI_EMMC >> 16), lsl #16
    bl sd_init
    cbnz x0, plat_dead
    bl plat_pi_partition
    cbnz x0, plat_dead
    mov x0, #0
    leave
plat_fail:
    mov x0, #1
    leave
plat_dead:
    address x0, plat_disk_lost
    bl puts
    b plat_shutdown

// x0 = page count. Returns x0 = address or 0 (EfiLoaderData pages).
plat_alloc_pages:
    frame
    sub sp, sp, #16
    mov x2, x0
    mov x0, #0                  // AllocateAnyPages
    mov x1, #2                  // EfiLoaderData
    mov x3, sp
    address x4, boot_services
    ldr x4, [x4]
    ldr x4, [x4, #40]           // AllocatePages
    blr x4
    mov x1, x0
    ldr x0, [sp]
    add sp, sp, #16
    cbz x1, 1f
    mov x0, #0
1:
    unframe

// x0 = address. Returns x0 = little-endian u64 from unaligned memory.
plat_ld64:
    mov x2, #0
    mov x3, #0
1:
    ldrb w4, [x0, x3]
    lsl x5, x3, #3
    lsl x4, x4, x5
    orr x2, x2, x4
    add x3, x3, #1
    cmp x3, #8
    b.lo 1b
    mov x0, x2
    ret

// Returns x0 = the flattened device tree from the UEFI configuration table,
// or 0.
plat_find_fdt:
    enter
    address x19, system_table
    ldr x19, [x19]
    ldr x20, [x19, #104]        // NumberOfTableEntries
    ldr x21, [x19, #112]        // ConfigurationTable
1:
    cbz x20, 2f
    mov x0, x21
    address x1, fdt_guid
    bl fat_guid_eq
    cbnz x0, 3f
    add x21, x21, #24
    sub x20, x20, #1
    b 1b
2:
    mov x0, #0
    leave
3:
    ldr x0, [x21, #16]
    leave

// Find SPCR (console UART) and MCFG (PCI ECAM) through the ACPI 2.0 tables.
plat_find_acpi:
    enter
    address x19, system_table
    ldr x19, [x19]
    ldr x20, [x19, #104]        // NumberOfTableEntries
    ldr x21, [x19, #112]        // ConfigurationTable
1:
    cbz x20, plat_acpi_fail
    mov x0, x21
    address x1, acpi20_guid
    bl fat_guid_eq
    cbnz x0, 2f
    add x21, x21, #24
    sub x20, x20, #1
    b 1b
2:
    ldr x22, [x21, #16]         // RSDP
    ldr x2, [x22]
    address x3, rsdp_signature
    ldr x3, [x3]
    cmp x2, x3
    b.ne plat_acpi_fail
    ldrb w2, [x22, #15]
    cmp w2, #2
    b.lo plat_acpi_fail
    add x0, x22, #24
    bl plat_ld64
    mov x23, x0                 // XSDT
    ldr w24, [x23, #4]          // length
    mov x25, #36
3:
    add x2, x25, #8
    cmp x2, x24
    b.hi 8f
    add x0, x23, x25
    bl plat_ld64
    mov x26, x0
    ldr w2, [x26]
    mov w3, #0x5053             // "SPCR"
    movk w3, #0x5243, lsl #16
    cmp w2, w3
    b.ne 4f
    ldrb w2, [x26, #40]         // address space: system memory
    cbnz w2, 6f
    ldrb w2, [x26, #36]         // interface: PL011 (3), SBSA generic (0xe)
    cmp w2, #3                  // or the BCM2835 mini UART (10h, Pi 3)
    b.eq 31f
    cmp w2, #0x0e
    b.eq 31f
    cmp w2, #0x10
    b.ne 6f
    add x0, x26, #44
    bl plat_ld64
    tst x0, #0xff               // the AUX block: its UART is at +40h
    b.ne 32f
    add x0, x0, #0x40
32:
    stv x0, plat_uart, x2
    mov x2, #1
    stv x2, plat_uart_type, x3
    b 6f
31:
    add x0, x26, #44
    bl plat_ld64
    stv x0, plat_uart, x2
    b 6f
4:
    mov w3, #0x434d             // "MCFG"
    movk w3, #0x4746, lsl #16
    cmp w2, w3
    b.ne 6f
    ldr w2, [x26, #4]
    cmp w2, #60
    b.lo 6f
    add x0, x26, #44
    bl plat_ld64
    stv x0, plat_ecam, x2
    ldrb w2, [x26, #54]         // start bus
    stv x2, plat_bus_start, x3
    ldrb w2, [x26, #55]         // end bus
    stv x2, plat_bus_end, x3
6:
    add x25, x25, #8
    b 3b
8:
    mov x0, #0
    leave
plat_acpi_fail:
    mov x0, #1
    leave

// ---------------------------------------------------------------------------
// Raspberry Pi 3 (BCM2837): no PCI, the console UART in the peripheral
// window at 3F000000h, and the SD card on the Arasan SDHCI (src/sdhci.S).
// Native mode there has not been validated on a physical board yet, so it
// is used only when the boot volume has \NATIVE.ON; otherwise the Pi stays
// in firmware mode.

// Returns x0 = 0 to run the Pi natively.
plat_pi_check:
    frame
    ldv x0, plat_uart
    lsr x0, x0, #24
    cmp x0, #0x3f
    b.ne 1f
    address x0, plat_pi_marker
    mov x1, #0
    bl dos_open
    cbnz x1, 1f
    bl dos_close
    mov x0, #0
    unframe
1:
    mov x0, #1
    unframe

// Finds the boot volume on the card: sector 0 itself, or the MBR partition
// whose first sector is the boot sector the FAT driver mounted. Returns
// x0 = 0 with sd_part_lba set.
plat_pi_partition:
    enter
    ldv x19, vio_queue          // a page for the probe buffer
    add x19, x19, #2048
    stv x19, vio_buffer, x2
    address x9, sd_part_lba
    str xzr, [x9]
    mov x0, #0
    mov x1, #1
    mov x2, x19
    mov x3, #0
    bl sd_rw
    cbnz x0, 9f
    bl vio_compare_boot
    cbz x0, 8f
    add x20, x19, #512          // keep the MBR
    mov x2, #0
1:
    ldr x3, [x19, x2]
    str x3, [x20, x2]
    add x2, x2, #8
    cmp x2, #512
    b.lo 1b
    mov x21, #0
2:
    mov x2, #16
    mul x2, x21, x2
    add x2, x2, #0x1c6
    add x0, x20, x2
    bl plat_ld32
    mov x22, x0
    cbz x22, 3f
    address x9, sd_part_lba
    str xzr, [x9]
    mov x0, x22
    mov x1, #1
    mov x2, x19
    mov x3, #0
    bl sd_rw
    cbnz x0, 3f
    bl vio_compare_boot
    cbnz x0, 3f
    address x9, sd_part_lba
    str x22, [x9]
    b 8f
3:
    add x21, x21, #1
    cmp x21, #4
    b.lo 2b
9:
    mov x0, #1
    leave
8:
    mov x0, #0
    leave

// x0 = address: little-endian u32 at any alignment.
plat_ld32:
    ldrb w1, [x0]
    ldrb w2, [x0, #1]
    orr w1, w1, w2, lsl #8
    ldrb w2, [x0, #2]
    orr w1, w1, w2, lsl #16
    ldrb w2, [x0, #3]
    orr w0, w1, w2, lsl #24
    ret

// x0 = partition-relative LBA, x1 = count, x2 = buffer, x3 = 0 read /
// 1 write: the native disk, virtio-blk or the Pi's SD card.
plat_disk_rw:
    adrp x9, plat_disk_kind
    ldr x9, [x9, :lo12:plat_disk_kind]
    cbz x9, vio_rw
    b sd_rw

// ---------------------------------------------------------------------------
// PCI and virtio-blk (virtio 1.0 "modern" transport).

// x0 = bus, x1 = device, x2 = function. Returns x0 = ECAM config address.
plat_pci_cfg:
    ldv x3, plat_ecam
    ldv x4, plat_bus_start
    sub x0, x0, x4
    lsl x0, x0, #20
    orr x0, x0, x1, lsl #15
    orr x0, x0, x2, lsl #12
    add x0, x0, x3
    ret

// Scan PCI for virtio-blk devices; keep the one whose MBR partition (or
// unpartitioned sector 0) holds the boot sector the FAT driver mounted.
plat_find_disk:
    enter
    ldv x19, plat_bus_start
1:
    ldv x2, plat_bus_end
    cmp x19, x2
    b.hi 9f
    mov x20, #0
2:
    cmp x20, #32
    b.hs 8f
    mov x21, #0
3:
    cmp x21, #8
    b.hs 7f
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bl plat_pci_cfg
    mov x22, x0
    ldr w2, [x22]
    mov w3, #0xffff
    and w4, w2, w3
    cmp w4, w3
    b.eq 6f
    mov w3, #0x1af4
    cmp w4, w3
    b.ne 5f
    lsr w4, w2, #16
    mov w3, #0x1001
    cmp w4, w3
    b.eq 4f
    mov w3, #0x1042
    cmp w4, w3
    b.ne 5f
4:
    mov x0, x22
    bl vio_probe
    cbnz x0, 5f
    stv x22, vio_pci, x2
    mov x0, #0
    leave
5:
    cbnz x21, 6f
    ldrb w2, [x22, #14]         // header type: probe functions 1-7 only
    tbz w2, #7, 7f              // for multi-function devices
6:
    add x21, x21, #1
    b 3b
7:
    add x20, x20, #1
    b 2b
8:
    add x19, x19, #1
    b 1b
9:
    mov x0, #1
    leave

// x0 = PCI config address of a virtio device. Parses its capabilities,
// starts it, and checks whether it holds the boot volume. Returns x0 = 0
// when it does (and leaves it configured).
vio_probe:
    enter
    mov x19, x0
    ldrh w2, [x19, #4]
    orr w2, w2, #6              // memory space + bus master
    strh w2, [x19, #4]
    ldrh w2, [x19, #6]
    tbz w2, #4, vio_probe_fail  // no capability list
    ldrb w20, [x19, #0x34]
    stv xzr, vio_common, x2
    stv xzr, vio_notify, x2
    mov x24, #48                // loop guard
1:
    and x20, x20, #0xfc
    cbz x20, 4f
    subs x24, x24, #1
    b.eq 4f
    add x21, x19, x20
    ldrb w2, [x21]
    cmp w2, #0x09               // vendor-specific: virtio_pci_cap
    b.ne 3f
    ldrb w22, [x21, #3]         // cfg_type
    ldrb w0, [x21, #4]          // BAR
    bl vio_bar
    cbz x0, 3f
    ldr w2, [x21, #8]
    add x0, x0, x2
    cmp x22, #1
    b.ne 2f
    stv x0, vio_common, x2
    b 3f
2:
    cmp x22, #2
    b.ne 3f
    stv x0, vio_notify, x2
    ldr w2, [x21, #16]
    stv x2, vio_notify_mul, x3
3:
    ldrb w20, [x21, #1]
    b 1b
4:
    ldv x2, vio_common
    cbz x2, vio_probe_fail
    ldv x2, vio_notify
    cbz x2, vio_probe_fail
    stv xzr, vio_part_lba, x2
    bl vio_init
    cbnz x0, vio_probe_fail
    // Match the mounted boot sector, first unpartitioned, then via the MBR.
    mov x0, #0
    bl vio_read_probe
    cbnz x0, vio_probe_fail
    bl vio_compare_boot
    cbz x0, vio_probe_ok
    ldv x23, vio_buffer
    ldrb w2, [x23, #510]
    cmp w2, #0x55
    b.ne vio_probe_fail
    ldrb w2, [x23, #511]
    cmp w2, #0xaa
    b.ne vio_probe_fail
    mov x24, #0
5:
    cmp x24, #4
    b.hs vio_probe_fail
    mov x2, #16
    mov x3, #446
    madd x2, x24, x2, x3
    ldv x23, vio_buffer
    add x2, x23, x2
    ldrb w3, [x2, #4]           // partition type
    cbz w3, 6f
    ldrb w4, [x2, #8]
    ldrb w5, [x2, #9]
    orr w4, w4, w5, lsl #8
    ldrb w5, [x2, #10]
    orr w4, w4, w5, lsl #16
    ldrb w5, [x2, #11]
    orr w25, w4, w5, lsl #24    // start LBA
    mov x0, x25
    bl vio_read_probe
    cbnz x0, 6f
    bl vio_compare_boot
    cbnz x0, 6f
    stv x25, vio_part_lba, x2
    b vio_probe_ok
6:
    ldv x0, vio_part_lba        // vio_read_probe reads absolute sectors
    add x24, x24, #1
    mov x0, #0
    bl vio_read_probe           // reload the MBR for the next entry
    cbnz x0, vio_probe_fail
    b 5b
vio_probe_ok:
    mov x0, #0
    leave
vio_probe_fail:
    mov x0, #1
    leave

// w0 = BAR number. Returns x0 = BAR base address (memory BARs), or 0.
vio_bar:
    cmp w0, #5
    b.hi 2f
    add x1, x19, #0x10
    ldr w2, [x1, x0, lsl #2]
    tbnz w2, #0, 2f             // I/O BAR
    and x3, x2, #0xfffffff0
    and w4, w2, #6
    cmp w4, #4
    b.ne 1f
    add x0, x0, #1
    ldr w4, [x1, x0, lsl #2]
    orr x3, x3, x4, lsl #32
1:
    mov x0, x3
    ret
2:
    mov x0, #0
    ret

// x0 = absolute LBA: read one sector into vio_buffer.
vio_read_probe:
    frame
    ldv x2, vio_part_lba
    sub x0, x0, x2              // vio_rw adds the partition offset
    mov x1, #1
    ldv x2, vio_buffer
    mov x3, #0
    bl vio_rw
    unframe

// Compare vio_buffer with the boot sector the FAT driver mounted.
vio_compare_boot:
    ldv x0, vio_buffer
    address x1, fat_boot_copy
    mov x2, #0
1:
    ldrb w3, [x0, x2]
    ldrb w4, [x1, x2]
    cmp w3, w4
    b.ne 2f
    add x2, x2, #1
    cmp x2, #96
    b.lo 1b
    mov x0, #0
    ret
2:
    mov x0, #1
    ret

// Reset and start the device with one 8-entry request queue.
vio_init:
    enter
    ldv x19, vio_common
    ldv x20, vio_queue
    dsb sy
    strb wzr, [x19, #20]        // device_status = reset
1:
    ldrb w2, [x19, #20]
    cbnz w2, 1b
    mov w2, #3                  // ACKNOWLEDGE | DRIVER
    strb w2, [x19, #20]
    mov w2, #1
    str w2, [x19, #0]           // device_feature_select = 1
    ldr w3, [x19, #4]
    tbz w3, #0, vio_init_fail   // VIRTIO_F_VERSION_1 required
    str wzr, [x19, #8]
    str wzr, [x19, #12]
    str w2, [x19, #8]
    str w2, [x19, #12]          // accept VERSION_1 only
    mov w2, #11                 // | FEATURES_OK
    strb w2, [x19, #20]
    ldrb w2, [x19, #20]
    tbz w2, #3, vio_init_fail
    strh wzr, [x19, #22]        // queue_select = 0
    ldrh w2, [x19, #24]
    cmp w2, #VQ_SIZE
    b.lo vio_init_fail
    mov w2, #VQ_SIZE
    strh w2, [x19, #24]
    // Queue page: descriptors @0, avail @256, used @512, header @1024,
    // status @1040, bounce/probe buffer @2048.
    mov x0, x20
    mov x1, #2048
    bl fat_zero_bytes
    str x20, [x19, #32]
    add x2, x20, #256
    str x2, [x19, #40]
    add x2, x20, #512
    str x2, [x19, #48]
    add x2, x20, #2048
    stv x2, vio_buffer, x3
    ldrh w2, [x19, #30]         // queue_notify_off
    ldv x3, vio_notify_mul
    mul x2, x2, x3
    ldv x3, vio_notify
    add x2, x2, x3
    stv x2, vio_notify_addr, x3
    mov w2, #1
    strh w2, [x19, #28]         // queue_enable
    stv xzr, vio_used_seen, x2
    mov w2, #15                 // | DRIVER_OK
    strb w2, [x19, #20]
    dsb sy
    mov x0, #0
    leave
vio_init_fail:
    mov w2, #0x80               // FAILED
    strb w2, [x19, #20]
    mov x0, #1
    leave

// x0 = partition-relative LBA, x1 = sector count, x2 = buffer, x3 = 0 read
// / 1 write. Returns x0 = 0 or an EFI device error.
vio_rw:
    ldv x9, vio_part_lba
    add x0, x0, x9
    ldv x9, vio_queue
    // Request header.
    str w3, [x9, #1024]         // type: 0 in, 1 out
    str wzr, [x9, #1028]
    str x0, [x9, #1032]
    mov w4, #0xff
    strb w4, [x9, #1040]
    // Descriptor 0: header (device reads).
    add x4, x9, #1024
    str x4, [x9, #0]
    mov w4, #16
    str w4, [x9, #8]
    mov w4, #1                  // NEXT
    strh w4, [x9, #12]
    mov w4, #1
    strh w4, [x9, #14]
    // Descriptor 1: data.
    str x2, [x9, #16]
    lsl x4, x1, #9
    str w4, [x9, #24]
    mov w4, #3                  // NEXT | WRITE (device writes for reads)
    cbz x3, 1f
    mov w4, #1
1:
    strh w4, [x9, #28]
    mov w4, #2
    strh w4, [x9, #30]
    // Descriptor 2: status (device writes).
    add x4, x9, #1040
    str x4, [x9, #32]
    mov w4, #1
    str w4, [x9, #40]
    mov w4, #2
    strh w4, [x9, #44]
    strh wzr, [x9, #46]
    // Publish head 0 in the available ring.
    add x5, x9, #256
    ldrh w6, [x5, #2]           // avail.idx
    and w7, w6, #(VQ_SIZE - 1)
    add x8, x5, #4
    strh wzr, [x8, x7, lsl #1]
    dmb sy
    add w6, w6, #1
    strh w6, [x5, #2]
    dsb sy
    ldv x5, vio_notify_addr
    strh wzr, [x5]              // notify queue 0
    ldv x6, vio_used_seen
    add x5, x9, #512
    mov x7, #0x4000000          // bounded wait
2:
    ldrh w8, [x5, #2]           // used.idx
    cmp w8, w6, uxth
    b.ne 3f
    subs x7, x7, #1
    b.eq 4f
    yield
    b 2b
3:
    dmb sy
    add x6, x6, #1
    and x6, x6, #0xffff
    stv x6, vio_used_seen, x8
    ldrb w4, [x9, #1040]
    cbnz w4, 4f
    mov x0, #0
    ret
4:
    efierr x0, 7
    ret

// ---------------------------------------------------------------------------
// Exceptions. A fault in a native program terminates that program; a fault
// in the kernel itself is reported and halts.

.balign 2048
plat_vectors:
.irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
.balign 128
    sub sp, sp, #64
    stp x0, x1, [sp]
    mov x0, #\n
    b plat_exception
.endr

plat_exception:
    stp x2, x3, [sp, #16]
    stp x29, x30, [sp, #32]
    mov x19, x0
    mrs x20, esr_el1
    mrs x21, elr_el1
    mrs x22, far_el1
    mrs x2, CurrentEL
    cmp x2, #8
    b.ne 1f
    mrs x20, esr_el2
    mrs x21, elr_el2
    mrs x22, far_el2
1:
    address x0, newline
    bl puts
    mov x0, x20
    mov x1, x22
    bl plat_fault_text          // DOS-style description first
    bl puts
    address x0, plat_exc_message
    bl puts
    mov x0, x20
    bl plat_print_hex
    address x0, plat_exc_pc
    bl puts
    mov x0, x21
    bl plat_print_hex
    address x0, plat_exc_far
    bl puts
    mov x0, x22
    bl plat_print_hex
    address x0, plat_exc_base   // lets PC be matched against kernel.elf
    bl puts
    address x0, __text_start
    sub x0, x0, #0x1000         // kernel.elf links at 0x1000
    bl plat_print_hex
    address x0, newline
    bl puts
    address x2, process_frames
    ldr x2, [x2]
    cbz x2, 2f
    address x0, plat_exc_process
    bl puts
    b proc_abort                // never returns here
2:
    address x0, plat_exc_halt
    bl puts
3:
    wfi
    b 3b

// x0 = ESR, x1 = FAR. Returns x0 = a one-line description of the fault.
plat_fault_text:
    lsr x2, x0, #26             // exception class
    and x3, x0, #0x3f           // fault status code (aborts)
    cmp x2, #0x24
    b.eq 1f
    cmp x2, #0x25
    b.eq 1f
    cmp x2, #0x20
    b.eq 5f
    cmp x2, #0x21
    b.eq 5f
    address x4, plat_fault_align
    cmp x2, #0x22               // PC alignment
    b.eq 9f
    cmp x2, #0x26               // SP alignment
    b.eq 9f
    address x4, plat_fault_undef
    cbz x2, 9f
    address x4, plat_fault_priv
    cmp x2, #0x18               // MSR/MRS/system instruction trapped
    b.eq 9f
    cmp x2, #0x01               // WFI/WFE trapped
    b.eq 9f
    address x4, plat_fault_brk
    cmp x2, #0x3c
    b.eq 9f
    address x4, plat_fault_other
    b 9f
1:
    // Data abort.
    lsr x5, x3, #2
    address x4, plat_fault_null
    cmp x5, #1                  // translation fault, any level
    b.ne 2f
    cmp x1, #MMU_NULL_GUARD
    b.lo 9f
    address x4, plat_fault_unmapped
    b 9f
2:
    cmp x5, #3                  // permission fault
    b.ne 3f
    address x4, plat_fault_write
    tbnz x0, #6, 9f             // WnR
    address x4, plat_fault_read
    b 9f
3:
    address x4, plat_fault_align
    cmp x3, #0x21
    b.eq 9f
    address x4, plat_fault_memory
    b 9f
5:
    // Instruction abort.
    lsr x5, x3, #2
    address x4, plat_fault_nx
    cmp x5, #3
    b.eq 9f
    address x4, plat_fault_jump_null
    cmp x5, #1
    b.ne 6f
    cmp x1, #MMU_NULL_GUARD
    b.lo 9f
    address x4, plat_fault_jump
    b 9f
6:
    address x4, plat_fault_memory
9:
    mov x0, x4
    ret

// x0 = value: print as 16 hex digits.
plat_print_hex:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, #60
1:
    lsr x0, x19, x20
    and x0, x0, #15
    cmp x0, #10
    add x1, x0, #'0'
    add x2, x0, #('a' - 10)
    csel x0, x1, x2, lo
    bl plat_putc
    subs x20, x20, #4
    b.pl 1b
    ldp x19, x20, [sp], #16
    unframe

// ---------------------------------------------------------------------------
// Device tree (ROM builds on boards without ACPI, e.g. under U-Boot's UEFI):
// the console UART named by /chosen stdout-path. Parsing needs no firmware
// services, so tools/unit.py checks it against trees built by dtc.

.equ FDT_LEVELS, 8

// x0 = flattened device tree. Returns x0 = console UART base address (0
// when none is usable) and x1 = plat_uart_type: 0 PL011, 1 16550 with
// 32-bit registers 4 bytes apart (as the BCM2835 mini UART), 2 16550 with
// byte registers 1 byte apart, 3 16550 with byte registers 4 bytes apart.
.global plat_fdt_console
plat_fdt_console:
    enter
    mov x19, x0
    ldr w2, [x19]
    rev w2, w2
    mov w3, #0xfeed
    movk w3, #0xd00d, lsl #16
    cmp w2, w3
    b.ne 90f
    ldr w20, [x19, #4]          // totalsize
    rev w20, w20
    add x2, x19, x20
    stv x2, fdt_end, x3
    ldr w2, [x19, #8]           // off_dt_struct
    rev w2, w2
    cmp x2, x20
    b.hs 90f
    add x2, x19, x2
    stv x2, fdt_struct, x3
    ldr w2, [x19, #12]          // off_dt_strings
    rev w2, w2
    ldr w3, [x19, #32]          // size_dt_strings
    rev w3, w3
    add x4, x2, x3
    cmp x4, x20
    b.hi 90f
    stv x3, fdt_strings_size, x4
    add x2, x19, x2
    stv x2, fdt_strings, x3
    // stdout-path: "/path[:options]", or an alias name from /aliases.
    address x0, fdt_chosen_path
    mov x1, #7
    bl fdt_find_node
    cbz x0, 90f
    mov x20, x0
    address x1, fdt_stdout_name
    mov x2, #11
    bl fdt_get_prop
    cbnz x0, 1f
    mov x0, x20
    address x1, fdt_linux_stdout_name
    mov x2, #17
    bl fdt_get_prop
    cbz x0, 90f
1:
    bl fdt_path_length
    mov x21, x0
    mov x22, x1
    cbz x22, 90f
    ldrb w2, [x21]
    cmp w2, #'/'
    b.eq 2f
    address x0, fdt_aliases_path
    mov x1, #8
    bl fdt_find_node
    cbz x0, 90f
    mov x1, x21
    mov x2, x22
    bl fdt_get_prop
    cbz x0, 90f
    bl fdt_path_length
    mov x21, x0
    mov x22, x1
    cbz x22, 90f
    ldrb w2, [x21]
    cmp w2, #'/'
    b.ne 90f
2:
    mov x0, x21
    mov x1, x22
    bl fdt_find_node
    cbz x0, 90f
    mov x20, x0                 // the UART node's properties
    ldv x23, fdt_matched
    subs x23, x23, #1           // its level (the root is 0)
    b.eq 90f
    address x1, fdt_status_name // status: absent, "okay" or "ok"
    mov x2, #6
    bl fdt_get_prop
    cbz x0, 21f
    mov x21, x0
    address x1, fdt_okay
    bl fat_strcmp
    cbz x0, 21f
    mov x0, x21
    address x1, fdt_ok
    bl fat_strcmp
    cbnz x0, 90f
21:
    // compatible: the first string of the list that names a known UART.
    mov x0, x20
    address x1, fdt_compatible_name
    mov x2, #10
    bl fdt_get_prop
    cbz x0, 90f
    mov x24, x0
    add x25, x0, x1             // end of the list
3:
    cmp x24, x25
    b.hs 90f
    address x27, fdt_uart_table
31:
    ldrb w26, [x27]             // kind: 1 PL011, 2 16550 family, 3 mini UART
    cbz w26, 34f
    mov x0, x24
    add x1, x27, #1
    bl fat_strcmp
    cbz x0, 4f
    add x27, x27, #1
32:
    ldrb w2, [x27], #1
    cbnz w2, 32b
    b 31b
34:
    ldrb w2, [x24], #1          // the next string of the list
    cbnz w2, 34b
    b 3b
4:
    mov x2, #0                  // PL011
    cmp x26, #1
    b.eq 5f
    mov x2, #1                  // mini UART: 32-bit registers 4 bytes apart
    cmp x26, #3
    b.eq 5f
    // 16550: reg-shift (default 0) and reg-io-width (default 1).
    mov x0, x20
    address x1, fdt_shift_name
    mov x2, #9
    mov x3, #0
    bl fdt_get_u32
    mov x26, x0
    mov x0, x20
    address x1, fdt_width_name
    mov x2, #12
    mov x3, #1
    bl fdt_get_u32
    mov x2, #2
    cbnz x26, 41f
    cmp x0, #1                  // shift 0: byte registers only
    b.eq 5f
    b 90f
41:
    cmp x26, #2
    b.ne 90f
    mov x2, #1
    cmp x0, #4
    b.eq 5f
    mov x2, #3
    cmp x0, #1
    b.ne 90f
5:
    stv x2, fdt_uart_type, x3
    // reg, in the parent's #address-cells, then up through each ranges.
    mov x0, x20
    address x1, fdt_reg_name
    mov x2, #3
    bl fdt_get_prop
    cbz x0, 90f
    sub x22, x23, #1            // the bus whose children use this address
    address x2, fdt_acells
    ldr x3, [x2, x22, lsl #3]
    cbz x3, 90f
    cmp x3, #2                  // 3-cell (PCI) addresses: not handled
    b.hi 90f
    cmp x1, x3, lsl #2
    b.lo 90f
    mov x1, x3
    bl fdt_cells
    mov x21, x0
6:
    cbz x22, 8f                 // the root: a CPU physical address
    address x2, fdt_rlen
    ldr x25, [x2, x22, lsl #3]
    cmn x25, #1
    b.eq 90f                    // no ranges: not memory-mapped
    cbz x25, 7f                 // empty ranges: the same addresses
    address x2, fdt_rptr
    ldr x24, [x2, x22, lsl #3]
    add x25, x24, x25           // end of the table
    ldv x2, fdt_end
    cmp x25, x2
    b.hi 90f
    address x2, fdt_acells
    ldr x26, [x2, x22, lsl #3]  // child address cells
    sub x3, x22, #1
    ldr x27, [x2, x3, lsl #3]   // parent address cells
    address x2, fdt_scells
    ldr x28, [x2, x22, lsl #3]  // size cells
    cmp x26, #2                 // at most 64-bit addresses and sizes:
    b.hi 90f                    // a 3-cell PCI range could match wrongly
    cmp x27, #2
    b.hi 90f
    cmp x28, #2
    b.hi 90f
61:
    add x2, x26, x27
    add x2, x2, x28
    cbz x2, 90f
    add x2, x24, x2, lsl #2
    cmp x2, x25
    b.hi 90f                    // the address is in no range
    mov x0, x24
    mov x1, x26
    bl fdt_cells
    mov x9, x0                  // child base
    mov x0, x1
    mov x1, x27
    bl fdt_cells
    mov x10, x0                 // parent base
    mov x0, x1
    mov x1, x28
    bl fdt_cells                // x0 = size
    mov x24, x1
    cmp x21, x9
    b.lo 61b
    sub x3, x21, x9
    cmp x3, x0
    b.hs 61b
    add x21, x10, x3
7:
    sub x22, x22, #1
    b 6b
8:
    cbz x21, 90f
    mov x0, x21
    ldv x1, fdt_uart_type
    leave
90:
    mov x0, #0
    mov x1, #0
    leave

// x0 = path, x1 = its length. Walks the tree to that node; returns x0 =
// the start of its properties (0 if absent) and sets fdt_matched to its
// level + 1. Each node on the way records #address-cells, #size-cells and
// ranges for its children in fdt_acells/fdt_scells/fdt_rptr/fdt_rlen.
fdt_find_node:
    enter
    mov x19, x0
    add x20, x0, x1             // end of the path
    ldv x21, fdt_struct
    mov x22, #-1                // depth of the open node
    mov x23, #0                 // nodes matched (the root is the first)
    bl fdt_skip_slashes
1:
    ldv x2, fdt_end
    add x3, x21, #4
    cmp x3, x2
    b.hi 9f
    ldr w2, [x21], #4
    rev w2, w2
    cmp w2, #4                  // FDT_NOP
    b.eq 1b
    cmp w2, #3                  // FDT_PROP
    b.eq 5f
    cmp w2, #2                  // FDT_END_NODE
    b.eq 6f
    cmp w2, #1                  // FDT_BEGIN_NODE
    b.ne 9f
    mov x24, x21                // its name
    ldv x3, fdt_end
2:
    cmp x21, x3
    b.hs 9f
    ldrb w2, [x21], #1
    cbnz w2, 2b
    add x21, x21, #3
    and x21, x21, #~3
    add x22, x22, #1            // deep unrelated subtrees are only skipped
    cbnz x22, 3f
    mov x0, #0                  // the root
    bl fdt_level_init
    mov x23, #1
    b 4f
3:
    cmp x22, x23                // a child of the deepest matched node?
    b.ne 1b
    mov x25, x19                // this path component: [x19, x25)
31:
    cmp x25, x20
    b.hs 32f
    ldrb w2, [x25]
    cmp w2, #'/'
    b.eq 32f
    add x25, x25, #1
    b 31b
32:
    mov x0, x24
    mov x1, x19
    sub x2, x25, x19
    bl fdt_name_eq
    cbz x0, 1b
    cmp x22, #FDT_LEVELS        // levels on the path are recorded
    b.hs 9f
    mov x0, x22
    bl fdt_level_init
    add x23, x23, #1
    mov x19, x25
    bl fdt_skip_slashes
4:
    cmp x19, x20
    b.lo 1b
    stv x23, fdt_matched, x2    // the whole path matched
    mov x0, x21
    leave
5:
    ldv x2, fdt_end             // the length and name offset
    add x3, x21, #8
    cmp x3, x2
    b.hi 9f
    ldr w25, [x21]              // property length
    rev w25, w25
    ldr w26, [x21, #4]          // name offset
    rev w26, w26
    add x24, x21, #8            // value
    add x21, x24, x25
    ldv x2, fdt_end
    cmp x21, x2
    b.hi 9f                     // a value past the end of the blob
    add x21, x21, #3
    and x21, x21, #~3
    sub x2, x23, #1             // only the deepest matched node's own
    cmp x22, x2
    b.ne 1b
    ldv x2, fdt_strings_size
    cmp x26, x2
    b.hs 9f
    ldv x27, fdt_strings
    add x27, x27, x26
    mov x0, x27
    address x1, fdt_acells_name
    bl fat_strcmp
    cbnz x0, 51f
    address x3, fdt_acells
    b 52f
51:
    mov x0, x27
    address x1, fdt_scells_name
    bl fat_strcmp
    cbnz x0, 53f
    address x3, fdt_scells
52:
    cmp x25, #4
    b.lo 1b
    ldr w2, [x24]
    rev w2, w2
    str x2, [x3, x22, lsl #3]
    b 1b
53:
    mov x0, x27
    address x1, fdt_ranges_name
    bl fat_strcmp
    cbnz x0, 1b
    address x3, fdt_rptr
    str x24, [x3, x22, lsl #3]
    address x3, fdt_rlen
    str x25, [x3, x22, lsl #3]
    b 1b
6:
    sub x2, x23, #1             // the deepest matched node ended: absent
    cmp x22, x2
    b.eq 9f
    sub x22, x22, #1
    b 1b
9:
    mov x0, #0
    leave

// Advances x19 past '/' characters, up to x20. Leaf.
fdt_skip_slashes:
    cmp x19, x20
    b.hs 1f
    ldrb w2, [x19]
    cmp w2, #'/'
    b.ne 1f
    add x19, x19, #1
    b fdt_skip_slashes
1:
    ret

// x0 = level: the device tree defaults for its children. Leaf.
fdt_level_init:
    address x2, fdt_acells
    mov x3, #2
    str x3, [x2, x0, lsl #3]
    address x2, fdt_scells
    mov x3, #1
    str x3, [x2, x0, lsl #3]
    address x2, fdt_rlen
    mov x3, #-1
    str x3, [x2, x0, lsl #3]
    ret

// x0 = node name ("name@unit", NUL-terminated), x1 = path component, x2 =
// its length. Returns x0 = 1 when they name the same node: the whole name,
// or the name without its unit address when the component has none. Leaf.
fdt_name_eq:
    mov x3, #0
    mov x6, #0                  // the component has a unit address
1:
    cmp x3, x2
    b.hs 2f
    ldrb w4, [x1, x3]
    ldrb w5, [x0, x3]
    cmp w4, w5
    b.ne 8f
    cmp w4, #'@'
    cset x7, eq
    orr x6, x6, x7
    add x3, x3, #1
    b 1b
2:
    ldrb w5, [x0, x3]
    cbz w5, 9f
    cmp w5, #'@'
    b.ne 8f
    cbnz x6, 8f
9:
    mov x0, #1
    ret
8:
    mov x0, #0
    ret

// x0 = start of a node's properties, x1 = name, x2 = name length. Returns
// x0 = the value (0 if absent) and x1 = its length.
fdt_get_prop:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
1:
    ldv x2, fdt_end
    add x3, x19, #12
    cmp x3, x2
    b.hi 9f
    ldr w2, [x19], #4
    rev w2, w2
    cmp w2, #4                  // FDT_NOP
    b.eq 1b
    cmp w2, #3                  // properties end at the first child or END
    b.ne 9f
    ldr w22, [x19]
    rev w22, w22
    ldr w23, [x19, #4]
    rev w23, w23
    add x24, x19, #8
    add x19, x24, x22
    ldv x2, fdt_end
    cmp x19, x2
    b.hi 9f                     // a value past the end of the blob
    add x19, x19, #3
    and x19, x19, #~3
    ldv x2, fdt_strings_size
    cmp x23, x2
    b.hs 9f
    ldv x0, fdt_strings
    add x0, x0, x23
    mov x3, #0
2:
    cmp x3, x21                 // the name, exactly
    b.hs 3f
    ldrb w4, [x0, x3]
    ldrb w5, [x20, x3]
    cmp w4, w5
    b.ne 1b
    add x3, x3, #1
    b 2b
3:
    ldrb w4, [x0, x3]
    cbnz w4, 1b
    mov x0, x24
    mov x1, x22
    leave
9:
    mov x0, #0
    mov x1, #0
    leave

// x0 = node properties, x1 = name, x2 = name length, x3 = default.
// Returns x0 = the property as a u32 cell, or the default.
fdt_get_u32:
    frame
    str x3, [sp, #-16]!
    bl fdt_get_prop
    ldr x3, [sp], #16
    cbz x0, 1f
    cmp x1, #4
    b.lo 1f
    ldr w3, [x0]
    rev w3, w3
1:
    mov x0, x3
    unframe

// x0 = cells, x1 = count. Returns x0 = their value (the low 64 bits) and
// x1 = the next cell. Leaf: x0-x4 only.
fdt_cells:
    mov x2, #0
1:
    cbz x1, 2f
    ldr w3, [x0], #4
    rev w3, w3
    orr x2, x3, x2, lsl #32
    sub x1, x1, #1
    b 1b
2:
    mov x1, x0
    mov x0, x2
    ret

// x0 = string property, x1 = its length. Returns x0 unchanged and x1 =
// the length of the path in it: up to a NUL, a ':' (options) or the end.
fdt_path_length:
    mov x2, #0
1:
    cmp x2, x1
    b.hs 2f
    ldrb w3, [x0, x2]
    cbz w3, 2f
    cmp w3, #':'
    b.eq 2f
    add x2, x2, #1
    b 1b
2:
    mov x1, x2
    ret

.section .rodata
fw_ansi_colour: .byte 0, 4, 2, 6, 1, 5, 3, 7   // ANSI colour -> EFI colour
.balign 8
acpi20_guid:
    .long 0x8868e871
    .short 0xe4f1, 0x11d3
    .byte 0xbc,0x22,0x00,0x80,0xc7,0x3c,0x88,0x81
rsdp_signature: .ascii "RSD PTR "
plat_cls_sequence: .asciz "\x1b[2J\x1b[H"
plat_exc_message: .asciz "CPU exception: ESR="
plat_fault_null: .asciz "Protection fault: null pointer reference\r\n"
plat_fault_unmapped: .asciz "Protection fault: reference to unmapped memory\r\n"
plat_fault_write: .asciz "Protection fault: write to read-only or protected memory\r\n"
plat_fault_read: .asciz "Protection fault: read of protected memory\r\n"
plat_fault_nx: .asciz "Protection fault: execution of non-executable memory\r\n"
plat_fault_jump_null: .asciz "Protection fault: jump to a null pointer\r\n"
plat_fault_jump: .asciz "Protection fault: jump to unmapped memory\r\n"
plat_fault_align: .asciz "Alignment fault: misaligned code, stack or data address\r\n"
plat_fault_memory: .asciz "Memory error: the access could not be completed\r\n"
plat_fault_undef: .asciz "Invalid instruction\r\n"
plat_fault_priv: .asciz "Privileged instruction\r\n"
plat_fault_brk: .asciz "Breakpoint instruction\r\n"
plat_fault_other: .asciz "Unexpected CPU exception\r\n"
plat_exc_pc: .asciz " PC="
plat_exc_base: .asciz " KERNEL="
plat_exc_far: .asciz " FAR="
plat_exc_process: .asciz "Program terminated by CPU exception.\r\n"
plat_exc_halt: .asciz "Kernel halted.\r\n"
plat_disk_lost: .asciz "\r\nBoot disk did not restart after leaving firmware.\r\n"
plat_native_message: .asciz "Platform: native AArch64 kernel (firmware exited; PL011 console, virtio-blk disk)\r\n"
plat_pi_message: .asciz "Platform: native AArch64 kernel (firmware exited; Raspberry Pi 3 UART console, SD card)\r\n"
plat_pi_marker: .asciz "A:\\NATIVE.ON"
plat_rom_native_message: .asciz "Platform: native AArch64 kernel (firmware exited; console UART at "
plat_rom_native_end: .asciz ", A: in ROM)\r\n"
plat_rom_firmware_message: .asciz "Platform: UEFI firmware services (ROM build; native mode not enabled or no known UART)\r\n"
fdt_guid:
    .long 0xb1b621d5
    .short 0xf19c, 0x41a5
    .byte 0x83,0x0b,0xd9,0x15,0x2c,0x69,0xaa,0xe0
fdt_chosen_path: .asciz "/chosen"
fdt_aliases_path: .asciz "/aliases"
fdt_stdout_name: .asciz "stdout-path"
fdt_linux_stdout_name: .asciz "linux,stdout-path"
fdt_compatible_name: .asciz "compatible"
fdt_reg_name: .asciz "reg"
fdt_status_name: .asciz "status"
fdt_okay: .asciz "okay"
fdt_ok: .asciz "ok"
fdt_shift_name: .asciz "reg-shift"
fdt_width_name: .asciz "reg-io-width"
fdt_acells_name: .asciz "#address-cells"
fdt_scells_name: .asciz "#size-cells"
fdt_ranges_name: .asciz "ranges"
// compatible strings: a kind byte (1 PL011, 2 16550 family, 3 BCM2835 mini
// UART) then the NUL-terminated name; a 0 kind ends the table.
fdt_uart_table:
    .byte 1
    .asciz "arm,pl011"
    .byte 1
    .asciz "arm,sbsa-uart"
    .byte 3
    .asciz "brcm,bcm2835-aux-uart"
    .byte 2
    .asciz "ns16550a"
    .byte 2
    .asciz "ns16550"
    .byte 2
    .asciz "ns16450"
    .byte 2
    .asciz "snps,dw-apb-uart"
    .byte 0
plat_firmware_message: .asciz "Platform: UEFI firmware services (no native drivers for this board)\r\n"

.section .data
.balign 8
fw_attribute: .quad 0x07
.section .bss
.balign 8
fw_esc_state: .skip 48          // state, parameter count, 4 parameters
.balign 16
platform_native: .skip 8
plat_uart: .skip 8
plat_uart_type: .skip 8           // 0 PL011, 1 16550/mini UART (32-bit, stride 4), 2 16550 (8-bit, stride 1), 3 16550 (8-bit, stride 4)
plat_disk_kind: .skip 8           // 0 virtio-blk, 1 Pi SD card, 2 none (ROM disk)
fdt_end: .skip 8
fdt_struct: .skip 8
fdt_strings: .skip 8
fdt_strings_size: .skip 8
fdt_matched: .skip 8
fdt_uart_type: .skip 8
fdt_acells: .skip 8 * FDT_LEVELS
fdt_scells: .skip 8 * FDT_LEVELS
fdt_rptr: .skip 8 * FDT_LEVELS
fdt_rlen: .skip 8 * FDT_LEVELS
plat_ecam: .skip 8
plat_bus_start: .skip 8
plat_bus_end: .skip 8
plat_arena: .skip 8
plat_map_size: .skip 8
plat_map_key: .skip 8
plat_desc_size: .skip 8
plat_desc_version: .skip 8
vio_pci: .skip 8
vio_common: .skip 8
vio_notify: .skip 8
vio_notify_mul: .skip 8
vio_notify_addr: .skip 8
vio_queue: .skip 8
vio_buffer: .skip 8
vio_used_seen: .skip 8
vio_part_lba: .skip 8
plat_granule_map: .skip PLAT_GRANULES * 2
plat_alloc_strategy: .skip 8
.balign 16
plat_memory_map: .skip 16384
