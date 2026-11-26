// SPDX-License-Identifier: MIT
// ARM DOS extension E0h: raw disk services for INSTALL. DOS reached whole
// disks through INT 13h (FDISK, FORMAT); here the firmware's Block I/O
// protocol plays that part. It is only available while UEFI boot services
// run (firmware mode, as the live ISO always is). A disk is a whole-disk
// Block I/O handle that is present, writable and not the one ARM DOS booted
// from.
//
// x0 = subfunction:
//   0  find disks: x0 = their count (0 in native mode)
//   1  x1 = disk, x2 = 32-byte buffer: u64 block size, u64 blocks,
//      u64 flags (1 removable), u64 reserved
//   2  read, 3 write: x1 = disk, x2 = first block, x3 = blocks, x4 = buffer
//   4  attach: x1 = disk, x2 = first block, x3 = blocks: mounts that range
//      (a partition) as the next drive letter; x0 = the drive (0 = A:)
//   5  flush: x1 = disk
.equ DISK_MAX, 8
.equ DISK_PARTS, 4
.equ DISK_BOUNCE_PAGES, 16      // 64 KiB, page aligned for any IoAlign

.macro ldv_bs reg
    adrp \reg, boot_services
    ldr \reg, [\reg, :lo12:boot_services]
.endm

