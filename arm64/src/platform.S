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

.section .text

// ---------------------------------------------------------------------------
// Console

// w0 = byte.
plat_putc:
    adrp x1, platform_native
    ldr x1, [x1, :lo12:platform_native]
    cbz x1, 2f
    ldv x1, plat_uart
1:
    ldr w2, [x1, #0x18]         // UARTFR
    tbnz w2, #5, 1b             // TXFF
    and w0, w0, #0xff
    str w0, [x1]
    ret
2:
    frame
    sub sp, sp, #16
    and w0, w0, #0xff
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
    ldr w2, [x1, #0x18]
    tbnz w2, #4, 1f             // RXFE
    ldr w0, [x1]
    and w0, w0, #0xff
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
    adrp x1, platform_native
    ldr x1, [x1, :lo12:platform_native]
    cbz x1, 1f
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
    cbz x2, plat_fail
    // Memory the runtime keeps after firmware is gone.
    mov x0, #(PLAT_ARENA_BYTES >> 12)
    bl plat_alloc_pages
    cbz x0, plat_fail
    stv x0, plat_arena, x2
    mov x0, #1
    bl plat_alloc_pages
    cbz x0, plat_fail
    stv x0, vio_queue, x2
    bl plat_find_disk
    cbnz x0, plat_fail
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
    // The firmware's virtio driver reset the device on exit; start ours.
    bl vio_init
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
    ldrb w2, [x26, #36]         // interface: PL011 (3) or SBSA generic (0xe)
    cmp w2, #3
    b.eq 31f
    cmp w2, #0x0e
    b.ne 6f
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
    address x0, efi_main
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

.section .rodata
.balign 8
acpi20_guid:
    .long 0x8868e871
    .short 0xe4f1, 0x11d3
    .byte 0xbc,0x22,0x00,0x80,0xc7,0x3c,0x88,0x81
rsdp_signature: .ascii "RSD PTR "
plat_cls_sequence: .asciz "\x1b[2J\x1b[H"
plat_exc_message: .asciz "\r\nCPU exception: ESR="
plat_exc_pc: .asciz " PC="
plat_exc_base: .asciz " KERNEL="
plat_exc_far: .asciz " FAR="
plat_exc_process: .asciz "Program terminated by CPU exception.\r\n"
plat_exc_halt: .asciz "Kernel halted.\r\n"
plat_disk_lost: .asciz "\r\nBoot disk did not restart after leaving firmware.\r\n"
plat_native_message: .asciz "Platform: native AArch64 kernel (firmware exited; PL011 console, virtio-blk disk)\r\n"
plat_firmware_message: .asciz "Platform: UEFI firmware services (no native drivers for this board)\r\n"

.section .bss
.balign 16
platform_native: .skip 8
plat_uart: .skip 8
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
