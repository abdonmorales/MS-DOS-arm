// SPDX-License-Identifier: MIT
// ARM DOS extension E0h: raw disk services for INSTALL. DOS reached whole
// disks through INT 13h (FDISK, FORMAT); here the firmware's Block I/O
// protocol plays that part. It is only available while UEFI boot services
// run (firmware mode, as the live ISO always is). A disk is a whole-disk
// Block I/O handle that is present, writable and provably not the one ARM
// DOS booted from: when either device path cannot be read, no disk is
// offered. Every transfer checks the medium against the MediaId recorded
// when the disk was found (or the partition attached), so a swapped medium
// is refused, not written.
//
// x0 = subfunction:
//   0  find disks: x0 = their count (0 in native mode)
//   1  x1 = disk, x2 = 32-byte buffer: u64 block size, u64 blocks,
//      u64 flags (1 removable), u64 reserved
//   2  read, 3 write: x1 = disk, x2 = first block, x3 = blocks, x4 = buffer
//   4  attach: x1 = disk, x2 = first block, x3 = blocks: mounts that range
//      (a partition) as a drive letter; x0 = the drive (0 = A:). The same
//      range attached again returns its drive; an overlapping one fails.
//   5  flush: x1 = disk
//   6  probe: as 4, but changes nothing; x0 = the drive 4 would return
.equ DISK_MAX, 8
.equ DISK_PARTS, 4
.equ DISK_BOUNCE_PAGES, 16      // 64 KiB, page aligned for any IoAlign
.equ DISK_CHANGED, 34           // DOS error: invalid disk change

.macro ldv_bs reg
    adrp \reg, boot_services
    ldr \reg, [\reg, :lo12:boot_services]
.endm