.section .text
.global disk_services
disk_services:
    cmp x0, #0
    b.eq disk_find
    cmp x0, #5
    b.hi disk_bad_function
    adrp x9, disk_count
    ldr x9, [x9, :lo12:disk_count]
    cmp x1, x9
    b.hs disk_bad_disk
    address x9, disk_bio
    ldr x9, [x9, x1, lsl #3]    // the disk's EFI_BLOCK_IO_PROTOCOL
    cmp x0, #1
    b.eq disk_info
    cmp x0, #4
    b.eq disk_attach
    cmp x0, #5
    b.eq disk_flush
    // Read or write through the bounce buffer, at most 64 KiB at a time.
    enter
    mov x19, x9
    cmp x0, #3
    cset x20, eq
    mov x21, x2                 // block
    mov x22, x3                 // blocks left
    mov x23, x4                 // caller's buffer
    bl disk_bounce_buffer
    cbz x0, 9f
    mov x24, x0
    ldr x2, [x19, #8]
    ldr w25, [x2, #12]          // BlockSize
    mov x26, #(DISK_BOUNCE_PAGES * 4096)
    udiv x26, x26, x25          // blocks per transfer
1:
    cbz x22, 8f
    cmp x22, x26
    csel x27, x22, x26, lo
    mul x28, x27, x25           // bytes this time
    cbz x20, 2f
    mov x0, x23
    mov x1, x24
    mov x2, x28
    bl disk_copy
    mov x0, #32                 // WriteBlocks
    bl disk_transfer
    cbnz x0, 9f
    b 3f
2:
    mov x0, #24                 // ReadBlocks
    bl disk_transfer
    cbnz x0, 9f
    mov x0, x24
    mov x1, x23
    mov x2, x28
    bl disk_copy
3:
    add x21, x21, x27
    sub x22, x22, x27
    add x23, x23, x28
    b 1b
8:
    mov x0, #0
    mov x1, #0
    leave
9:
    mov x0, #21                 // drive not ready
    mov x1, #1
    leave

// x0 = Block I/O offset (24 read, 32 write); x19 protocol, x21 block,
// x24 bounce buffer, x28 bytes. Returns the EFI status.
disk_transfer:
    frame
    mov x9, x0
    mov x0, x19
    ldr x1, [x19, #8]
    ldr w1, [x1]                // MediaId
    mov x2, x21
    mov x3, x28
    mov x4, x24
    ldr x5, [x19, x9]
    blr x5
    unframe

// x0 = source, x1 = destination, x2 = bytes (a multiple of 8). Leaf.
disk_copy:
    cbz x2, 2f
1:
    ldr x9, [x0], #8
    str x9, [x1], #8
    subs x2, x2, #8
    b.hi 1b
2:
    ret

// Returns x0 = the 64 KiB bounce buffer (allocated once), or 0.
disk_bounce_buffer:
    frame
    address x0, disk_bounce
    ldr x2, [x0]
    cbnz x2, 1f
    mov x0, #0                  // AllocateAnyPages
    mov x1, #2                  // EfiLoaderData
    mov x2, #DISK_BOUNCE_PAGES
    address x3, disk_bounce
    ldv_bs x4
    ldr x4, [x4, #40]           // AllocatePages
    blr x4
    mov x2, #0
    cbnz x0, 1f
    address x0, disk_bounce
    ldr x2, [x0]
1:
    mov x0, x2
    unframe


disk_info:
    ldr x10, [x9, #8]           // EFI_BLOCK_IO_MEDIA
    ldr w11, [x10, #12]
    str x11, [x2]
    ldr x11, [x10, #24]         // LastBlock
    add x11, x11, #1
    str x11, [x2, #8]
    ldrb w11, [x10, #4]         // RemovableMedia
    str x11, [x2, #16]
    str xzr, [x2, #24]
    mov x0, #0
    mov x1, #0
    ret

disk_flush:
    frame
    mov x0, x9
    ldr x9, [x9, #40]           // FlushBlocks
    blr x9
    mov x1, #0
    cbz x0, 1f
    mov x0, #21
    mov x1, #1
1:
    unframe

disk_bad_function:
    mov x0, #1
    mov x1, #1
    ret
disk_bad_disk:
    mov x0, #15                 // invalid drive
    mov x1, #1
    ret

// Attach: a partition slot records the protocol and its first block; its
// rw entry (disk_part_rwN) is what the drive table calls.
disk_attach:
    frame
    address x10, disk_part_bio
    mov x11, #0
1:
    ldr x12, [x10, x11, lsl #3]
    cbz x12, 2f
    add x11, x11, #1
    cmp x11, #DISK_PARTS
    b.lo 1b
    mov x0, #4                  // too many open files: no slot left
    mov x1, #1
    unframe
2:
    ldr x12, [x9, #8]
    ldr w13, [x12, #12]         // BlockSize
    ldr x14, [x12, #24]         // LastBlock
    add x14, x14, #1
    adds x15, x2, x3            // the range must lie on the disk
    b.cs 8f
    cmp x15, x14
    b.hi 8f
    cbz x3, 8f
    str x9, [x10, x11, lsl #3]
    address x10, disk_part_start
    str x2, [x10, x11, lsl #3]
    stp x11, x9, [sp, #-16]!
    adr x0, disk_part_rw0
    add x0, x0, x11, lsl #3     // each entry is two instructions
    mov x1, x13
    mov x2, x3
    bl drive_add_block
    ldp x11, x9, [sp], #16
    cbz x1, 3f
    address x10, disk_part_bio  // no letter or volume left: free the slot
    str xzr, [x10, x11, lsl #3]
    mov x0, #15
    mov x1, #1
    unframe
3:
    mov x1, #0
    unframe
8:
    mov x0, #87                 // invalid parameter
    mov x1, #1
    unframe

// rw(x0 = sector, x1 = buffer, x2 = count, x3 = 1 to write) for each slot.
// The buffer is a page-aligned sector cache slot.
disk_part_rw0:
    mov x9, #0
    b disk_part_rw
    mov x9, #1
    b disk_part_rw
    mov x9, #2
    b disk_part_rw
    mov x9, #3
    b disk_part_rw
disk_part_rw:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    address x10, disk_part_bio
    ldr x19, [x10, x9, lsl #3]
    address x10, disk_part_start
    ldr x10, [x10, x9, lsl #3]
    mov x20, x3
    add x10, x10, x0
    mov x4, x1
    ldr x11, [x19, #8]
    ldr w1, [x11]               // MediaId
    ldr w12, [x11, #12]
    mul x3, x2, x12             // bytes
    mov x2, x10
    mov x0, x19
    mov x9, #24                 // ReadBlocks
    cbz x20, 1f
    mov x9, #32                 // WriteBlocks
1:
    ldr x5, [x19, x9]
    blr x5
    cbnz x0, 2f
    cbz x20, 2f
    mov x0, x19                 // writes are written through to the disk
    ldr x5, [x19, #40]          // FlushBlocks
    blr x5
2:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// Find: every Block I/O handle that is a whole, present, writable disk
// whose device path is not a prefix of the boot device's.
disk_find:
    enter
    sub sp, sp, #32
    address x9, disk_count
    str xzr, [x9]
    ldv_bs x19
    adrp x9, platform_native
    ldr x9, [x9, :lo12:platform_native]
    cbnz x9, 8f                 // no firmware left: no disks to offer
    // The boot device's path (the partition ARM DOS was loaded from).
    str xzr, [sp, #24]
    adrp x0, image_handle
    ldr x0, [x0, :lo12:image_handle]
    address x1, loaded_image_guid
    add x2, sp, #16
    ldr x3, [x19, #152]         // HandleProtocol
    blr x3
    cbnz x0, 1f
    ldr x0, [sp, #16]
    ldr x0, [x0, #24]           // DeviceHandle
    address x1, disk_path_guid
    add x2, sp, #24
    ldr x3, [x19, #152]
    blr x3
    cbz x0, 1f
    str xzr, [sp, #24]
1:
    ldr x26, [sp, #24]          // boot device path, or 0
    mov x0, x26
    bl disk_path_length
    mov x27, x0
    // LocateHandleBuffer(ByProtocol, BlockIo, NULL, &count, &buffer)
    mov x0, #2
    address x1, block_io_guid
    mov x2, #0
    mov x3, sp
    add x4, sp, #8
    ldr x5, [x19, #312]
    blr x5
    cbnz x0, 8f
    ldr x20, [sp]               // handles
    ldr x21, [sp, #8]           // buffer
    mov x22, #0                 // index
    mov x23, #0                 // disks found
2:
    cmp x22, x20
    b.hs 7f
    cmp x23, #DISK_MAX
    b.hs 7f
    ldr x24, [x21, x22, lsl #3]
    add x22, x22, #1
    mov x0, x24
    address x1, block_io_guid
    add x2, sp, #16
    ldr x3, [x19, #152]
    blr x3
    cbnz x0, 2b
    ldr x25, [sp, #16]
    ldr x9, [x25, #8]
    ldrb w10, [x9, #5]          // MediaPresent
    cbz w10, 2b
    ldrb w10, [x9, #6]          // LogicalPartition
    cbnz w10, 2b
    ldrb w10, [x9, #7]          // ReadOnly
    cbnz w10, 2b
    ldr w10, [x9, #12]
    cmp x10, #512
    b.lo 2b
    cmp x10, #4096
    b.hi 2b
    ldr x10, [x9, #24]          // a disk of at least 8 MiB
    cmp x10, #16384
    b.lo 2b
    cbz x26, 4f
    mov x0, x24
    address x1, disk_path_guid
    add x2, sp, #16
    ldr x3, [x19, #152]
    blr x3
    cbnz x0, 4f
    ldr x0, [sp, #16]
    bl disk_path_length
    cbz x0, 4f
    cmp x0, x27
    b.hi 4f
    ldr x9, [sp, #16]           // the boot partition lies on this disk?
    mov x10, #0
3:
    ldrb w11, [x9, x10]
    ldrb w12, [x26, x10]
    cmp w11, w12
    b.ne 4f
    add x10, x10, #1
    cmp x10, x0
    b.lo 3b
    b 2b
4:
    address x9, disk_bio
    str x25, [x9, x23, lsl #3]
    add x23, x23, #1
    b 2b
7:
    address x9, disk_count
    str x23, [x9]
    mov x0, x21
    ldr x9, [x19, #72]          // FreePool
    blr x9
8:
    adrp x0, disk_count
    ldr x0, [x0, :lo12:disk_count]
    mov x1, #0
    add sp, sp, #32
    leave

// x0 = device path (or 0): its length in bytes without the end node. Leaf.
disk_path_length:
    mov x9, #0
    cbz x0, 2f
1:
    ldrb w10, [x0, x9]
    add x11, x9, #1
    ldrb w11, [x0, x11]
    cmp w10, #0x7f
    b.ne 3f
    cmp w11, #0xff
    b.eq 2f
3:
    add x11, x9, #2
    ldrb w12, [x0, x11]
    add x11, x9, #3
    ldrb w13, [x0, x11]
    orr w12, w12, w13, lsl #8
    cmp w12, #4
    b.lo 2f
    add x9, x9, x12
    cmp x9, #4096               // a sane bound
    b.lo 1b
2:
    mov x0, x9
    ret

.section .rodata
.balign 4
disk_path_guid:                 // EFI_DEVICE_PATH_PROTOCOL
    .long 0x09576e91
    .short 0x6d3f, 0x11d2
    .byte 0x8e,0x39,0x00,0xa0,0xc9,0x69,0x72,0x3b
.section .bss
.balign 8
disk_count: .skip 8
disk_bio: .skip DISK_MAX * 8
disk_bounce: .skip 8
disk_part_bio: .skip DISK_PARTS * 8
disk_part_start: .skip DISK_PARTS * 8
.section .text
