// SPDX-License-Identifier: MIT
// Kernel translation tables (native mode only). After ExitBootServices the
// kernel replaces the firmware's page tables with its own identity map:
//
//   - kernel code read-only and executable, kernel read-only data and all
//     other RAM execute-never, kernel data and bss writable but execute-never;
//   - the DOS memory arena (program images, drivers, 48h blocks) readable,
//     writable and executable, since programs run code from it;
//   - every physical address below 1 TiB that the firmware's memory map does
//     not list as RAM mapped as Device-nGnRnE, execute-never (MMIO, PCI BARs);
//   - the first 64 KiB unmapped, so null pointers (and small offsets from
//     them) fault instead of reading or overwriting low memory.
//
// A kernel that firmware started at EL2 drops to EL1 here, so in native mode
// the kernel always runs at EL1 with these tables (EL1&0 translation regime).
// Firmware mode keeps the firmware's tables and exception level.

.equ MMU_POOL_PAGES, 256               // 1 MiB of translation tables
.equ MMU_DEVICE_LIMIT, 0x10000000000   // map MMIO below 1 TiB
.equ MMU_NULL_GUARD, 0x10000           // unmapped low 64 KiB
.equ MMU_ADDR_MASK, 0x0000fffffffff000

.equ PTE_ATTR_DEVICE, (0 << 2)         // MAIR index 0: Device-nGnRnE
.equ PTE_ATTR_NORMAL, (1 << 2)         // MAIR index 1: Normal write-back
.equ PTE_ATTR_NC, (2 << 2)             // MAIR index 2: Normal non-cacheable
.equ PTE_EL0, (1 << 6)                 // AP[1]: EL0 may access
.equ PTE_RO, (1 << 7)                  // AP[2]: read-only
.equ PTE_SH_INNER, (3 << 8)
.equ PTE_AF, (1 << 10)
.equ PTE_PXN, (1 << 53)
.equ PTE_UXN, (1 << 54)
.equ PTE_PERM_BITS, (PTE_EL0 | PTE_RO | PTE_PXN | PTE_UXN)

.equ MMU_DEVICE, (PTE_AF | PTE_ATTR_DEVICE | PTE_PXN | PTE_UXN)
.equ MMU_NORMAL_NC, (PTE_AF | PTE_SH_INNER | PTE_ATTR_NC | PTE_PXN | PTE_UXN)
.equ MMU_DATA, (PTE_AF | PTE_SH_INNER | PTE_ATTR_NORMAL | PTE_PXN | PTE_UXN)
.equ MMU_RODATA, (MMU_DATA | PTE_RO)
.equ MMU_TEXT, (PTE_AF | PTE_SH_INNER | PTE_ATTR_NORMAL | PTE_RO | PTE_UXN)
.equ MMU_RWX, (PTE_AF | PTE_SH_INNER | PTE_ATTR_NORMAL | PTE_UXN)

.equ MMU_MAIR, 0x44ff00
// T0SZ 16 (48-bit VA), inner/outer write-back walks, inner shareable, 4 KiB
// granule, TTBR1 walks disabled; IPS is added at run time.
.equ MMU_TCR, (16 | (1 << 8) | (1 << 10) | (3 << 12) | (1 << 23))
// RES1 bits plus M, C, SA, SA0, I, DZE, UCT, nTWI, nTWE, UCI (EL0 may use
// DC ZVA, CTR_EL0, WFI/WFE and cache maintenance by VA).
.equ MMU_SCTLR, 0x34d5d81d

.macro mov64 reg, val
    movz \reg, #((\val) & 0xffff)
    movk \reg, #(((\val) >> 16) & 0xffff), lsl #16
    movk \reg, #(((\val) >> 32) & 0xffff), lsl #32
    movk \reg, #(((\val) >> 48) & 0xffff), lsl #48
.endm

.section .text

// Before ExitBootServices: reserve the table pool. Failure only disables
// protection, so it is not an error.
mmu_reserve:
    frame
    mov x0, #MMU_POOL_PAGES
    bl plat_alloc_pages
    stv x0, mmu_pool, x1
    unframe

// Returns x0 = zeroed 4 KiB table, or 0 when the pool is exhausted.
mmu_alloc_table:
    ldv x0, mmu_pool_used
    cmp x0, #MMU_POOL_PAGES
    b.hs 2f
    add x1, x0, #1
    stv x1, mmu_pool_used, x2
    ldv x1, mmu_pool
    add x0, x1, x0, lsl #12
    mov x1, x0
    add x2, x0, #4096
