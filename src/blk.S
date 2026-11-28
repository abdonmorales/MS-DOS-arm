// SPDX-License-Identifier: MIT
// Multi-disk block layer for the native kernel (after ExitBootServices).
//
// Every disk the kernel can reach is registered in one disk table; each
// registration scans the disk's partition table and mounts its FAT volumes
// as drive letters. The boot disk (virtio-blk, already driving A:) and every
// further virtio-blk PCI device are registered at boot by blk_init; other
// backends (USB mass storage, ...) call disk_register themselves.
//
// disk_register:
//   x0 = rw function, x1 = sector count, x2 = context (passed back to rw),
//   x3 = sector size (0 = 512; 512-4096, a power of two), x4 = flags
//   (bit 1 removable, reported by E0h subfunction 1; bit 0 is reserved for
//   the boot disk). Returns x0 = the disk number, x1 = 0; or x1 = 1 with
//   x0 = 4 (table full, 8 disks) or 87 (bad argument). Before returning it
//   scans the disk and mounts its FAT volumes (rules below).
//   The rw function is called as
//     rw(x0 = first sector, x1 = count, x2 = buffer, w3 = 0 read / 1 write,
//        x4 = context) -> x0 = 0, or nonzero on a device error,
//   with the AAPCS64 rules (x0-x18 may be clobbered). The layer guarantees
//   count >= 1, first + count <= the sector count, a 4 KiB aligned buffer
//   and at most 64 KiB per call. A write must be on the medium (or at least
//   ordered before later reads) when rw returns: nothing flushes later.
//
// Drive letters: fixed-disk volumes take the first free letter from C:
// upward (A: is the boot volume; B: is left to the first CONFIG.SYS block
// driver, as DOS kept it for the second floppy). blk_init runs before
// CONFIG.SYS, so the disks get C:, D:, ... in disk order (the boot disk's
// other partitions, then each further disk in PCI order), partitions in
// table order, and RAMDRIVE/VDISK take the letters left free after them.
// Letters go past LASTDRIVE when needed, as for block drivers. A volume is
// mounted when its partition type is FAT (MBR 01h, 04h, 06h, 0Bh, 0Ch, 0Eh,
// EFh, and the logical drives of an extended partition 05h/0Fh; GPT EFI
// System and Basic Data) and its first sector is a FAT boot record; a disk
// without a partition table whose sector 0 is a FAT boot record is mounted
// whole. Every table field is checked against the disk size; EBR chains
// must move forward and stop after 16 links; GPT reads at most 128 entries.
//
// The native E0h disk services (blk_services) offer every registered disk
// except the boot disk, in registration order.
.equ BLK_DISKS, 8
.equ BLK_RW, 0
.equ BLK_CTX, 8
.equ BLK_BLOCKS, 16
.equ BLK_BSIZE, 24
.equ BLK_FLAGS, 32
.equ BLKF_BOOT, 1
.equ BLKF_REMOVABLE, 2
.equ BLK_PARTS, 16              // mounted ranges (FAT_VOLS bounds them too)
.equ BLK_BOUNCE_SIZE, 65536
.equ BLK_VIO_MAX, 7
.equ VB_COMMON, 0
.equ VB_NOTIFY, 8               // queue 0's notify address
.equ VB_QUEUE, 16
.equ VB_SEEN, 24
.equ VB_DEVICE, 32
.equ VB_NBASE, 40
.equ VB_NMUL, 48
.equ VB_PCI, 56

.section .text