.section .text
.global disk_services
disk_services:
    cmp x0, #0
    b.eq disk_find
    cmp x0, #6
    b.hi disk_bad_function
    adrp x9, disk_count
    ldr x9, [x9, :lo12:disk_count]
    cmp x1, x9
    b.hs disk_bad_disk
    address x9, disk_media
    ldr x10, [x9, x1, lsl #3]   // MediaId when the disk was found
    address x9, disk_bio
    ldr x9, [x9, x1, lsl #3]    // the disk's EFI_BLOCK_IO_PROTOCOL
    cmp x0, #1
    b.eq disk_info
    cmp x0, #4
    b.eq disk_attach
    cmp x0, #6
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
    mov x26, x10                // MediaId
    mov x0, x19
    mov x1, x26
    mov x2, x20
    bl disk_media_check
    cbnz x0, 7f
    ldr x9, [x19, #8]
    ldr x10, [x9, #24]          // LastBlock
    add x10, x10, #1
    adds x11, x21, x22          // the range must lie on the disk
    b.cs 6f
    cmp x11, x10
    b.hi 6f
    bl disk_bounce_buffer
    cbz x0, 9f
    mov x24, x0
    ldr x2, [x19, #8]
    ldr w25, [x2, #12]          // BlockSize
    mov x27, #(DISK_BOUNCE_PAGES * 4096)
    udiv x27, x27, x25          // blocks per transfer
1:
    cbz x22, 8f
    cmp x22, x27
    csel x9, x22, x27, lo
    str x9, [sp, #-16]!
    mul x28, x9, x25            // bytes this time
    cbz x20, 2f
    mov x0, x23
    mov x1, x24
    mov x2, x28
    bl disk_copy
    mov x0, #32                 // WriteBlocks
    bl disk_transfer
    cbnz x0, 5f
    b 3f
2:
    mov x0, #24                 // ReadBlocks
    bl disk_transfer
    cbnz x0, 5f
    mov x0, x24
    mov x1, x23
    mov x2, x28
    bl disk_copy
3:
    ldr x9, [sp], #16
    add x21, x21, x9
    sub x22, x22, x9
    add x23, x23, x28
    b 1b
5:
    add sp, sp, #16
    b 9f
6:
    mov x0, #87                 // invalid parameter
    mov x1, #1
    leave
7:
    mov x1, #1                  // x0 = the media check's error
    leave
8:
    mov x0, #0
    mov x1, #0
    leave
9:
    mov x0, #21                 // drive not ready
    mov x1, #1
    leave

// x0 = Block I/O offset (24 read, 32 write); x19 protocol, x21 block,
// x24 bounce buffer, x26 MediaId, x28 bytes. Returns the EFI status.
disk_transfer:
    frame
    mov x9, x0
    mov x0, x19
    mov x1, x26
    mov x2, x21
    mov x3, x28
    mov x4, x24
    ldr x5, [x19, x9]
    blr x5
    unframe

// x0 = protocol, x1 = expected MediaId, x2 = 1 for a write. Returns x0 = 0
// when the same medium is present (and writable for a write), else the
// DOS error. Leaf.
disk_media_check:
    ldr x9, [x0, #8]
    ldrb w10, [x9, #5]          // MediaPresent
    cbz w10, 1f
    ldr w10, [x9]               // MediaId
    cmp x10, x1
    b.ne 1f
    cbz x2, 2f
    ldrb w10, [x9, #7]          // ReadOnly
    cbz w10, 2f
    mov x0, #19                 // write protected
    ret
1:
    mov x0, #DISK_CHANGED
    ret
2:
    mov x0, #0
    ret

// x0 = source, x1 = destination, x2 = bytes (a multiple of 512). Leaf.
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

// Attach (x0 = 4) or probe (6): x9 protocol, x10 MediaId, x2 first block,
// x3 blocks. A partition slot records the protocol, range and MediaId; its
// rw entry (disk_part_rwN) is what the drive table calls.
disk_attach:
    enter
    cmp x0, #4
    cset x19, eq                // 1: attach, 0: probe
    mov x20, x9
    mov x21, x10
    mov x22, x2
    mov x23, x3
    mov x0, x20
    mov x1, x21
    mov x2, #1
    bl disk_media_check
    cbnz x0, 97f
    adrp x9, fat_cache_buffers  // no sector cache: no block drives at all
    ldr x9, [x9, :lo12:fat_cache_buffers]
    cbz x9, 95f
    ldr x12, [x20, #8]
    ldr w24, [x12, #12]         // BlockSize
    ldr x14, [x12, #24]         // LastBlock
    add x14, x14, #1
    cbz x23, 98f
    adds x15, x22, x23          // the range must lie on the disk
    b.cs 98f
    cmp x15, x14
    b.hi 98f
    // The same range again: its drive. An overlapping range: refused.
    address x10, disk_part_bio
    address x11, disk_part_start
    address x12, disk_part_len
    mov x25, #-1                // a free slot
    mov x13, #0
1:
    ldr x14, [x10, x13, lsl #3]
    cbnz x14, 2f
    cmn x25, #1
    csel x25, x13, x25, eq
    b 4f
2:
    cmp x14, x20
    b.ne 4f
    ldr x16, [x11, x13, lsl #3]
    ldr x17, [x12, x13, lsl #3]
    cmp x16, x22
    b.ne 3f
    cmp x17, x23
    b.eq 50f
3:
    add x17, x16, x17           // overlap: start < s + l and s < end
    cmp x22, x17
    b.hs 4f
    cmp x16, x15
    b.lo 96f
4:
    add x13, x13, #1
    cmp x13, #DISK_PARTS
    b.lo 1b
    cmn x25, #1
    b.eq 94f
    bl drive_next_free
    cmp x0, #DRIVES
    b.hs 99f
    adrp x9, fat_vol_count
    ldr x9, [x9, :lo12:fat_vol_count]
    cmp x9, #FAT_VOLS
    b.hs 94f
    cbz x19, 90f                // probe: that letter
    address x10, disk_part_bio
    str x20, [x10, x25, lsl #3]
    address x10, disk_part_start
    str x22, [x10, x25, lsl #3]
    address x10, disk_part_len
    str x23, [x10, x25, lsl #3]
    address x10, disk_part_media
    str x21, [x10, x25, lsl #3]
    adr x0, disk_part_rw0
    add x0, x0, x25, lsl #3     // each entry is two instructions
    mov x1, x24
    mov x2, x23
    bl drive_add_block
    cbnz x1, 5f
    address x10, disk_part_drive
    str x0, [x10, x25, lsl #3]
    b 90f
5:
    address x10, disk_part_bio  // no letter or volume left: free the slot
    str xzr, [x10, x25, lsl #3]
    b 99f
50:
    address x10, disk_part_drive
    ldr x24, [x10, x13, lsl #3]
    cbz x19, 51f
    address x10, disk_part_media
    str x21, [x10, x13, lsl #3]
    mov x0, x24                 // re-read whatever is there now
    bl drive_remount
51:
    mov x0, x24
90:
    mov x1, #0
    leave
94:
    mov x0, #4                  // no partition slot or volume left
    b 9f
95:
    mov x0, #8                  // insufficient memory
    b 9f
96:
    mov x0, #5                  // access denied: overlaps an attached range
    b 9f
97:
    b 9f                        // x0 = the media check's error
98:
    mov x0, #87                 // invalid parameter
    b 9f
99:
    mov x0, #15                 // no drive letter left
9:
    mov x1, #1
    leave

// rw(x0 = sector, x1 = buffer, x2 = count, x3 = 1 to write) for each slot.
// The buffer is a page-aligned sector cache slot. Returns x0 = 0, or 1.
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
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x20, x3
    mov x21, x1
    address x10, disk_part_bio
    ldr x19, [x10, x9, lsl #3]
    cbz x19, 8f
    address x10, disk_part_len  // stay inside the partition
    ldr x10, [x10, x9, lsl #3]
    adds x11, x0, x2
    b.cs 8f
    cmp x11, x10
    b.hi 8f
    address x10, disk_part_start
    ldr x10, [x10, x9, lsl #3]
    add x22, x10, x0            // disk block
    address x10, disk_part_media
    ldr x10, [x10, x9, lsl #3]
    str x10, [sp, #-16]!
    str x2, [sp, #8]
    mov x0, x19
    mov x1, x10
    mov x2, x20
    bl disk_media_check
    ldr x2, [sp, #8]
    ldr x1, [sp], #16
    cbnz x0, 8f
    ldr x11, [x19, #8]
    ldr w12, [x11, #12]
    mul x3, x2, x12             // bytes
    mov x2, x22
    mov x4, x21
    mov x0, x19
    mov x9, #24                 // ReadBlocks
    cbz x20, 1f
    mov x9, #32                 // WriteBlocks
1:
    ldr x5, [x19, x9]
    blr x5
    cbnz x0, 8f
    cbz x20, 7f
    ldr x11, [x19, #8]
    ldrb w11, [x11, #8]         // WriteCaching: written through
    cbz w11, 7f
    mov x0, x19
    ldr x5, [x19, #40]          // FlushBlocks
    blr x5
    cbnz x0, 8f
7:
    mov x0, #0
    b 9f
8:
    mov x0, #1
9:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// Find: every Block I/O handle that is a whole, present, writable disk
// whose device path is known and not a prefix of the boot device's.
disk_find:
    enter
    sub sp, sp, #32
    address x9, disk_count
    str xzr, [x9]
    ldv_bs x19
    adrp x9, platform_native
    ldr x9, [x9, :lo12:platform_native]
    cbnz x9, 8f                 // no firmware left: no disks to offer
    // The boot device's path (the partition ARM DOS was loaded from). If
    // it cannot be read, no disk can be shown not to hold it: offer none.
    adrp x0, image_handle
    ldr x0, [x0, :lo12:image_handle]
    address x1, loaded_image_guid
    add x2, sp, #16
    ldr x3, [x19, #152]         // HandleProtocol
    blr x3
    cbnz x0, 8f
    ldr x0, [sp, #16]
    ldr x0, [x0, #24]           // DeviceHandle
    cbz x0, 8f
    address x1, disk_path_guid
    add x2, sp, #24
    ldr x3, [x19, #152]
    blr x3
    cbnz x0, 8f
    ldr x26, [sp, #24]          // boot device path
    cbz x26, 8f
    mov x0, x26
    bl disk_path_length
    mov x27, x0
    cbz x27, 8f
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
    ldr w10, [x9, #12]          // BlockSize: 512-4096, a power of two
    cmp x10, #512
    b.lo 2b
    cmp x10, #4096
    b.hi 2b
    sub x11, x10, #1
    tst x10, x11
    b.ne 2b
    ldr w11, [x9, #16]          // IoAlign: the bounce buffer is 4 KiB aligned
    cmp x11, #4096
    b.hi 2b
    ldr x11, [x9, #24]          // a disk of at least 8 MiB
    add x11, x11, #1
    mul x11, x11, x10
    cmp x11, #0x800000
    b.lo 2b
    // A disk whose path is unknown or empty cannot be told apart from the
    // boot disk: skip it.
    mov x0, x24
    address x1, disk_path_guid
    add x2, sp, #16
    ldr x3, [x19, #152]
    blr x3
    cbnz x0, 2b
    ldr x0, [sp, #16]
    cbz x0, 2b
    bl disk_path_length
    cbz x0, 2b
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
    ldr x10, [x25, #8]
    ldr w10, [x10]              // MediaId now: later transfers must match
    address x9, disk_media
    str x10, [x9, x23, lsl #3]
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
    b.lo 4f
    add x9, x9, x12
    cmp x9, #4096               // a sane bound
    b.lo 1b
4:
    mov x9, #0                  // malformed: treated as unknown
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
disk_media: .skip DISK_MAX * 8
disk_bounce: .skip 8
disk_part_bio: .skip DISK_PARTS * 8
disk_part_start: .skip DISK_PARTS * 8
disk_part_len: .skip DISK_PARTS * 8
disk_part_media: .skip DISK_PARTS * 8
disk_part_drive: .skip DISK_PARTS * 8
.section .text