1:
    stp xzr, xzr, [x1], #16
    cmp x1, x2
    b.lo 1b
    ret
2:
    mov x0, #0
    ret

// x0 = descriptor address, x1 = new descriptor. Once the tables are live a
// change of a valid entry that is not only a permission change (a block
// becoming a table, a memory type change) uses break-before-make.
mmu_store:
    ldv x2, mmu_live
    cbz x2, 2f
    ldr x2, [x0]
    tbz x2, #0, 2f              // was invalid
    tbz x1, #0, 2f              // becomes invalid: flushed by the caller
    eor x3, x2, x1
    mov64 x4, PTE_PERM_BITS
    bic x3, x3, x4
    cbz x3, 2f
    str xzr, [x0]
    dsb ishst
    tlbi vmalle1is
    dsb ish
    isb
2:
    str x1, [x0]
    ret

// x0 = table, x1 = level (0-3), x2 = start, x3 = end (4 KiB aligned),
// x4 = leaf attributes (0 unmaps). Uses the largest blocks that fit (1 GiB
// at level 1, 2 MiB at level 2, pages at level 3) and splits blocks that are
// only partly covered. Returns x0 = 0, or 1 when the table pool ran out.
mmu_walk:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x24, #39
    mov x5, #9
    msub x24, x20, x5, x24      // shift = 39 - 9 * level
    mov x25, #1
    lsl x25, x25, x24           // bytes per entry
1:
    cmp x21, x22
    b.hs 8f
    lsr x5, x21, x24
    and x5, x5, #511
    add x26, x19, x5, lsl #3    // entry address
    sub x6, x25, #1
    bic x7, x21, x6             // entry's first address
    add x8, x7, x25             // entry's end
    cmp x8, x22
    csel x27, x8, x22, ls       // this chunk ends at min(entry end, end)
    ldr x9, [x26]
    cbz x20, 3f                 // level 0 holds only tables
    cmp x21, x7
    b.ne 3f
    cmp x27, x8
    b.ne 3f
    // The whole entry is covered: write a block or page descriptor.
    mov x1, #0
    cbz x23, 2f
    orr x1, x7, x23
    cmp x20, #3
    mov x10, #3                 // page
    mov x11, #1                 // block
    csel x10, x10, x11, eq
    orr x1, x1, x10
2:
    mov x0, x26
    bl mmu_store
    b 7f
3:
    // Partly covered: descend, creating or splitting the next level.
    and x10, x9, #3
    cmp x10, #3
    b.ne 4f
    mov64 x10, MMU_ADDR_MASK
    and x28, x9, x10
    b 6f
4:
    bl mmu_alloc_table
    cbz x0, 9f
    mov x28, x0
    ldr x9, [x26]
    tbz x9, #0, 5f              // was invalid: the new table stays empty
    mov64 x10, MMU_ADDR_MASK
    bic x11, x9, x10
    bic x11, x11, #3            // the block's attributes
    cmp x20, #2
    mov x12, #3
    mov x13, #1
    csel x12, x12, x13, eq      // children of level 2 are pages
    orr x11, x11, x12
    and x12, x9, x10            // block base
    lsr x13, x25, #9            // child size
    mov x14, #0