// Registers the boot disk and the other virtio-blk disks (native mode).
blk_init:
    enter
    ldv x9, platform_native
    cbz x9, 9f
    ldv x9, plat_disk_kind      // the Pi's SD card: no size known, A: only
    cbnz x9, 9f
    address x19, blk_vio_boot
    ldv x0, vio_pci
    mov x1, x19
    bl vblk_caps
    cbnz x0, 1f
    ldr x9, [x19, #VB_DEVICE]
    ldr w1, [x9]                // capacity, in 512-byte sectors
    ldr w2, [x9, #4]
    orr x1, x1, x2, lsl #32
    address x0, blk_boot_rw
    mov x2, #0
    mov x3, #512
    mov x4, #BLKF_BOOT
    bl disk_register
1:
    bl blk_virtio_scan
9:
    leave

// The boot disk's rw: vio_rw adds the boot partition's offset.
blk_boot_rw:
    ldv x9, vio_part_lba
    sub x0, x0, x9
    b vio_rw

.global disk_register
disk_register:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    cbnz x22, 1f
    mov x22, #512
1:
    cbz x19, 8f
    cbz x20, 8f
    cmp x22, #512
    b.lo 8f
    cmp x22, #4096
    b.hi 8f
    sub x9, x22, #1
    tst x9, x22
    b.ne 8f
    ldv x24, blk_count
    cmp x24, #BLK_DISKS
    b.hs 7f
    address x9, blk_disks
    add x9, x9, x24, lsl #6
    str x19, [x9, #BLK_RW]
    str x21, [x9, #BLK_CTX]
    str x20, [x9, #BLK_BLOCKS]
    str x22, [x9, #BLK_BSIZE]
    str x23, [x9, #BLK_FLAGS]
    add x2, x24, #1
    stv x2, blk_count, x3
    mov x0, x24
    bl blk_scan
    mov x0, x24
    mov x1, #0
    leave
7:
    mov x0, #4
    b 9f
8:
    mov x0, #87
9:
    mov x1, #1
    leave

// x0 = disk, x1 = first sector, x2 = count, x3 = buffer, x4 = 1 to write.
// Returns x0 = 0, or 1 (bad disk, range off the disk, device error).
blk_rw:
    frame
    ldv x9, blk_count
    cmp x0, x9
    b.hs 8f
    cbz x2, 7f
    address x9, blk_disks
    add x9, x9, x0, lsl #6
    ldr x10, [x9, #BLK_BLOCKS]
    adds x11, x1, x2
    b.cs 8f
    cmp x11, x10
    b.hi 8f
    mov x0, x1
    mov x1, x2
    mov x2, x3
    mov w3, w4
    ldr x4, [x9, #BLK_CTX]
    ldr x5, [x9, #BLK_RW]
    blr x5
    cmp x0, #0
    cset x0, ne
    unframe
7:
    mov x0, #0
    unframe
8:
    mov x0, #1
    unframe

// rw(x0 = sector, x1 = buffer, x2 = count, x3 = 1 to write) of each mounted
// range, as the drive table and FAT driver call block drivers.
blk_part_rw0:
.irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    mov x9, #\n
    b blk_part_rw
.endr
blk_part_rw:
    address x10, blk_part_disk
    ldr x11, [x10, x9, lsl #3]
    cbz x11, 8f
    address x10, blk_part_len   // stay inside the range
    ldr x12, [x10, x9, lsl #3]
    adds x13, x0, x2
    b.cs 8f
    cmp x13, x12
    b.hi 8f
    address x10, blk_part_start
    ldr x12, [x10, x9, lsl #3]
    mov x4, x3
    mov x3, x1
    add x1, x12, x0
    sub x0, x11, #1
    b blk_rw
8:
    mov x0, #1
    ret

// x0 = disk, x1 = first sector, x2 = sectors, x3 = 1 attach / 0 probe.
// Mounts that range as the next free drive letter from C:. The same range
// again returns its drive (an attach re-reads its boot record); a range
// overlapping a mounted one fails. Returns x0 = drive (0 = A:), x1 = 0; or
// x1 = 1 with x0 = 4 (no slot or volume), 5 (overlap), 8 (no sector cache),
// 15 (bad disk or no letter), 87 (range off the disk).
blk_attach:
    enter
    mov x19, x3
    mov x20, x0
    mov x22, x1
    mov x23, x2
    adrp x9, fat_cache_buffers
    ldr x9, [x9, :lo12:fat_cache_buffers]
    cbz x9, 95f
    ldv x9, blk_count
    cmp x20, x9
    b.hs 99f
    address x9, blk_disks
    add x21, x9, x20, lsl #6
    cbz x23, 98f
    adds x15, x22, x23
    b.cs 98f
    ldr x14, [x21, #BLK_BLOCKS]
    cmp x15, x14
    b.hi 98f
    add x26, x20, #1            // slot tag: disk + 1
    address x10, blk_part_disk
    address x11, blk_part_start
    address x12, blk_part_len
    mov x25, #-1                // a free slot
    mov x13, #0
1:
    ldr x14, [x10, x13, lsl #3]
    cbnz x14, 2f
    cmn x25, #1
    csel x25, x13, x25, eq
    b 4f
2:
    cmp x14, x26
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
    cmp x13, #BLK_PARTS
    b.lo 1b
    cmn x25, #1
    b.eq 94f
    mov x0, #2
    bl drive_next_free_from
    cmp x0, #DRIVES
    b.hs 99f
    ldv x9, fat_vol_count
    cmp x9, #FAT_VOLS
    b.hs 94f
    cbz x19, 90f                // probe: that letter
    address x10, blk_part_disk
    str x26, [x10, x25, lsl #3]
    address x10, blk_part_start
    str x22, [x10, x25, lsl #3]
    address x10, blk_part_len
    str x23, [x10, x25, lsl #3]
    address x0, blk_part_rw0
    add x0, x0, x25, lsl #3     // each entry is two instructions
    ldr x1, [x21, #BLK_BSIZE]
    mov x2, x23
    mov x3, #2
    bl drive_add_block_from
    cbnz x1, 5f
    address x10, blk_part_drive
    str x0, [x10, x25, lsl #3]
    b 90f
5:
    address x10, blk_part_disk
    str xzr, [x10, x25, lsl #3]
    b 99f
50:
    address x10, blk_part_drive
    ldr x24, [x10, x13, lsl #3]
    cbz x19, 51f
    mov x0, x24
    bl drive_remount
    mov x0, x24
    bl drive_entry
    mov w9, #'\\'
    strh w9, [x0, #DRV_CWD]
51:
    mov x0, x24
90:
    mov x1, #0
    leave
94:
    mov x0, #4
    b 9f
95:
    mov x0, #8
    b 9f
96:
    mov x0, #5
    b 9f
98:
    mov x0, #87
    b 9f
99:
    mov x0, #15
9:
    mov x1, #1
    leave

// x0 = sector of the disk being scanned, x1 = 4 KiB buffer: reads it.
// Returns x0 = 0, or 1.
blk_read:
    mov x3, x1
    mov x1, x0
    ldv x0, blk_cur_disk
    mov x2, #1
    mov x4, #0
    b blk_rw

// x0 = sector buffer, x1 = sector size. Returns x0 = 0 when it holds a FAT
// boot record (signature, jump, BPB sector size, sectors per cluster,
// reserved sectors, FAT count and media byte all plausible). Leaf.
blk_is_fat:
    ldrb w9, [x0, #510]
    cmp w9, #0x55
    b.ne 8f
    ldrb w9, [x0, #511]
    cmp w9, #0xaa
    b.ne 8f
    ldrb w9, [x0]
    cmp w9, #0xeb
    b.eq 1f
    cmp w9, #0xe9
    b.ne 8f
1:
    le16 w9, x0, 11, w10
    cmp x9, x1
    b.ne 8f
    ldrb w9, [x0, #13]
    cbz w9, 8f
    sub w10, w9, #1
    tst w9, w10
    b.ne 8f
    le16 w9, x0, 14, w10
    cbz w9, 8f
    ldrb w9, [x0, #16]
    cbz w9, 8f
    cmp w9, #2
    b.hi 8f
    ldrb w9, [x0, #21]
    cmp w9, #0xf0
    b.lo 8f
    mov x0, #0
    ret
8:
    mov x0, #1
    ret

// w0 = MBR partition type. Returns x0 = 1 for the FAT types. Leaf.
blk_fat_type:
    and w0, w0, #0xff
    adr x9, blk_fat_types
1:
    ldrb w10, [x9], #1
    cbz w10, 2f
    cmp w10, w0
    b.ne 1b
    mov x0, #1
    ret
2:
    mov x0, #0
    ret
blk_fat_types: .byte 0x01, 0x04, 0x06, 0x0b, 0x0c, 0x0e, 0xef, 0
.balign 4

// x0 = disk: finds its FAT volumes and mounts them.
blk_scan:
    enter
    mov x19, x0
    address x9, blk_disks
    add x20, x9, x19, lsl #6
    stv x19, blk_cur_disk, x9
    ldr x9, [x20, #BLK_BLOCKS]
    stv x9, blk_cur_blocks, x10
    ldr x9, [x20, #BLK_BSIZE]
    stv x9, blk_cur_bsize, x10
    ldr x9, [x20, #BLK_FLAGS]
    stv x9, blk_cur_flags, x10
    mov x0, #0
    address x1, blk_table
    bl blk_read
    cbnz x0, 9f
    address x0, blk_table
    ldv x1, blk_cur_bsize
    bl blk_is_fat
    cbnz x0, 1f
    mov x0, #0                  // a FAT over the whole disk
    ldv x1, blk_cur_blocks
    mov x2, #0
    bl blk_try                  // (on the boot disk that is A: itself)
    b 9f
1:
    address x23, blk_table
    ldrb w9, [x23, #510]
    cmp w9, #0x55
    b.ne 9f
    ldrb w9, [x23, #511]
    cmp w9, #0xaa
    b.ne 9f
    mov x24, #0
2:
    add x9, x23, #446           // a protective MBR: the disk is GPT
    add x9, x9, x24, lsl #4
    ldrb w10, [x9, #4]
    cmp w10, #0xee
    b.eq 30f
    add x24, x24, #1
    cmp x24, #4
    b.lo 2b
    address x9, blk_mbr         // keep the table: blk_table is reused
    mov x10, #0
21:
    add x11, x23, x10
    ldrb w12, [x11, #446]
    strb w12, [x9, x10]
    add x10, x10, #1
    cmp x10, #64
    b.lo 21b
    mov x24, #0
3:
    address x25, blk_mbr
    add x25, x25, x24, lsl #4
    ldrb w26, [x25, #4]
    add x0, x25, #8
    bl plat_ld32
    mov x27, x0
    add x0, x25, #12
    bl plat_ld32
    mov x28, x0
    mov w0, w26
    bl blk_fat_type
    cbz x0, 4f
    mov x0, x27
    mov x1, x28
    add x2, x24, #1
    bl blk_try
    b 5f
4:
    cmp w26, #0x05
    b.eq 41f
    cmp w26, #0x0f
    b.ne 5f
41:
    mov x0, x27
    mov x1, x28
    bl blk_extended
5:
    add x24, x24, #1
    cmp x24, #4
    b.lo 3b
    b 9f
30:
    bl blk_gpt
9:
    leave

// x0 = first sector, x1 = sectors of an extended partition: mounts the FAT
// logical drives of its EBR chain (numbered from 5).
blk_extended:
    enter
    mov x19, x0
    mov x20, x1
    cbz x19, 9f
    cbz x20, 9f
    adds x9, x19, x20
    b.cs 9f
    ldv x10, blk_cur_blocks
    cmp x9, x10
    b.hi 9f
    mov x21, x19                // this EBR
    mov x22, #16                // links at most
    mov x23, #5                 // partition number
1:
    mov x0, x21
    address x1, blk_table
    bl blk_read
    cbnz x0, 9f
    address x24, blk_table
    ldrb w9, [x24, #510]
    cmp w9, #0x55
    b.ne 9f
    ldrb w9, [x24, #511]
    cmp w9, #0xaa
    b.ne 9f
    // The next EBR (entry 2, relative to the extended partition): it must
    // lie after this one and inside the extended partition.
    mov x27, #0
    ldrb w9, [x24, #(446 + 16 + 4)]
    cmp w9, #0x05
    b.eq 11f
    cmp w9, #0x0f
    b.ne 12f
11:
    add x0, x24, #(446 + 16 + 8)
    bl plat_ld32
    add x9, x19, x0
    cmp x9, x21
    b.ls 12f
    add x10, x19, x20
    cmp x9, x10
    b.hs 12f
    mov x27, x9
12:
    ldrb w26, [x24, #(446 + 4)] // entry 1: the logical drive, relative
    add x0, x24, #(446 + 8)     // to this EBR
    bl plat_ld32
    mov x25, x0
    add x0, x24, #(446 + 12)
    bl plat_ld32
    mov x28, x0
    cbz x25, 2f
    mov w0, w26
    bl blk_fat_type
    cbz x0, 2f
    add x0, x21, x25
    mov x1, x28
    mov x2, x23
    bl blk_try
2:
    add x23, x23, #1
    cbz x27, 9f
    mov x21, x27
    subs x22, x22, #1
    b.ne 1b
9:
    leave

// GPT (after a protective MBR): mounts EFI System and Basic Data
// partitions. The header and entry array are bounded, not CRC checked.
blk_gpt:
    enter
    mov x0, #1
    address x1, blk_table
    bl blk_read
    cbnz x0, 9f
    address x19, blk_table
    ldr x9, [x19]
    address x10, blk_gpt_sig
    ldr x10, [x10]
    cmp x9, x10
    b.ne 9f
    ldv x23, blk_cur_bsize
    ldr w9, [x19, #12]          // header size
    cmp x9, #92
    b.lo 9f
    cmp x9, x23
    b.hi 9f
    ldr x20, [x19, #72]         // first sector of the entries
    ldr w21, [x19, #80]         // entries
    ldr w22, [x19, #84]         // entry size
    cmp x21, #128
    mov x9, #128
    csel x21, x9, x21, hi
    cmp x22, #128
    b.lo 9f
    cmp x22, x23
    b.hi 9f
    sub x9, x22, #1
    tst x9, x22
    b.ne 9f
    cmp x20, #2
    b.lo 9f
    mul x9, x21, x22            // the array must lie on the disk
    add x9, x9, x23
    sub x9, x9, #1
    udiv x9, x9, x23
    adds x10, x20, x9
    b.cs 9f
    ldv x11, blk_cur_blocks
    cmp x10, x11
    b.hi 9f
    mov x24, #0                 // entry
    mov x25, #-1                // sector in blk_gpt_buf
1:
    cmp x24, x21
    b.hs 9f
    mul x9, x24, x22
    udiv x10, x9, x23
    add x26, x20, x10
    cmp x26, x25
    b.eq 2f
    mov x0, x26
    address x1, blk_gpt_buf
    bl blk_read
    cbnz x0, 9f
    mov x25, x26
2:
    mul x9, x24, x22
    udiv x10, x9, x23
    msub x11, x10, x23, x9
    address x27, blk_gpt_buf
    add x27, x27, x11
    ldp x9, x10, [x27]
    address x12, blk_guid_esp
    ldp x13, x14, [x12]
    cmp x9, x13
    ccmp x10, x14, #0, eq
    b.eq 3f
    address x12, blk_guid_data
    ldp x13, x14, [x12]
    cmp x9, x13
    ccmp x10, x14, #0, eq
    b.ne 4f
3:
    ldr x0, [x27, #32]          // first and last sector
    ldr x9, [x27, #40]
    cmp x9, x0
    b.lo 4f
    sub x1, x9, x0
    add x1, x1, #1
    add x2, x24, #1
    bl blk_try
4:
    add x24, x24, #1
    b 1b
9:
    leave

// x0 = first sector, x1 = sectors, x2 = partition number (0: whole disk)
// on the disk being scanned: mounts it when it is on the disk, is not the
// boot volume and starts with a FAT boot record; reports the letter.
blk_try:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    cbz x20, 9f
    adds x9, x19, x20
    b.cs 9f
    ldv x10, blk_cur_blocks
    cmp x9, x10
    b.hi 9f
    ldv x9, blk_cur_flags
    tbz x9, #0, 1f
    cbz x19, 9f                 // the boot disk: never A:'s range again
    ldv x10, vio_part_lba
    cmp x10, x19
    b.lo 1f
    add x11, x19, x20
    cmp x10, x11
    b.lo 9f
1:
    mov x0, x19
    address x1, blk_sector
    bl blk_read
    cbnz x0, 9f
    address x0, blk_sector
    ldv x1, blk_cur_bsize
    bl blk_is_fat
    cbnz x0, 9f
    ldv x0, blk_cur_disk
    mov x1, x19
    mov x2, x20
    mov x3, #1
    bl blk_attach
    cbnz x1, 9f
    // "Drive C: is disk 1, partition 2"
    address x22, blk_msg
    address x9, blk_msg_drive
    mov x10, #0
2:
    ldrb w11, [x9, x10]
    strb w11, [x22, x10]
    add x10, x10, #1
    cbnz w11, 2b
    add w0, w0, #'A'
    strb w0, [x22, #6]
    add x22, x22, #17
    ldv x0, blk_cur_disk
    mov x1, x22
    bl blk_dec
    mov x22, x0
    cbz x21, 3f
    address x9, blk_msg_part
    mov x10, #0
31:
    ldrb w11, [x9, x10]
    strb w11, [x22], #1
    add x10, x10, #1
    cmp x10, #12
    b.lo 31b
    mov x0, x21
    mov x1, x22
    bl blk_dec
    mov x22, x0
3:
    mov w9, #'\r'
    strb w9, [x22]
    mov w9, #'\n'
    strb w9, [x22, #1]
    strb wzr, [x22, #2]
    address x0, blk_msg
    bl puts
9:
    leave

// x0 = value (< 1000), x1 = destination. Returns x0 = the end. Leaf.
blk_dec:
    mov x9, #100
    mov x12, #0                 // a digit written
1:
    udiv x10, x0, x9
    msub x0, x10, x9, x0
    cbnz x10, 2f
    cbnz x12, 2f
    cmp x9, #1
    b.ne 3f
2:
    add w10, w10, #'0'
    strb w10, [x1], #1
    mov x12, #1
3:
    mov x10, #10
    udiv x9, x9, x10
    cbnz x9, 1b
    mov x0, x1
    ret

// ---------------------------------------------------------------------------
// E0h disk services in native mode (see disks.S and ABI.md): the disks are
// the registered ones except the boot disk.

// x0 = offered disk index. Returns x0 = the table index, or -1. Leaf.
blk_offered:
    ldv x9, blk_count
    address x10, blk_disks
    mov x11, #0
1:
    cmp x11, x9
    b.hs 3f
    ldr x12, [x10, #BLK_FLAGS]
    tbnz x12, #0, 2f
    cbz x0, 4f
    sub x0, x0, #1
2:
    add x10, x10, #64
    add x11, x11, #1
    b 1b
3:
    mov x0, #-1
    ret
4:
    mov x0, x11
    ret

blk_services:
    cmp x0, #6
    b.hi 97f
    cbnz x0, 1f
    ldv x9, blk_count           // 0: count the disks offered
    address x10, blk_disks
    mov x0, #0
0:
    cbz x9, 98f
    ldr x11, [x10, #BLK_FLAGS]
    tst x11, #BLKF_BOOT
    cinc x0, x0, eq
    add x10, x10, #64
    sub x9, x9, #1
    b 0b
98:
    mov x1, #0
    ret
97:
    mov x0, #1
    mov x1, #1
    ret
1:
    enter
    mov x19, x0
    mov x20, x2
    mov x21, x3
    mov x22, x4
    mov x0, x1
    bl blk_offered
    cmn x0, #1
    b.eq 85f
    mov x23, x0
    address x9, blk_disks
    add x24, x9, x23, lsl #6
    cmp x19, #1
    b.ne 2f
    ldr x9, [x24, #BLK_BSIZE]
    str x9, [x20]
    ldr x9, [x24, #BLK_BLOCKS]
    str x9, [x20, #8]
    ldr x9, [x24, #BLK_FLAGS]
    ubfx x9, x9, #1, #1
    str x9, [x20, #16]
    str xzr, [x20, #24]
    b 80f
2:
    cmp x19, #5                 // flush: rw writes are already complete
    b.eq 80f
    cmp x19, #4
    b.eq 3f
    cmp x19, #6
    b.ne 4f
3:
    mov x0, x23
    mov x1, x20
    mov x2, x21
    cmp x19, #4
    cset x3, eq
    bl blk_attach
    leave
4:
    cmp x19, #3                 // 2 read, 3 write, via the bounce buffer
    cset x25, eq
    ldr x26, [x24, #BLK_BSIZE]
    adds x9, x20, x21
    b.cs 87f
    ldr x10, [x24, #BLK_BLOCKS]
    cmp x9, x10
    b.hi 87f
    mov x27, #BLK_BOUNCE_SIZE
    udiv x27, x27, x26
5:
    cbz x21, 80f
    cmp x21, x27
    csel x28, x21, x27, lo
    cbz x25, 6f
    mov x0, x22
    address x1, blk_bounce
    mul x2, x28, x26
    bl disk_copy
6:
    mov x0, x23
    mov x1, x20
    mov x2, x28
    address x3, blk_bounce
    mov x4, x25
    bl blk_rw
    cbnz x0, 81f
    cbnz x25, 7f
    address x0, blk_bounce
    mov x1, x22
    mul x2, x28, x26
    bl disk_copy
7:
    add x20, x20, x28
    sub x21, x21, x28
    mul x9, x28, x26
    add x22, x22, x9
    b 5b
80:
    mov x0, #0
    mov x1, #0
    leave
81:
    mov x0, #21
    b 89f
85:
    mov x0, #15
    b 89f
87:
    mov x0, #87
89:
    mov x1, #1
    leave

// ---------------------------------------------------------------------------
// Further virtio-blk PCI disks (the boot disk is platform.S's): one request
// queue each, the same request layout as vio_rw.

blk_virtio_scan:
    enter
    ldv x9, plat_ecam
    cbz x9, 9f
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
    ldv x9, vio_pci             // the boot disk is already running
    cmp x22, x9
    b.eq 5f
    mov x0, x22
    bl blk_vio_add
5:
    cbnz x21, 6f
    ldrb w2, [x22, #14]         // multi-function devices only
    tbz w2, #7, 7f
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
    leave

// x0 = PCI config address of a virtio-blk device: starts it and registers
// it as a disk.
blk_vio_add:
    enter
    mov x19, x0
    ldv x20, blk_vio_count
    cmp x20, #BLK_VIO_MAX
    b.hs 9f
    address x21, blk_vio
    add x21, x21, x20, lsl #6
    mov x0, x19
    mov x1, x21
    bl vblk_caps
    cbnz x0, 9f
    address x9, blk_vio_queues
    add x9, x9, x20, lsl #12
    str x9, [x21, #VB_QUEUE]
    mov x0, x21
    bl vblk_init
    cbnz x0, 9f
    add x9, x20, #1
    stv x9, blk_vio_count, x10
    ldr x9, [x21, #VB_DEVICE]
    ldr w1, [x9]                // capacity, in 512-byte sectors
    ldr w2, [x9, #4]
    orr x1, x1, x2, lsl #32
    address x0, vblk_rw
    mov x2, x21
    mov x3, #512
    mov x4, #0
    bl disk_register
9:
    leave

// x0 = PCI config address, x1 = device record: finds the common, notify and
// device configuration structures. Returns x0 = 0 when all three exist.
vblk_caps:
    enter
    mov x19, x0
    mov x23, x1
    str xzr, [x23, #VB_COMMON]
    str xzr, [x23, #VB_NBASE]
    str xzr, [x23, #VB_DEVICE]
    str x19, [x23, #VB_PCI]
    ldrh w2, [x19, #4]
    orr w2, w2, #6              // memory space + bus master
    strh w2, [x19, #4]
    ldrh w2, [x19, #6]
    tbz w2, #4, 8f              // no capability list
    ldrb w20, [x19, #0x34]
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
    str x0, [x23, #VB_COMMON]
    b 3f
2:
    cmp x22, #2
    b.ne 21f
    str x0, [x23, #VB_NBASE]
    ldr w2, [x21, #16]
    str x2, [x23, #VB_NMUL]
    b 3f
21:
    cmp x22, #4
    b.ne 3f
    str x0, [x23, #VB_DEVICE]
3:
    ldrb w20, [x21, #1]
    b 1b
4:
    ldr x2, [x23, #VB_COMMON]
    cbz x2, 8f
    ldr x2, [x23, #VB_NBASE]
    cbz x2, 8f
    ldr x2, [x23, #VB_DEVICE]
    cbz x2, 8f
    mov x0, #0
    leave
8:
    mov x0, #1
    leave

// x0 = device record (its VB_QUEUE page set): reset and start the device
// with one 8-entry queue. Returns x0 = 0.
vblk_init:
    enter
    mov x21, x0
    ldr x19, [x21, #VB_COMMON]
    ldr x20, [x21, #VB_QUEUE]
    dsb sy
    strb wzr, [x19, #20]        // device_status = reset
    mov x9, #0x1000000
1:
    ldrb w2, [x19, #20]
    cbz w2, 2f
    subs x9, x9, #1
    b.ne 1b
    b 8f
2:
    mov w2, #3                  // ACKNOWLEDGE | DRIVER
    strb w2, [x19, #20]
    mov w2, #1
    str w2, [x19, #0]           // device_feature_select = 1
    ldr w3, [x19, #4]
    tbz w3, #0, 8f              // VIRTIO_F_VERSION_1 required
    str wzr, [x19, #8]
    str wzr, [x19, #12]
    str w2, [x19, #8]
    str w2, [x19, #12]          // accept VERSION_1 only
    mov w2, #11                 // | FEATURES_OK
    strb w2, [x19, #20]
    ldrb w2, [x19, #20]
    tbz w2, #3, 8f
    strh wzr, [x19, #22]        // queue_select = 0
    ldrh w2, [x19, #24]
    cmp w2, #VQ_SIZE
    b.lo 8f
    mov w2, #VQ_SIZE
    strh w2, [x19, #24]
    mov x0, x20                 // descriptors @0, avail @256, used @512,
    mov x1, #2048               // header @1024, status @1040
    bl fat_zero_bytes
    str x20, [x19, #32]
    add x2, x20, #256
    str x2, [x19, #40]
    add x2, x20, #512
    str x2, [x19, #48]
    ldrh w2, [x19, #30]         // queue_notify_off
    ldr x3, [x21, #VB_NMUL]
    mul x2, x2, x3
    ldr x3, [x21, #VB_NBASE]
    add x2, x2, x3
    str x2, [x21, #VB_NOTIFY]
    mov w2, #1
    strh w2, [x19, #28]         // queue_enable
    str xzr, [x21, #VB_SEEN]
    mov w2, #15                 // | DRIVER_OK
    strb w2, [x19, #20]
    dsb sy
    mov x0, #0
    leave
8:
    mov w2, #0x80               // FAILED
    strb w2, [x19, #20]
    mov x0, #1
    leave

// The disk table's rw for these devices: x0 = sector, x1 = count, x2 =
// buffer, w3 = 1 to write, x4 = device record. Leaf.
vblk_rw:
    mov x10, x4
    ldr x9, [x10, #VB_QUEUE]
    str w3, [x9, #1024]         // type: 0 in, 1 out
    str wzr, [x9, #1028]
    str x0, [x9, #1032]
    mov w4, #0xff
    strb w4, [x9, #1040]
    add x4, x9, #1024           // descriptor 0: header
    str x4, [x9, #0]
    mov w4, #16
    str w4, [x9, #8]
    mov w4, #1
    strh w4, [x9, #12]
    strh w4, [x9, #14]
    str x2, [x9, #16]           // descriptor 1: data
    lsl x4, x1, #9
    str w4, [x9, #24]
    mov w4, #3                  // NEXT | WRITE (device writes for reads)
    cbz w3, 1f
    mov w4, #1
1:
    strh w4, [x9, #28]
    mov w4, #2
    strh w4, [x9, #30]
    add x4, x9, #1040           // descriptor 2: status
    str x4, [x9, #32]
    mov w4, #1
    str w4, [x9, #40]
    mov w4, #2
    strh w4, [x9, #44]
    strh wzr, [x9, #46]
    add x5, x9, #256            // publish head 0
    ldrh w6, [x5, #2]
    and w7, w6, #(VQ_SIZE - 1)
    add x8, x5, #4
    strh wzr, [x8, x7, lsl #1]
    dmb sy
    add w6, w6, #1
    strh w6, [x5, #2]
    dsb sy
    ldr x5, [x10, #VB_NOTIFY]
    strh wzr, [x5]
    ldr x6, [x10, #VB_SEEN]
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
    str x6, [x10, #VB_SEEN]
    ldrb w4, [x9, #1040]
    cbnz w4, 4f
    mov x0, #0
    ret
4:
    mov x0, #1
    ret

.section .rodata
.balign 8
blk_gpt_sig: .ascii "EFI PART"
blk_guid_esp:                   // C12A7328-F81F-11D2-BA4B-00A0C93EC93B
    .long 0xc12a7328
    .short 0xf81f, 0x11d2
    .byte 0xba,0x4b,0x00,0xa0,0xc9,0x3e,0xc9,0x3b
blk_guid_data:                  // EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
    .long 0xebd0a0a2
    .short 0xb9e5, 0x4433
    .byte 0x87,0xc0,0x68,0xb6,0xb7,0x26,0x99,0xc7
blk_msg_drive: .asciz "Drive ?: is disk "
blk_msg_part: .ascii ", partition "
.section .bss
.balign 4096
blk_bounce: .skip BLK_BOUNCE_SIZE
blk_vio_queues: .skip BLK_VIO_MAX * 4096
blk_table: .skip 4096
blk_sector: .skip 4096
blk_gpt_buf: .skip 4096
blk_disks: .skip BLK_DISKS * 64
blk_vio: .skip BLK_VIO_MAX * 64
blk_vio_boot: .skip 64
blk_mbr: .skip 64
blk_part_disk: .skip BLK_PARTS * 8
blk_part_start: .skip BLK_PARTS * 8
blk_part_len: .skip BLK_PARTS * 8
blk_part_drive: .skip BLK_PARTS * 8
blk_count: .skip 8
blk_vio_count: .skip 8
blk_cur_disk: .skip 8
blk_cur_blocks: .skip 8
blk_cur_bsize: .skip 8
blk_cur_flags: .skip 8
blk_msg: .skip 64
.section .text