51:
    orr x15, x12, x11
    str x15, [x28, x14, lsl #3]
    add x12, x12, x13
    add x14, x14, #1
    cmp x14, #512
    b.lo 51b
5:
    dsb ishst
    mov x0, x26
    orr x1, x28, #3
    bl mmu_store
6:
    mov x0, x28
    add x1, x20, #1
    mov x2, x21
    mov x3, x27
    mov x4, x23
    bl mmu_walk
    cbnz x0, 9f
7:
    mov x21, x27
    b 1b
8:
    mov x0, #0
    leave
9:
    mov x0, #1
    leave

// x0 = start, x1 = end, x2 = leaf attributes (0 unmaps). Rounds out to
// pages. Returns x0 = 0 on success.
mmu_set:
    frame
    mov x3, #0xfff
    bic x0, x0, x3
    add x1, x1, x3
    bic x1, x1, x3
    mov x4, x2
    mov x3, x1
    mov x2, x0
    ldv x0, mmu_root
    cbz x0, 2f
    mov x1, #0
    bl mmu_walk
    ldv x1, mmu_live
    cbz x1, 1f
    dsb ishst
    tlbi vmalle1is
    dsb ish
    isb
1:
    unframe
2:
    mov x0, #1
    unframe

// Hooks for drivers that find MMIO or a framebuffer after boot. x0 = start,
// x1 = end. No-ops (x0 = 0) unless the kernel's own tables are live. Do not
// call them on RAM the kernel itself is using.
mmu_map_device:
    mov64 x2, MMU_DEVICE
    b 1f
mmu_map_normal_nc:
    mov64 x2, MMU_NORMAL_NC
1:
    ldv x3, mmu_live
    cbz x3, 2f
    frame
    mrs x3, daif
    str x3, [sp, #-16]!
    msr daifset, #0xf           // nothing may touch a range mid-update
    bl mmu_set
    ldr x3, [sp], #16
    msr daif, x3
    unframe
2:
    mov x0, #0
    ret

// After ExitBootServices, with the final memory map in plat_memory_map.
// Returns x0 = 0 when the kernel's tables are live, 1 when protection is
// unavailable (the firmware's tables and exception level stay in use).
mmu_init:
    enter
    ldv x0, mmu_pool
    cbz x0, 90f
    mrs x19, CurrentEL
    cmp x19, #8
    b.ne 1f
    mrs x0, hcr_el2
    tbnz x0, #34, 90f           // VHE host: EL1 is not a separate regime
1:
    mrs x0, id_aa64mmfr0_el1
    ubfx x1, x0, #28, #4        // TGran4
    cmp x1, #0xf
    b.eq 90f
    and x1, x0, #0xf            // PARange
    cmp x1, #5
    mov x2, #5
    csel x1, x1, x2, ls
    stv x1, mmu_ips, x2
    address x2, mmu_pa_bits
    ldrb w2, [x2, x1]
    mov x20, #1
    lsl x20, x20, x2            // physical address limit
    mov64 x2, MMU_DEVICE_LIMIT
    cmp x20, x2
    csel x20, x20, x2, ls
    bl mmu_alloc_table
    cbz x0, 90f
    stv x0, mmu_root, x1

    // Everything below the limit starts as device memory.
    mov x0, #0
    mov x1, x20
    mov64 x2, MMU_DEVICE
    bl mmu_set
    cbnz x0, 90f

    // RAM from the memory map, by type. Regions without write-back support
    // stay device memory.
    address x21, plat_memory_map
    ldv x22, plat_map_size
    add x22, x21, x22
    ldv x23, plat_desc_size
    cbz x23, 90f
2:
    add x0, x21, x23
    cmp x0, x22
    b.hi 4f
    ldr w0, [x21]               // Type
    cmp w0, #16
    b.hs 3f
    address x1, mmu_type_class
    ldrb w1, [x1, x0]
    cbz w1, 3f
    ldr x2, [x21, #32]          // Attribute
    tbz x2, #3, 3f              // EFI_MEMORY_WB
    ldr x0, [x21, #8]           // PhysicalStart
    ldr x3, [x21, #24]          // NumberOfPages
    add x3, x0, x3, lsl #12
    cmp x0, x20
    b.hs 3f
    cmp x3, x20
    csel x3, x3, x20, ls
    mov64 x2, MMU_DATA
    cmp w1, #2
    b.ne 21f
    mov64 x2, MMU_RWX           // runtime services code
21:
    mov x1, x3
    bl mmu_set
    cbnz x0, 90f
3:
    add x21, x21, x23
    b 2b
4:
    // The kernel image: PE headers, code, read-only data, data and bss.
    address x0, __text_start
    sub x0, x0, #0x1000
    address x1, __text_start
    mov64 x2, MMU_RODATA
    bl mmu_set
    cbnz x0, 90f
    address x0, __text_start
    address x1, __rodata_start
    mov64 x2, MMU_TEXT
    bl mmu_set
    cbnz x0, 90f
    address x0, __rodata_start
    address x1, __data_start
    mov64 x2, MMU_RODATA
    bl mmu_set
    cbnz x0, 90f
    address x0, __data_start
    address x1, __image_end
    mov64 x2, MMU_DATA
    bl mmu_set
    cbnz x0, 90f

    // The DOS arena: programs and drivers execute from it.
    ldv x0, plat_arena
    cbz x0, 5f
    mov x1, #PLAT_ARENA_BYTES
    add x1, x0, x1
    mov64 x2, MMU_RWX
    bl mmu_set
    cbnz x0, 90f
5:
    mov x0, #0
    mov x1, #MMU_NULL_GUARD
    mov x2, #0
    bl mmu_set
    cbnz x0, 90f

    // Translation registers.
    ldv x0, mmu_root
    mov64 x1, MMU_TCR
    ldv x2, mmu_ips
    orr x1, x1, x2, lsl #32
    mov64 x2, MMU_MAIR
    mov64 x3, MMU_SCTLR
    dsb ish
    cmp x19, #8
    b.eq 6f
    bl mmu_switch_el1
    b 7f
6:
    bl mmu_enter_el1
7:
    mov x0, #1
    stv x0, mmu_live, x1
    mov x0, #0
    leave
90:
    mov x0, #1
    leave

// EL1 with the firmware's MMU on: switch tables with the MMU briefly off.
// The code between the two SCTLR writes makes no data accesses, so the
// caches stay coherent with what the new (identical, write-back) mapping
// expects. x0 = TTBR0, x1 = TCR, x2 = MAIR, x3 = SCTLR.
.balign 64
mmu_switch_el1:
    address x4, mmu_switch_el1
    address x5, mmu_switch_end
1:
    dc cvac, x4                 // the code runs uncached for a moment
    add x4, x4, #64
    cmp x4, x5
    b.lo 1b
    dsb sy
    msr daifset, #0xf
    mrs x4, sctlr_el1
    bic x4, x4, #1
    msr sctlr_el1, x4
    isb
    msr mair_el1, x2
    msr tcr_el1, x1
    msr ttbr0_el1, x0
    isb
    tlbi vmalle1
    dsb nsh
    isb
    msr sctlr_el1, x3
    isb
    ic iallu
    dsb nsh
    isb
    mov x4, #3
    msr cntkctl_el1, x4         // EL0 may read the counters
    mov x4, #(3 << 20)
    msr cpacr_el1, x4           // FP/SIMD at EL0 and EL1
    isb
    ret
mmu_switch_end:

// EL2 (firmware's own tables): configure EL1 from scratch with the MMU on
// and drop to it, keeping the current stack. x0-x3 as above.
mmu_enter_el1:
    msr daifset, #0xf
    msr mair_el1, x2
    msr tcr_el1, x1
    msr ttbr0_el1, x0
    msr sctlr_el1, x3
    address x4, plat_vectors
    msr vbar_el1, x4
    mov x4, #(3 << 20)
    msr cpacr_el1, x4
    mov x4, #3
    msr cntkctl_el1, x4
    msr cnthctl_el2, x4         // EL1 physical counter and timer
    msr cntvoff_el2, xzr
    mov x4, #0x33ff
    msr cptr_el2, x4            // no FP/SIMD traps
    msr vttbr_el2, xzr
    mrs x4, midr_el1
    msr vpidr_el2, x4
    mrs x4, mpidr_el1
    msr vmpidr_el2, x4
    mov x4, #(1 << 31)
    msr hcr_el2, x4             // EL1 is AArch64; nothing trapped or routed
    mrs x4, id_aa64pfr0_el1
    ubfx x4, x4, #24, #4        // GICv3 system register interface?
    cbz x4, 1f
    mrs x5, S3_4_C12_C9_5       // ICC_SRE_EL2
    mov x6, #9
    orr x5, x5, x6              // SRE, Enable: EL1 may use ICC_* registers
    msr S3_4_C12_C9_5, x5
    msr S3_4_C12_C11_0, xzr     // ICH_HCR_EL2: no virtual interface
1:
    mov x4, sp
    msr sp_el1, x4
    mov x4, #0x3c5              // EL1h, interrupts masked
    msr spsr_el2, x4
    adr x4, 2f
    msr elr_el2, x4
    isb
    tlbi vmalle1
    dsb ish
    isb
    eret
2:
    ret

.section .rodata
mmu_banner: .asciz "Memory protection: kernel code read-only, data no-execute, null pointers trapped\r\n"
mmu_pa_bits: .byte 32, 36, 40, 42, 44, 48
// UEFI memory type -> 0 not RAM, 1 RAM, 2 runtime services code.
mmu_type_class: .byte 0, 1, 1, 1, 1, 2, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0

.section .bss
.balign 8
mmu_pool: .skip 8
mmu_pool_used: .skip 8
mmu_root: .skip 8
mmu_live: .skip 8
mmu_ips: .skip 8
