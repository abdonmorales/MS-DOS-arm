// SPDX-License-Identifier: MIT
// Native FAT12/FAT16/FAT32 driver over EFI_BLOCK_IO_PROTOCOL.
//
// The runtime's file services were written against EFI_FILE_PROTOCOL. This
// driver keeps that contract: each open file or directory is an object with
// the same function table, so the DOS-facing code is unchanged while all
// filesystem logic (FAT chains, directories, long names, allocation) now runs
// in this file. UEFI only moves raw sectors. Replacing fat_block_io with a
// native disk driver is what remains before the runtime can leave firmware.
//
// Adapted ideas: FAT chain and directory handling follow MS-DOS 4.0 src/DOS
// (FAT.ASM, DIR.ASM, DIR2.ASM, CREATE.ASM); long names follow the VFAT
// on-disk format. The calling conventions are AAPCS64 throughout.

.equ FAT_SLOTS, 32              // write-through sector cache entries (BUFFERS= picks how many are used)
.equ FAT_SLOTS_DEFAULT, 8
.equ FAT_SLOT_SHIFT, 12         // 4 KiB per entry (largest sector size)
.equ FAT_OBJECTS, 128
.equ OBJ_SIZE, 128
.equ OBJ_MAGIC, 88
.equ OBJ_POS, 96
.equ OBJ_PARENT, 104            // directory cluster holding the entry (0=root)
.equ OBJ_INDEX, 108             // short entry index in that directory
.equ OBJ_FIRST, 112             // first entry of the set (long-name start)
.equ OBJ_DIRPOS, 116            // directory read cursor
.equ OBJ_FLAGS, 120
.equ OBJ_VOL, 121               // volume slot that owns the object
.equ OF_WRITE, 1
.equ OF_DIR, 2
.equ OF_ROOT, 4
.equ OF_PERM, 8
.equ OF_GONE, 16             // entry deleted through another handle
.equ NO_INDEX, 0xffffffff
.equ FAT_EOC, 0x0fffffff
.equ FAT_VOLS, 16               // mounted volumes (A: plus block devices)
.equ VOL_LIVE, (21 * 8)         // fat_mounted .. fat_root_obj
.equ VOL_SIZE, 272              // live block plus the boot record copy

.macro ldv reg, sym
    adrp \reg, \sym
    ldr \reg, [\reg, :lo12:\sym]
.endm
.macro stv reg, sym, tmp
    adrp \tmp, \sym
    str \reg, [\tmp, :lo12:\sym]
.endm
.macro efierr reg, code
    mov \reg, #\code
    orr \reg, \reg, #0x8000000000000000
.endm
.macro enter
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
.endm
.macro leave
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x23, x24, [sp, #48]
    ldp x25, x26, [sp, #64]
    ldp x27, x28, [sp, #80]
    ldp x29, x30, [sp], #96
    ret
.endm
// Little-endian 16-bit field at an arbitrary (possibly odd) offset.
.macro le16 reg, base, off, tmp
    ldrb \reg, [\base, #\off]
    ldrb \tmp, [\base, #(\off + 1)]
    orr \reg, \reg, \tmp, lsl #8
.endm

.section .text

// ---------------------------------------------------------------------------
// Mount: find Block I/O under the boot partition and validate its BPB.
// Returns x0=0 when the native driver owns the volume.
.global fat_mount
fat_mount:
    enter
    address x19, boot_services
    ldr x19, [x19]
    // Sector cache buffers come from firmware pages (4 KiB aligned for DMA).
    mov x0, #0                  // AllocateAnyPages
    mov x1, #2                  // EfiLoaderData
    mov x2, #FAT_SLOTS
    address x3, fat_cache_buffers
    ldr x4, [x19, #40]          // AllocatePages
    blr x4
    cbnz x0, fat_mount_fail
    address x2, fat_cache_lba
    address x3, fat_cache_stamp
    mov x4, #0
    mov x5, #-1
1:
    str x5, [x2, x4, lsl #3]
    str xzr, [x3, x4, lsl #3]
    add x4, x4, #1
    cmp x4, #FAT_SLOTS
    b.lo 1b
    address x0, image_handle
    ldr x0, [x0]
    address x1, loaded_image_guid
    address x2, protocol_result
    ldr x3, [x19, #152]         // HandleProtocol
    blr x3
    cbnz x0, fat_mount_fail
    address x0, protocol_result
    ldr x0, [x0]
    ldr x20, [x0, #24]          // LoadedImage.DeviceHandle (boot partition)
    stv x20, fat_device, x2
    mov x0, x20
    address x1, block_io_guid
    address x2, protocol_result
    ldr x3, [x19, #152]
    blr x3
    cbnz x0, fat_mount_fail
    address x0, protocol_result
    ldr x21, [x0]
    ldr x22, [x21, #8]          // EFI_BLOCK_IO_MEDIA
    ldrb w2, [x22, #5]          // MediaPresent
    cbz w2, fat_mount_fail
    ldrb w2, [x22, #7]          // ReadOnly: leave such media to firmware
    cbz w2, 1f
    mov x2, #1                  // a CD or other read-only boot: live mode
    adrp x3, boot_read_only
    str x2, [x3, :lo12:boot_read_only]
    b fat_mount_fail
1:
    ldr w23, [x22]              // MediaId
    ldr w24, [x22, #12]         // BlockSize
    cmp x24, #512
    b.lo fat_mount_fail
    cmp x24, #4096
    b.hi fat_mount_fail
    sub x2, x24, #1
    tst x24, x2
    b.ne fat_mount_fail
    stv x21, fat_blockio, x2
    stv x23, fat_media_id, x2
    stv x24, fat_bps, x2
    bl fat_mount_parse
    cbnz x0, fat_mount_fail
    ldv x0, fat_root_obj
    address x1, root_directory
    str x0, [x1]
    mov x0, #0
    leave
fat_mount_fail:
    efierr x0, 3
    leave

// Reads the boot record of the live volume (fat_bps already set) and
// fills in its geometry; creates its root object (fat_root_obj).
// Returns x0 = 0, or an EFI error when it holds no usable FAT.
fat_mount_parse:
    enter
    stv xzr, fat_mounted, x2
    stv xzr, fat_dew_dir, x2
    stv xzr, fat_next_free, x2
    ldv x24, fat_bps
    mov x0, #0
    bl fat_cache_read
    cbnz x0, fat_parse_fail
    mov x25, x1                 // boot sector
    address x0, fat_boot_copy   // lets the platform layer find this disk
    mov x2, #96
    bl fat_memcpy
    ldrb w2, [x25, #510]
    cmp w2, #0x55
    b.ne fat_parse_fail
    ldrb w2, [x25, #511]
    cmp w2, #0xaa
    b.ne fat_parse_fail
    le16 w2, x25, 11, w3        // bytes per sector
    cmp x2, x24
    b.ne fat_parse_fail
    ldrb w26, [x25, #13]        // sectors per cluster
    cbz w26, fat_parse_fail
    sub w2, w26, #1
    tst w26, w2
    b.ne fat_parse_fail
    le16 w27, x25, 14, w3       // reserved sectors
    cbz w27, fat_parse_fail
    ldrb w28, [x25, #16]        // FAT copies
    cbz w28, fat_parse_fail
    stv x26, fat_spc, x2
    stv x27, fat_fat_start, x2
    stv x28, fat_num_fats, x2
    mul x2, x26, x24
    stv x2, fat_cluster_bytes, x3
    le16 w19, x25, 17, w3       // root entries
    stv x19, fat_root_entries, x2
    le16 w20, x25, 19, w3       // total sectors (16-bit)
    cbnz w20, 2f
    ldr w20, [x25, #32]
2:
    ldv x2, fat_total_sectors   // a block device's size, when known: a
    cbz x2, 21f                 // boot record claiming more is not ours
    cmp x20, x2                 // (an old file system on a new partition)
    b.hi fat_parse_fail
21:
    le16 w21, x25, 22, w3       // sectors per FAT (16-bit)
    mov x23, x21                // remember whether the BPB is FAT32-shaped
    cbnz w21, 3f
    ldr w21, [x25, #36]
3:
    cbz w21, fat_parse_fail
    stv x21, fat_fat_sectors, x2
    // root_start = reserved + copies * fat_sectors
    madd x2, x28, x21, x27
    stv x2, fat_root_start, x3
    lsl x3, x19, #5
    add x3, x3, x24
    sub x3, x3, #1
    udiv x3, x3, x24            // root directory sectors
    add x22, x2, x3
    stv x22, fat_data_start, x2
    cmp x20, x22
    b.ls fat_parse_fail
    sub x2, x20, x22
    udiv x2, x2, x26
    stv x2, fat_clusters, x3
    mov x3, #4085
    mov x4, #12
    cmp x2, x3
    b.lo 4f
    mov x3, #65525
    mov x4, #16
    cmp x2, x3
    b.lo 4f
    mov x4, #32
4:
    // Never trust the cluster count beyond what the FAT can describe: with a
    // short FAT, entries for the extra clusters would land past the FAT.
    mul x5, x21, x24
    lsl x5, x5, #3
    udiv x5, x5, x4             // entries one FAT copy holds
    subs x5, x5, #2             // minus the two reserved entries
    b.le fat_parse_fail
    cmp x4, #32
    b.ne 41f
    mov x6, #0xfff4             // FAT32: highest data cluster is 0x0FFFFFF5
    movk x6, #0x0fff, lsl #16
    cmp x5, x6
    csel x5, x5, x6, ls
41:
    cmp x2, x5
    csel x2, x2, x5, ls
    stv x2, fat_clusters, x3
    stv x4, fat_type, x3
    cmp x4, #32
    b.eq 5f
    cbz x19, fat_parse_fail     // FAT12/16 need a fixed root directory
    b 6f
5:
    cbnz x19, fat_parse_fail
    cbnz x23, fat_parse_fail
    ldr w2, [x25, #44]          // root cluster
    and w2, w2, #0x0fffffff
    cmp x2, #2
    b.lo fat_parse_fail
    ldv x3, fat_clusters
    add x3, x3, #2
    cmp x2, x3
    b.hs fat_parse_fail
    stv x2, fat_root_cluster, x3
    le16 w19, x25, 48, w3       // FSInfo sector
    mov x2, #2
    stv x2, fat_next_free, x3
    cbz x19, 6f
    cmp x19, x27
    b.hs 6f
    mov x0, x19
    bl fat_cache_read
    cbnz x0, 6f
    ldr w2, [x1]
    mov w3, #0x5252
    movk w3, #0x4161, lsl #16
    cmp w2, w3
    b.ne 6f
    ldr w2, [x1, #484]
    mov w3, #0x7272
    movk w3, #0x6141, lsl #16
    cmp w2, w3
    b.ne 6f
    ldr w2, [x1, #492]          // next-free hint
    stv x2, fat_next_free, x3
    // The free count is maintained by checkers, not by this driver: mark it
    // unknown so no stale value survives our allocations.
    ldr w2, [x1, #488]
    cmn w2, #1
    b.eq 6f
    mov w2, #-1
    str w2, [x1, #488]
    mov x0, x1
    bl fat_cache_commit
6:
    bl fat_obj_alloc
    cbz x0, fat_parse_fail
    mov w2, #(OF_DIR | OF_ROOT | OF_WRITE | OF_PERM)
    strb w2, [x0, #OBJ_FLAGS]
    mov x2, #NO_INDEX
    str w2, [x0, #OBJ_INDEX]
    str w2, [x0, #OBJ_FIRST]
    stv x0, fat_root_obj, x1
    mov x2, #1
    stv x2, fat_mounted, x3
    mov x0, #0
    leave
fat_parse_fail:
    efierr x0, 3
    leave

// Before returning to firmware: flush, then reinstall Block I/O so the
// firmware's own FAT driver reconnects and drops its stale cached state.
.global fat_unmount
fat_unmount:
    enter
    mov x0, #0
    bl fat_vol_select
    ldv x2, fat_mounted
    cbz x2, 1f
    bl fat_flush_device
    ldv x2, platform_native     // no firmware left to hand the disk back to
    cbnz x2, 1f
    address x19, boot_services
    ldr x19, [x19]
    ldv x0, fat_device
    address x1, block_io_guid
    ldv x2, fat_blockio
    mov x3, x2
    ldr x4, [x19, #136]         // ReinstallProtocolInterface
    blr x4
    stv xzr, fat_mounted, x2
1:
    leave

.global fat_print_backend
fat_print_backend:
    frame
    ldv x2, fat_mounted
    address x0, fat_backend_firmware
    cbz x2, 1f
    ldv x2, fat_type
    address x0, fat_backend_fat12
    cmp x2, #12
    b.eq 1f
    address x0, fat_backend_fat16
    cmp x2, #16
    b.eq 1f
    address x0, fat_backend_fat32
1:
    bl puts
    ldv x2, fat_mounted
    cbz x2, 2f
    address x0, fat_backend_blockio
    ldv x2, platform_native
    cbz x2, 3f
    address x0, fat_backend_virtio
    adrp x2, plat_disk_kind
    ldr x2, [x2, :lo12:plat_disk_kind]
    cbz x2, 3f
    address x0, fat_backend_sd
3:
    bl puts
2:
    unframe

// ---------------------------------------------------------------------------
// Block I/O and the sector cache. Cached sectors are written through.

// x0=LBA, x1=buffer. Returns EFI status.
fat_read_blocks:
    mov x9, #24                 // ReadBlocks
    b fat_block_io
fat_write_blocks:
    mov x9, #32                 // WriteBlocks
fat_block_io:
    adrp x2, fat_backend
    ldr x2, [x2, :lo12:fat_backend]
    cbnz x2, fat_driver_io
    adrp x2, platform_native
    ldr x2, [x2, :lo12:platform_native]
    cbz x2, 1f
    mov x2, x1                  // native virtio-blk path, 512-byte sectors
    cmp x9, #32
    cset x3, eq
    mov x1, #1
    b plat_disk_rw
1:
    frame
    mov x4, x1
    mov x2, x0
    ldv x0, fat_blockio
    ldv x1, fat_media_id
    ldv x3, fat_bps
    ldr x5, [x0, x9]
    blr x5
    unframe

// A block device driver: rw(x0 = sector, x1 = buffer, x2 = count,
// x3 = 1 to write) returns x0 = 0, or nonzero on a device error.
fat_driver_io:
    frame
    cmp x9, #32
    cset x3, eq
    mov x2, #1
    ldv x4, fat_drv_rw
    blr x4
    cbz x0, 1f
    efierr x0, 7                // EFI_DEVICE_ERROR
1:
    unframe

// x0 = volume slot: makes it the live volume. The live geometry is saved
// to its slot and the next one loaded; the write-through sector cache is
// simply dropped. Leaf: uses x9-x15 only.
.global fat_vol_select
fat_vol_select:
    adrp x9, fat_cur_vol
    ldr x10, [x9, :lo12:fat_cur_vol]
    cmp x10, x0
    b.ne 1f
    ret
1:
    str x0, [x9, :lo12:fat_cur_vol]
    adrp x11, fat_dew_dir       // the directory walk cache is per volume
    str xzr, [x11, :lo12:fat_dew_dir]
    address x11, fat_vols
    mov x12, #VOL_SIZE
    madd x13, x10, x12, x11     // old slot
    madd x14, x0, x12, x11      // new slot
    address x11, fat_mounted
    mov x12, #0
2:
    ldr x15, [x11, x12]
    str x15, [x13, x12]
    ldr x15, [x14, x12]
    str x15, [x11, x12]
    add x12, x12, #8
    cmp x12, #VOL_LIVE
    b.lo 2b
    address x11, fat_boot_copy
    add x13, x13, #VOL_LIVE
    add x14, x14, #VOL_LIVE
    mov x12, #0
3:
    ldr x15, [x11, x12]
    str x15, [x13, x12]
    ldr x15, [x14, x12]
    str x15, [x11, x12]
    add x12, x12, #8
    cmp x12, #96
    b.lo 3b
    address x11, fat_cache_lba
    mov x12, #0
    mov x15, #-1
4:
    str x15, [x11, x12, lsl #3]
    add x12, x12, #1
    cmp x12, #FAT_SLOTS
    b.lo 4b
    ret

// Mounts a block device driver as a new volume. x0 = rw entry (as for
// fat_driver_io), x1 = sector size, x2 = total sectors. Returns x0 = the
// volume slot (or -1 when none is free) and x1 = 0 when it holds a FAT
// (its root object in x2), 1 when it must be formatted first.
.global fat_add_volume
fat_add_volume:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    // Cache slots are 4 KiB: sectors must be 512..4096 bytes, a power of 2.
    cmp x20, #512
    b.lo 8f
    cmp x20, #4096
    b.hi 8f
    sub x9, x20, #1
    tst x9, x20
    b.ne 8f
    ldv x22, fat_vol_count
    cmp x22, #FAT_VOLS
    b.hs 8f
    add x2, x22, #1
    stv x2, fat_vol_count, x3
    mov x0, x22
    bl fat_vol_select
    address x0, fat_mounted     // a clean slot
    mov x2, #0
1:
    str xzr, [x0, x2]
    add x2, x2, #8
    cmp x2, #VOL_LIVE
    b.lo 1b
    mov x2, #1
    stv x2, fat_backend, x3
    stv x19, fat_drv_rw, x3
    stv x20, fat_bps, x3
    stv x21, fat_total_sectors, x3
    bl fat_remount
    mov x1, x0
    mov x0, x22
    ldv x2, fat_root_obj
    leave
8:
    mov x0, #-1
    mov x1, #1
    leave

// Re-reads the live volume's boot record (after FORMAT or a disk change).
// Returns x0 = 0 when it holds a FAT, 1 otherwise. The root object is kept.
.global fat_remount
fat_remount:
    enter
    ldv x19, fat_root_obj
    bl fat_mount_parse
    cbz x0, 1f
    stv xzr, fat_mounted, x2
    mov x0, #1
    leave
1:
    cbz x19, 2f                 // keep the first root object, free the new
    ldv x0, fat_root_obj
    str xzr, [x0, #OBJ_MAGIC]
    stv x19, fat_root_obj, x2
2:
    mov x0, #0
    leave

fat_flush_device:
    adrp x0, fat_backend
    ldr x0, [x0, :lo12:fat_backend]
    cbnz x0, 2f
    adrp x0, platform_native
    ldr x0, [x0, :lo12:platform_native]
    cbz x0, 1f
    mov x0, #0                  // virtio writes complete before vio_rw returns
    ret
2:
    mov x0, #0
    ret
1:
    frame
    ldv x0, fat_blockio
    ldr x1, [x0, #40]           // FlushBlocks
    blr x1
    unframe

// x0=LBA. Returns x0=status, x1=sector buffer.
fat_cache_read:
    enter
    mov x19, x0
    mov x20, #0
    b fat_cache_get
// Same, but a miss is not read from disk: the caller overwrites the sector.
fat_cache_claim:
    enter
    mov x19, x0
    mov x20, #1
fat_cache_get:
    address x21, fat_cache_lba
    address x22, fat_cache_stamp
    adrp x2, fat_cache_clock
    ldr x23, [x2, :lo12:fat_cache_clock]
    add x23, x23, #1
    str x23, [x2, :lo12:fat_cache_clock]
    ldv x6, fat_slot_count
    mov x24, #0
1:
    ldr x2, [x21, x24, lsl #3]
    cmp x2, x19
    b.eq 5f
    add x24, x24, #1
    cmp x24, x6
    b.lo 1b
    mov x24, #0                 // miss: evict the least recently used
    ldr x3, [x22]
    mov x4, #1
2:
    ldr x2, [x22, x4, lsl #3]
    cmp x2, x3
    b.hs 3f
    mov x3, x2
    mov x24, x4
3:
    add x4, x4, #1
    cmp x4, x6
    b.lo 2b
    mov x2, #-1
    str x2, [x21, x24, lsl #3]
    ldv x25, fat_cache_buffers
    add x25, x25, x24, lsl #FAT_SLOT_SHIFT
    cbnz x20, 4f
    mov x0, x19
    mov x1, x25
    bl fat_read_blocks
    cbnz x0, 6f
4:
    str x19, [x21, x24, lsl #3]
    b 7f
5:
    ldv x25, fat_cache_buffers
    add x25, x25, x24, lsl #FAT_SLOT_SHIFT
7:
    str x23, [x22, x24, lsl #3]
    mov x0, #0
    mov x1, x25
6:
    leave

// x0=any pointer inside a cached sector. Writes that sector to disk.
fat_cache_commit:
    frame
    ldv x2, fat_cache_buffers
    sub x3, x0, x2
    lsr x3, x3, #FAT_SLOT_SHIFT
    add x1, x2, x3, lsl #FAT_SLOT_SHIFT
    address x4, fat_cache_lba
    ldr x0, [x4, x3, lsl #3]
    bl fat_write_blocks
    unframe

// ---------------------------------------------------------------------------
// File allocation table.

// x0=cluster. Returns first sector of that cluster.
fat_cluster_lba:
    ldv x1, fat_spc
    ldv x2, fat_data_start
    sub x0, x0, #2
    madd x0, x0, x1, x2
    ret

// x0=byte offset in the first FAT. Returns x0=status, x1=pointer.
fat_locate:
    frame
    ldv x2, fat_bps
    udiv x3, x0, x2
    msub x4, x3, x2, x0
    ldv x5, fat_fat_start
    add x0, x5, x3
    str x4, [sp, #-16]!
    bl fat_cache_read
    ldr x4, [sp], #16
    add x1, x1, x4
    unframe

// x0=cluster. Returns x0=status, x1=next (end-of-chain becomes FAT_EOC).
fat_get:
    enter
    mov x19, x0
    bl fat_check_cluster        // corrupt chains must not index past the FAT
    cbnz x0, 9f
    ldv x20, fat_type
    cmp x20, #12
    b.eq 3f
    lsl x0, x19, #1
    cmp x20, #16
    b.eq 1f
    lsl x0, x19, #2
1:
    bl fat_locate
    cbnz x0, 9f
    cmp x20, #16
    b.ne 2f
    ldrh w1, [x1]
    mov x2, #0xfff8
    b 5f
2:
    ldr w1, [x1]
    and w1, w1, #0x0fffffff
    mov x2, #0xfff8
    movk x2, #0x0fff, lsl #16
    b 5f
3:
    add x21, x19, x19, lsr #1
    mov x0, x21
    bl fat_locate
    cbnz x0, 9f
    ldrb w22, [x1]
    add x0, x21, #1
    bl fat_locate
    cbnz x0, 9f
    ldrb w1, [x1]
    orr w1, w22, w1, lsl #8
    tbz x19, #0, 4f
    lsr w1, w1, #4
4:
    and w1, w1, #0xfff
    mov x2, #0xff8
5:
    cmp x1, x2
    b.lo 6f
    mov x1, #FAT_EOC
6:
    mov x0, #0
9:
    leave

// x0=pointer inside a cached FAT sector: write it and every mirror copy.
fat_commit_fat:
    enter
    ldv x19, fat_cache_buffers
    sub x2, x0, x19
    lsr x20, x2, #FAT_SLOT_SHIFT
    add x19, x19, x20, lsl #FAT_SLOT_SHIFT
    address x2, fat_cache_lba
    ldr x21, [x2, x20, lsl #3]
    mov x0, x21
    mov x1, x19
    bl fat_write_blocks
    cbnz x0, 9f
    ldv x22, fat_num_fats
    ldv x23, fat_fat_sectors
1:
    subs x22, x22, #1
    b.ls 8f
    add x21, x21, x23
    mov x0, x21
    mov x1, x19
    bl fat_write_blocks
    cbnz x0, 9f
    b 1b
8:
    mov x0, #0
9:
    leave

// x0=cluster, x1=value (FAT_EOC for end of chain). Returns status.
fat_set:
    enter
    mov x19, x0
    mov x20, x1
    stv xzr, fat_dew_dir, x2    // chains may change: drop the walk cache
    bl fat_check_cluster        // never write outside this volume's FAT
    cbnz x0, 9f
    ldv x21, fat_type
    cmp x21, #12
    b.eq 4f
    lsl x0, x19, #1
    cmp x21, #16
    b.eq 1f
    lsl x0, x19, #2
1:
    bl fat_locate
    cbnz x0, 9f
    cmp x21, #16
    b.ne 2f
    strh w20, [x1]
    b 3f
2:
    ldr w2, [x1]
    and w2, w2, #0xf0000000     // FAT32 keeps the reserved top nibble
    and w3, w20, #0x0fffffff
    orr w2, w2, w3
    str w2, [x1]
3:
    mov x0, x1
    bl fat_commit_fat
    b 9f
4:
    add x22, x19, x19, lsr #1
    mov x0, x22
    bl fat_locate
    cbnz x0, 9f
    ldrb w2, [x1]
    tbz x19, #0, 5f
    and w2, w2, #0x0f
    and w3, w20, #0x0f
    orr w2, w2, w3, lsl #4
    b 6f
5:
    and w2, w20, #0xff
6:
    strb w2, [x1]
    mov x0, x1
    bl fat_commit_fat
    cbnz x0, 9f
    add x0, x22, #1
    bl fat_locate
    cbnz x0, 9f
    ldrb w2, [x1]
    tbz x19, #0, 7f
    lsr w2, w20, #4
    and w2, w2, #0xff
    b 8f
7:
    and w2, w2, #0xf0
    lsr w3, w20, #8
    and w3, w3, #0x0f
    orr w2, w2, w3
8:
    strb w2, [x1]
    mov x0, x1
    bl fat_commit_fat
9:
    leave

// x0=value from fat_get. Returns x0=0 when it names a valid data cluster.
fat_check_cluster:
    cmp x0, #2
    b.lo 1f
    ldv x1, fat_clusters
    add x1, x1, #2
    cmp x0, x1
    b.hs 1f
    mov x0, #0
    ret
1:
    efierr x0, 10               // EFI_VOLUME_CORRUPTED
    ret

// Returns x0=status, x1=new cluster already marked end-of-chain.
fat_alloc:
    enter
    ldv x19, fat_clusters
    add x20, x19, #2
    ldv x21, fat_next_free
    cmp x21, #2
    b.lo 1f
    cmp x21, x20
    b.lo 2f
1:
    mov x21, #2
2:
    mov x22, x19
3:
    cbz x22, 5f
    mov x0, x21
    bl fat_get
    cbnz x0, 9f
    cbz x1, 6f
    add x21, x21, #1
    cmp x21, x20
    b.lo 4f
    mov x21, #2
4:
    sub x22, x22, #1
    b 3b
5:
    efierr x0, 11               // EFI_VOLUME_FULL
    b 9f
6:
    mov x0, x21
    mov x1, #FAT_EOC
    bl fat_set
    cbnz x0, 9f
    add x2, x21, #1
    stv x2, fat_next_free, x3
    mov x0, #0
    mov x1, x21
9:
    leave

// x0=first cluster of a chain to release.
fat_free_chain:
    enter
    mov x19, x0
    ldv x20, fat_clusters
    add x21, x20, #2
1:
    cmp x19, #2
    b.lo 8f
    cmp x19, x21
    b.hs 8f
    mov x0, x19
    bl fat_get
    cbnz x0, 9f
    mov x22, x1
    mov x0, x19
    mov x1, #0
    bl fat_set
    cbnz x0, 9f
    mov x19, x22
    subs x20, x20, #1
    b.ne 1b
8:
    mov x0, #0
9:
    leave

// x0=cluster: fill it with zero bytes.
fat_zero_cluster:
    enter
    bl fat_cluster_lba
    mov x19, x0
    ldv x20, fat_spc
1:
    mov x0, x19
    bl fat_cache_claim
    cbnz x0, 9f
    mov x21, x1
    mov x0, x1
    ldv x1, fat_bps
    bl fat_zero_bytes
    mov x0, x21
    bl fat_cache_commit
    cbnz x0, 9f
    add x19, x19, #1
    subs x20, x20, #1
    b.ne 1b
    mov x0, #0
9:
    leave

// Returns x0=status, x1=free cluster count (scans the whole FAT).
fat_count_free:
    enter
    ldv x19, fat_clusters
    add x19, x19, #2
    mov x20, #2
    mov x21, #0
1:
    cmp x20, x19
    b.hs 2f
    mov x0, x20
    bl fat_get
    cbnz x0, 9f
    cbnz x1, 3f
    add x21, x21, #1
3:
    add x20, x20, #1
    b 1b
2:
    mov x0, #0
    mov x1, x21
9:
    leave

// ---------------------------------------------------------------------------
// Directories. A directory is named by its first cluster; 0 is the root.

// x0=directory, x1=entry index. Returns x0=status (EFI_NOT_FOUND past the
// directory's current size), x1=pointer to the 32-byte entry in the cache.
fat_dir_entry:
    enter
    mov x19, x0
    mov x20, x1
    cbnz x19, 2f
    ldv x2, fat_type
    cmp x2, #32
    b.eq 1f
    ldv x2, fat_root_entries
    cmp x20, x2
    b.hs 7f
    lsl x3, x20, #5
    ldv x4, fat_bps
    udiv x5, x3, x4
    msub x21, x5, x4, x3
    ldv x6, fat_root_start
    add x0, x6, x5
    b 6f
1:
    ldv x19, fat_root_cluster
2:
    mov x0, x19                 // directory cluster from disk: range-check it
    bl fat_check_cluster
    cbnz x0, 9f
    ldv x2, fat_cluster_bytes
    lsr x2, x2, #5
    udiv x22, x20, x2
    msub x23, x22, x2, x20
    // Resume from the last walk of this directory when it stopped at or
    // before the wanted cluster: a scan is then linear, not quadratic in the
    // chain length (a looping chain made each scan take minutes).
    mov x26, x19
    mov x27, x22
    ldv x3, fat_dew_dir
    cmp x3, x19
    b.ne 21f
    ldv x4, fat_dew_ord
    cmp x4, x22
    b.hi 21f
    ldv x19, fat_dew_clu
    sub x22, x22, x4
21:
    ldv x24, fat_clusters
3:
    cbz x22, 5f
    mov x0, x19
    bl fat_get
    cbnz x0, 9f
    mov x2, #FAT_EOC
    cmp x1, x2
    b.eq 7f
    mov x19, x1
    mov x0, x1
    bl fat_check_cluster
    cbnz x0, 9f
    sub x22, x22, #1
    subs x24, x24, #1
    b.ne 3b
    efierr x0, 10
    b 9f
5:
    stv x26, fat_dew_dir, x2
    stv x27, fat_dew_ord, x2
    stv x19, fat_dew_clu, x2
    mov x0, x19
    bl fat_cluster_lba
    mov x25, x0
    lsl x3, x23, #5
    ldv x4, fat_bps
    udiv x5, x3, x4
    msub x21, x5, x4, x3
    add x0, x25, x5
6:
    bl fat_cache_read
    cbnz x0, 9f
    add x1, x1, x21
    b 9f
7:
    efierr x0, 14
9:
    leave

// x0=directory: append one zeroed cluster.
fat_dir_extend:
    enter
    mov x19, x0
    cbnz x19, 1f
    ldv x2, fat_type
    cmp x2, #32
    b.ne 5f                     // fixed FAT12/16 root cannot grow
    ldv x19, fat_root_cluster
1:
    ldv x20, fat_clusters
2:
    mov x0, x19
    bl fat_get
    cbnz x0, 9f
    mov x2, #FAT_EOC
    cmp x1, x2
    b.eq 3f
    mov x19, x1
    mov x0, x1
    bl fat_check_cluster
    cbnz x0, 9f
    subs x20, x20, #1
    b.ne 2b
    efierr x0, 10
    b 9f
3:
    bl fat_alloc
    cbnz x0, 9f
    mov x21, x1
    mov x0, x21
    bl fat_zero_cluster
    cbnz x0, 9f
    mov x0, x19
    mov x1, x21
    bl fat_set
    b 9f
5:
    efierr x0, 11
9:
    leave

// x0=directory, x1=first index to examine. Returns x0=0 and fills
// fat_de_name/entry/index/first/next for the next live entry, or
// EFI_NOT_FOUND at the end. Valid ASCII long names replace short names.
fat_dir_read:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, #0                 // expected long-name ordinal (0=none)
    mov x22, #0                 // long-name checksum
    mov x23, #0                 // index of first long-name entry
    mov x24, #0                 // long name has unsupported characters
fat_dr_loop:
    mov x2, #0x10000
    cmp x20, x2
    b.hs fat_dr_end
    mov x0, x19
    mov x1, x20
    bl fat_dir_entry
    cbnz x0, fat_dr_return
    ldrb w2, [x1]
    cbz w2, fat_dr_end
    cmp w2, #0xe5
    b.eq fat_dr_reset
    ldrb w3, [x1, #11]
    and w4, w3, #0x3f
    cmp w4, #0x0f
    b.eq fat_dr_lfn
    tbnz w3, #3, fat_dr_reset   // volume label
    mov x25, x1
    address x0, fat_de_entry
    mov x1, x25
    mov x2, #32
    bl fat_memcpy
    address x0, fat_de_entry
    bl fat_short_checksum
    cmp x21, #1
    b.ne fat_dr_short
    cmp w0, w22
    b.ne fat_dr_short
    // A valid long-name set stays part of the entry (x23 = its first slot)
    // even when its name cannot be shown, so delete and rename remove it.
    cbnz x24, fat_dr_alias
    address x0, fat_lfn_buf
    ldrb w2, [x0]
    cbz w2, fat_dr_alias
    address x1, fat_de_name
    bl fat_strcpy
    b fat_dr_found
fat_dr_short:
    mov x23, x20
fat_dr_alias:
    address x0, fat_de_entry
    address x1, fat_de_name
    bl fat_format_short
fat_dr_found:
    stv x20, fat_de_index, x2
    stv x23, fat_de_first, x2
    add x3, x20, #1
    stv x3, fat_de_next, x2
    mov x0, #0
    b fat_dr_return
fat_dr_lfn:
    and w5, w2, #0x1f
    tbz w2, #6, 1f
    cbz w5, fat_dr_reset
    cmp w5, #20
    b.hi fat_dr_reset
    mov x23, x20
    ldrb w22, [x1, #13]
    mov x24, #0
    address x6, fat_lfn_buf
    mov x7, #13
    mul x7, x5, x7
    strb wzr, [x6, x7]
    b 2f
1:
    cbz x21, fat_dr_reset
    sub x6, x21, #1
    cmp x5, x6
    b.ne fat_dr_reset
    ldrb w6, [x1, #13]
    cmp w6, w22
    b.ne fat_dr_reset
2:
    mov x21, x5
    sub x6, x5, #1
    mov x7, #13
    mul x6, x6, x7
    address x7, fat_lfn_buf
    add x7, x7, x6
    address x8, fat_lfn_offsets
    mov x9, #0
3:
    ldrb w10, [x8, x9]
    ldrb w11, [x1, x10]
    add x10, x10, #1
    ldrb w12, [x1, x10]
    orr w11, w11, w12, lsl #8
    mov w12, #0xffff
    cmp w11, w12
    b.eq 4f
    cbz w11, 4f
    cmp w11, #0x20
    b.lo 5f
    cmp w11, #0x7e
    b.hi 5f
    strb w11, [x7, x9]
    b 6f
4:
    strb wzr, [x7, x9]
    b 6f
5:
    mov x24, #1
    mov w11, #'_'
    strb w11, [x7, x9]
6:
    add x9, x9, #1
    cmp x9, #13
    b.lo 3b
    add x20, x20, #1
    b fat_dr_loop
fat_dr_reset:
    mov x21, #0
    add x20, x20, #1
    b fat_dr_loop
fat_dr_end:
    efierr x0, 14
fat_dr_return:
    leave

// x0=11-byte short name. Returns w0=VFAT checksum.
fat_short_checksum:
    mov w2, #0
    mov x3, #0
1:
    ldrb w4, [x0, x3]
    lsr w5, w2, #1
    and w6, w2, #1
    orr w5, w5, w6, lsl #7
    add w2, w5, w4
    and w2, w2, #0xff
    add x3, x3, #1
    cmp x3, #11
    b.lo 1b
    mov w0, w2
    ret

// x0=directory entry, x1=destination. Writes "NAME.EXT" honoring the
// Windows NT lower-case flags in byte 12.
fat_format_short:
    mov x2, #0
    mov x3, #0
    ldrb w9, [x0, #12]
    mov x4, #8
1:
    cbz x4, 2f
    sub x5, x4, #1
    ldrb w6, [x0, x5]
    cmp w6, #' '
    b.ne 2f
    mov x4, x5
    b 1b
2:
    cmp x2, x4
    b.hs 4f
    ldrb w6, [x0, x2]
    cbnz x2, 3f
    cmp w6, #0x05
    b.ne 3f
    mov w6, #0xe5
3:
    tbz w9, #3, 31f
    sub w7, w6, #'A'
    cmp w7, #25
    b.hi 31f
    add w6, w6, #32
31:
    strb w6, [x1, x3]
    add x3, x3, #1
    add x2, x2, #1
    b 2b
4:
    mov x4, #11
5:
    cmp x4, #8
    b.ls 7f
    sub x5, x4, #1
    ldrb w6, [x0, x5]
    cmp w6, #' '
    b.ne 6f
    mov x4, x5
    b 5b
6:
    mov w6, #'.'
    strb w6, [x1, x3]
    add x3, x3, #1
    mov x2, #8
61:
    cmp x2, x4
    b.hs 7f
    ldrb w6, [x0, x2]
    tbz w9, #4, 62f
    sub w7, w6, #'A'
    cmp w7, #25
    b.hi 62f
    add w6, w6, #32
62:
    strb w6, [x1, x3]
    add x3, x3, #1
    add x2, x2, #1
    b 61b
7:
    strb wzr, [x1, x3]
    ret

// x0=directory, x1=ASCII name. Case-insensitive match against the long
// name and the short alias. Returns x0=0 with fat_de_* filled.
fat_dir_lookup:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, #0
1:
    mov x0, x19
    mov x1, x21
    bl fat_dir_read
    cbnz x0, 9f
    address x0, fat_de_name
    mov x1, x20
    bl fat_strcasecmp
    cbz x0, 8f
    address x0, fat_de_entry
    address x1, fat_short_tmp
    bl fat_format_short
    address x0, fat_short_tmp
    mov x1, x20
    bl fat_strcasecmp
    cbz x0, 8f
    ldv x21, fat_de_next
    b 1b
8:
    mov x0, #0
9:
    leave

// x0=directory, x1=11-byte short name. Returns x0=1 if taken, 0 if free,
// or an EFI error status.
fat_short_exists:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, #0
1:
    mov x0, x19
    mov x1, x21
    bl fat_dir_read
    cbz x0, 2f
    efierr x2, 14
    cmp x0, x2
    b.ne 9f
    mov x0, #0
    b 9f
2:
    address x2, fat_de_entry
    mov x3, #0
3:
    ldrb w4, [x2, x3]
    ldrb w5, [x20, x3]
    cmp w4, w5
    b.ne 4f
    add x3, x3, #1
    cmp x3, #11
    b.lo 3b
    mov x0, #1
    b 9f
4:
    ldv x21, fat_de_next
    b 1b
9:
    leave

// x0=name, x1=11-byte output. Returns x0=0 when the name is an exact 8.3
// name (x1=NT case flags), or x0=1 when a long name is required (output is
// the upper-case basis, x2=basis length before the numeric tail).
fat_make_short:
    mov x3, #0
    mov w4, #' '
1:
    strb w4, [x1, x3]
    add x3, x3, #1
    cmp x3, #11
    b.lo 1b
    mov x5, #-1
    mov x3, #0
2:
    ldrb w4, [x0, x3]
    cbz w4, 3f
    cmp w4, #'.'
    b.ne 21f
    mov x5, x3
21:
    add x3, x3, #1
    b 2b
3:
    mov x6, x3
    cbnz x5, 31f
    mov x5, #-1                 // ".name": the dot does not start an extension
31:
    mov x7, #0                  // bit 0: not representable exactly
    mov x8, #0                  // base length
    mov x9, #0                  // extension length
    mov x10, #0                 // 1/2 base lower/upper, 4/8 ext lower/upper
    mov x11, #0                 // 0=base, 1=extension
    mov x3, #0
4:
    cmp x3, x6
    b.hs 9f
    ldrb w4, [x0, x3]
    cmp x3, x5
    b.ne 41f
    mov x11, #1
    b 8f
41:
    cmp w4, #'.'
    b.eq 42f
    cmp w4, #' '
    b.ne 43f
42:
    orr x7, x7, #1
    b 8f
43:
    sub w12, w4, #'a'
    cmp w12, #25
    b.hi 44f
    sub w4, w4, #32
    mov x12, #1
    b 47f
44:
    sub w12, w4, #'A'
    cmp w12, #25
    b.hi 45f
    mov x12, #2
    b 47f
45:
    mov x12, #0
    sub w13, w4, #'0'
    cmp w13, #9
    b.ls 47f
    address x14, fat_short_specials
451:
    ldrb w15, [x14], #1
    cbz w15, 46f
    cmp w15, w4
    b.eq 47f
    b 451b
46:
    mov w4, #'_'
    orr x7, x7, #1
47:
    cbnz x11, 48f
    orr x10, x10, x12
    cmp x8, #8
    b.hs 471f
    strb w4, [x1, x8]
    add x8, x8, #1
    b 8f
471:
    orr x7, x7, #1
    b 8f
48:
    lsl x12, x12, #2
    orr x10, x10, x12
    cmp x9, #3
    b.hs 471b
    add x13, x9, #8
    strb w4, [x1, x13]
    add x9, x9, #1
8:
    add x3, x3, #1
    b 4b
9:
    add x13, x5, #1
    cmp x13, x6
    b.ne 91f
    orr x7, x7, #1              // trailing dot
91:
    cbnz x8, 92f
    orr x7, x7, #1
    mov w4, #'_'
    strb w4, [x1]
    mov x8, #1
92:
    and x13, x10, #3
    cmp x13, #3
    b.ne 93f
    orr x7, x7, #1              // mixed-case base needs a long name
93:
    and x13, x10, #12
    cmp x13, #12
    b.ne 94f
    orr x7, x7, #1
94:
    mov x14, #0
    tbz x10, #0, 95f
    orr x14, x14, #0x08
95:
    tbz x10, #2, 96f
    orr x14, x14, #0x10
96:
    mov x2, x8
    and x0, x7, #1
    mov x1, x14
    ret

// x0=directory, x1=11-byte basis (rewritten in place), x2=basis length.
// Appends the first free "~N" tail. Returns status.
fat_unique_short:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    address x0, fat_basis_tmp
    mov x1, x20
    mov x2, #11
    bl fat_memcpy
    mov x22, #1
1:
    address x23, fat_digits
    mov x3, x22
    mov x4, #0
2:
    mov x5, #10
    udiv x6, x3, x5
    msub x7, x6, x5, x3
    add w7, w7, #'0'
    strb w7, [x23, x4]
    add x4, x4, #1
    mov x3, x6
    cbnz x3, 2b
    mov x5, #7
    sub x5, x5, x4              // prefix length that leaves room for ~N
    cmp x21, x5
    csel x5, x21, x5, lo
    address x6, fat_basis_tmp
    mov x3, #0
    mov w7, #' '
3:
    strb w7, [x20, x3]
    add x3, x3, #1
    cmp x3, #8
    b.lo 3b
    mov x3, #0
4:
    cmp x3, x5
    b.hs 5f
    ldrb w7, [x6, x3]
    strb w7, [x20, x3]
    add x3, x3, #1
    b 4b
5:
    mov w7, #'~'
    strb w7, [x20, x3]
    add x3, x3, #1
6:
    sub x4, x4, #1
    ldrb w7, [x23, x4]
    strb w7, [x20, x3]
    add x3, x3, #1
    cbnz x4, 6b
    ldrb w7, [x6, #8]
    strb w7, [x20, #8]
    ldrb w7, [x6, #9]
    strb w7, [x20, #9]
    ldrb w7, [x6, #10]
    strb w7, [x20, #10]
    mov x0, x19
    mov x1, x20
    bl fat_short_exists
    cbz x0, 9f
    cmp x0, #1
    b.ne 9f
    add x22, x22, #1
    mov x2, #0x4240
    movk x2, #0xf, lsl #16      // 1,000,000
    cmp x22, x2
    b.lo 1b
    efierr x0, 11
9:
    leave

// x0=directory, x1=number of consecutive free entries needed. Grows the
// directory when needed. Returns x0=status, x1=first index of the run.
fat_dir_alloc:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, #0
    mov x22, #0
    mov x23, #0
1:
    mov x2, #0x10000
    cmp x21, x2
    b.hs 7f
    mov x0, x19
    mov x1, x21
    bl fat_dir_entry
    cbz x0, 2f
    efierr x2, 14
    cmp x0, x2
    b.ne 9f
    mov x0, x19
    bl fat_dir_extend
    cbnz x0, 9f
    b 1b
2:
    ldrb w2, [x1]
    cbz w2, 3f
    cmp w2, #0xe5
    b.eq 3f
    mov x22, #0
    add x21, x21, #1
    b 1b
3:
    cbnz x22, 4f
    mov x23, x21
4:
    add x22, x22, #1
    add x21, x21, #1
    cmp x22, x20
    b.lo 1b
    mov x0, #0
    mov x1, x23
    b 9f
7:
    efierr x0, 11
9:
    leave

// x0=directory, x1=first index, x2=long name, x3=long-name entry count.
// Writes the long-name entries and then fat_new_entry. Returns x0=status,
// x1=index of the short entry.
fat_dir_write_set:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x26, #0
    cbz x22, 1f
    mov x0, x21
    bl fat_strlen
    mov x26, x0
1:
    address x0, fat_new_entry
    bl fat_short_checksum
    mov x23, x0
    mov x24, x22
2:
    cbz x24, 6f
    mov x0, x19
    mov x1, x20
    bl fat_dir_entry
    cbnz x0, 9f
    mov x25, x1
    mov w2, w24
    cmp x24, x22
    b.ne 3f
    orr w2, w2, #0x40
3:
    strb w2, [x25]
    mov w2, #0x0f
    strb w2, [x25, #11]
    strb wzr, [x25, #12]
    strb w23, [x25, #13]
    strh wzr, [x25, #26]
    sub x6, x24, #1
    mov x7, #13
    mul x6, x6, x7
    address x8, fat_lfn_offsets
    mov x9, #0
4:
    add x10, x6, x9
    cmp x10, x26
    b.lo 41f
    b.eq 42f
    mov w11, #0xffff
    b 43f
41:
    ldrb w11, [x21, x10]
    b 43f
42:
    mov w11, #0
43:
    ldrb w12, [x8, x9]
    strb w11, [x25, x12]
    add x12, x12, #1
    lsr w13, w11, #8
    strb w13, [x25, x12]
    add x9, x9, #1
    cmp x9, #13
    b.lo 4b
    mov x0, x25
    bl fat_cache_commit
    cbnz x0, 9f
    add x20, x20, #1
    sub x24, x24, #1
    b 2b
6:
    mov x0, x19
    mov x1, x20
    bl fat_dir_entry
    cbnz x0, 9f
    mov x25, x1
    mov x0, x1
    address x1, fat_new_entry
    mov x2, #32
    bl fat_memcpy
    mov x0, x25
    bl fat_cache_commit
    cbnz x0, 9f
    mov x0, #0
    mov x1, x20
9:
    leave

// x0=directory, x1=first index, x2=last index: mark the entries deleted.
fat_dir_delete_set:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
1:
    cmp x20, x21
    b.hi 8f
    mov x0, x19
    mov x1, x20
    bl fat_dir_entry
    cbnz x0, 9f
    mov w2, #0xe5
    strb w2, [x1]
    mov x0, x1
    bl fat_cache_commit
    cbnz x0, 9f
    add x20, x20, #1
    b 1b
8:
    mov x0, #0
9:
    leave

// x0=11-byte name, x1=attributes, x2=NT case flags, x3=first cluster.
// Builds fat_new_entry stamped with the current DOS date and time.
fat_build_entry:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    address x23, fat_new_entry
    mov x0, x23
    mov x1, #32
    bl fat_zero_bytes
    mov x0, x23
    mov x1, x19
    mov x2, #11
    bl fat_memcpy
    strb w20, [x23, #11]
    strb w21, [x23, #12]
    lsr x2, x22, #16
    strh w2, [x23, #20]
    strh w22, [x23, #26]
    bl fat_now
    strh w1, [x23, #14]
    strh w0, [x23, #16]
    strh w0, [x23, #18]
    strh w1, [x23, #22]
    strh w0, [x23, #24]
    leave

// Returns w0=DOS date, w1=DOS time from the runtime clock.
fat_now:
    enter
    bl dos_get_date             // x0=year, x2=month, x3=day
    subs x0, x0, #1980
    b.hs 1f
    mov x0, #0
    mov x2, #1
    mov x3, #1
1:
    lsl x19, x0, #9
    orr x19, x19, x2, lsl #5
    orr x19, x19, x3
    bl dos_get_time             // x0=hour, x2=minute, x3=second
    lsl x20, x0, #11
    orr x20, x20, x2, lsl #5
    lsr x3, x3, #1
    orr x20, x20, x3
    mov x0, x19
    mov x1, x20
    leave

// x0=ASCII name. Returns x0=0 when it can name a FAT directory entry.
fat_valid_long:
    mov x2, #0
    mov x3, #0
1:
    ldrb w4, [x0, x2]
    cbz w4, 4f
    cmp w4, #0x20
    b.lo 5f
    cmp w4, #0x7f
    b.hs 5f
    address x5, fat_long_invalid
2:
    ldrb w6, [x5], #1
    cbz w6, 3f
    cmp w6, w4
    b.eq 5f
    b 2b
3:
    cmp w4, #'.'
    b.eq 31f
    cmp w4, #' '
    b.eq 31f
    mov x3, #1
31:
    add x2, x2, #1
    cmp x2, #255
    b.hi 5f
    b 1b
4:
    cbz x3, 5f
    mov x0, #0
    ret
5:
    efierr x0, 2
    ret

// x0=entry pointer. Returns x0=first cluster.
fat_entry_get_cluster:
    ldrh w1, [x0, #26]
    ldv x2, fat_type
    cmp x2, #32
    b.ne 1f
    ldrh w2, [x0, #20]
    orr w1, w1, w2, lsl #16
    and w1, w1, #0x0fffffff     // FAT32 cluster numbers are 28 bits
1:
    mov x0, x1
    ret

// x0=entry pointer, x1=cluster.
fat_entry_set_cluster:
    strh w1, [x0, #26]
    lsr w1, w1, #16
    strh w1, [x0, #20]
    ret

// x0=absolute path ("" or "\A\B"). Returns x0=status, x1=directory cluster.
fat_resolve_dir:
    enter
    mov x19, x0
    mov x20, #0
1:
    ldrb w2, [x19]
    cmp w2, #'\\'
    b.ne 2f
    add x19, x19, #1
    b 1b
2:
    cbz w2, 8f
    address x3, fat_rename_comp
    mov x4, #0
3:
    ldrb w2, [x19]
    cbz w2, 4f
    cmp w2, #'\\'
    b.eq 4f
    strb w2, [x3, x4]
    add x4, x4, #1
    add x19, x19, #1
    cmp x4, #255
    b.hi 7f
    b 3b
4:
    strb wzr, [x3, x4]
    ldrb w2, [x3]
    cmp w2, #'.'
    b.ne 5f
    ldrb w2, [x3, #1]
    cbz w2, 1b
    cmp w2, #'.'
    b.ne 5f
    ldrb w2, [x3, #2]
    cbnz w2, 5f
    cbz x20, 1b
5:
    mov x0, x20
    address x1, fat_rename_comp
    bl fat_dir_lookup
    cbnz x0, 9f
    address x0, fat_de_entry
    ldrb w2, [x0, #11]
    tbz w2, #4, 6f
    bl fat_entry_get_cluster
    mov x20, x0
    b 1b
6:
    efierr x0, 14
    b 9f
7:
    efierr x0, 2
    b 9f
8:
    mov x0, #0
    mov x1, x20
9:
    leave

// ---------------------------------------------------------------------------
// File objects.

// Returns x0=fresh object with its EFI_FILE_PROTOCOL table, or 0.
fat_obj_alloc:
    address x1, fat_objects
    mov x2, #0
1:
    ldr x3, [x1, #OBJ_MAGIC]
    cbz x3, 2f
    add x1, x1, #OBJ_SIZE
    add x2, x2, #1
    cmp x2, #FAT_OBJECTS
    b.lo 1b
    mov x0, #0
    ret
2:
    mov x0, x1
    mov x3, #0
3:
    str xzr, [x0, x3]
    add x3, x3, #8
    cmp x3, #OBJ_SIZE
    b.lo 3b
    mov x3, #0x10000            // EFI_FILE_PROTOCOL_REVISION
    str x3, [x0]
    address x3, fat_vt_open
    str x3, [x0, #8]
    address x3, fat_vt_close
    str x3, [x0, #16]
    address x3, fat_vt_delete
    str x3, [x0, #24]
    address x3, fat_vt_read
    str x3, [x0, #32]
    address x3, fat_vt_write
    str x3, [x0, #40]
    address x3, fat_vt_getpos
    str x3, [x0, #48]
    address x3, fat_vt_setpos
    str x3, [x0, #56]
    address x3, fat_vt_getinfo
    str x3, [x0, #64]
    address x3, fat_vt_setinfo
    str x3, [x0, #72]
    address x3, fat_vt_flush
    str x3, [x0, #80]
    mov x3, #1
    str x3, [x0, #OBJ_MAGIC]
    ldv x3, fat_cur_vol
    strb w3, [x0, #OBJ_VOL]
    ret

// Each method first makes the object's volume the live one.
.macro fat_vthunk name
fat_vt_\name:
    adrp x9, fat_efi_\name
    add x9, x9, :lo12:fat_efi_\name
    b fat_vol_thunk
.endm
fat_vthunk open
fat_vthunk close
fat_vthunk delete
fat_vthunk read
fat_vthunk write
fat_vthunk getpos
fat_vthunk setpos
fat_vthunk getinfo
fat_vthunk setinfo
fat_vthunk flush
fat_vol_thunk:
    ldrb w10, [x0, #OBJ_VOL]
    adrp x11, fat_cur_vol
    ldr x11, [x11, :lo12:fat_cur_vol]
    cmp x10, x11
    b.ne 1f
    br x9
1:
    stp x29, x30, [sp, #-64]!
    stp x0, x1, [sp, #16]
    stp x2, x3, [sp, #32]
    stp x4, x9, [sp, #48]
    mov x0, x10
    bl fat_vol_select
    ldp x0, x1, [sp, #16]
    ldp x2, x3, [sp, #32]
    ldp x4, x9, [sp, #48]
    ldp x29, x30, [sp], #64
    br x9

// x0=object (not root). Returns x0=status, x1=its cached short entry.
fat_obj_entry:
    frame
    ldrb w2, [x0, #OBJ_FLAGS]
    tbnz w2, #4, 1f             // OF_GONE: the slot may now hold another file
    ldr w1, [x0, #OBJ_INDEX]
    ldr w0, [x0, #OBJ_PARENT]
    bl fat_dir_entry
    cbnz x0, 2f
    ldrb w2, [x1]
    cbz w2, 1f
    cmp w2, #0xe5
    b.ne 2f
1:
    efierr x0, 7                // entry vanished under this handle
2:
    unframe

// x0=object. Returns x0=status, x1=first cluster (0 for the root).
fat_obj_cluster:
    frame
    ldrb w2, [x0, #OBJ_FLAGS]
    tbz w2, #2, 1f
    mov x0, #0
    mov x1, #0
    unframe
1:
    bl fat_obj_entry
    cbnz x0, 2f
    mov x0, x1
    bl fat_entry_get_cluster
    mov x1, x0
    mov x0, #0
2:
    unframe

// x0=object (not root). Fills fat_de_* for its own entry.
fat_obj_load_name:
    enter
    mov x19, x0
    efierr x0, 7
    ldrb w2, [x19, #OBJ_FLAGS]
    tbnz w2, #4, 9f             // OF_GONE
    ldr w0, [x19, #OBJ_PARENT]
    ldr w1, [x19, #OBJ_FIRST]
    bl fat_dir_read
    cbnz x0, 9f
    ldv x2, fat_de_index
    ldr w3, [x19, #OBJ_INDEX]
    cmp x2, x3
    b.eq 9f
    efierr x0, 7
9:
    leave

// x0=object, x1=byte count. Allocates clusters so the chain covers it.
fat_obj_ensure:
    enter
    mov x19, x0
    ldv x21, fat_cluster_bytes
    add x22, x1, x21
    sub x22, x22, #1
    udiv x22, x22, x21
    cbz x22, 8f
    mov x0, x19
    bl fat_obj_entry
    cbnz x0, 9f
    mov x0, x1
    bl fat_entry_get_cluster
    mov x23, x0
    cbnz x23, 2f
    bl fat_alloc
    cbnz x0, 9f
    mov x23, x1
    mov x0, x19
    bl fat_obj_entry
    cbnz x0, 9f
    mov x24, x1
    mov x0, x1
    mov x1, x23
    bl fat_entry_set_cluster
    mov x0, x24
    bl fat_cache_commit
    cbnz x0, 9f
2:
    mov x24, #1
3:
    cmp x24, x22
    b.hs 8f
    mov x0, x23
    bl fat_get
    cbnz x0, 9f
    mov x2, #FAT_EOC
    cmp x1, x2
    b.ne 4f
    bl fat_alloc
    cbnz x0, 9f
    mov x25, x1
    mov x0, x23
    mov x1, x25
    bl fat_set
    cbnz x0, 9f
    mov x23, x25
    b 5f
4:
    mov x23, x1
    mov x0, x1
    bl fat_check_cluster
    cbnz x0, 9f
5:
    add x24, x24, #1
    b 3b
8:
    mov x0, #0
9:
    leave

// x0=object, x1=byte count. Frees clusters beyond what the size needs.
fat_obj_truncate_chain:
    enter
    mov x19, x0
    ldv x21, fat_cluster_bytes
    add x22, x1, x21
    sub x22, x22, #1
    udiv x22, x22, x21
    mov x0, x19
    bl fat_obj_entry
    cbnz x0, 9f
    mov x24, x1
    mov x0, x1
    bl fat_entry_get_cluster
    mov x23, x0
    cbz x23, 8f
    cbnz x22, 2f
    mov x0, x24
    mov x1, #0
    bl fat_entry_set_cluster
    mov x0, x24
    bl fat_cache_commit
    cbnz x0, 9f
    mov x0, x23
    bl fat_free_chain
    b 9f
2:
    mov x24, #1
3:
    cmp x24, x22
    b.hs 4f
    mov x0, x23
    bl fat_get
    cbnz x0, 9f
    mov x2, #FAT_EOC
    cmp x1, x2
    b.eq 8f
    mov x23, x1
    mov x0, x1
    bl fat_check_cluster
    cbnz x0, 9f
    add x24, x24, #1
    b 3b
4:
    mov x0, x23
    bl fat_get
    cbnz x0, 9f
    mov x25, x1
    mov x2, #FAT_EOC
    cmp x25, x2
    b.eq 8f
    mov x0, x23
    mov x1, #FAT_EOC
    bl fat_set
    cbnz x0, 9f
    mov x0, x25
    bl fat_free_chain
    b 9f
8:
    mov x0, #0
9:
    leave

// x0=first cluster, x1=byte offset, x2=buffer (0 writes zeros), x3=length,
// x4=0 read / 1 write. The chain must already cover the range.
fat_file_io:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    cbz x22, 8f
    ldv x24, fat_cluster_bytes
    udiv x25, x20, x24
    msub x26, x25, x24, x20     // offset within the cluster
1:
    cbz x25, 3f
    mov x0, x19
    bl fat_get
    cbnz x0, 9f
    mov x19, x1
    mov x0, x1
    bl fat_check_cluster
    cbnz x0, 9f
    sub x25, x25, #1
    b 1b
3:
    mov x0, x19
    bl fat_check_cluster
    cbnz x0, 9f
    mov x0, x19
    bl fat_cluster_lba
    mov x28, x0
    ldv x4, fat_bps
    udiv x5, x26, x4
    msub x6, x5, x4, x26
    sub x7, x4, x6
    cmp x22, x7
    csel x27, x22, x7, lo
    add x0, x28, x5
    mov x28, x6
    cbnz x23, 4f
    bl fat_cache_read
    cbnz x0, 9f
    add x1, x1, x28
    mov x0, x21
    mov x2, x27
    bl fat_memcpy
    b 5f
4:
    cbnz x28, 41f
    ldv x4, fat_bps
    cmp x27, x4
    b.ne 41f
    bl fat_cache_claim
    b 42f
41:
    bl fat_cache_read
42:
    cbnz x0, 9f
    add x0, x1, x28
    mov x25, x0
    cbz x21, 43f
    mov x1, x21
    mov x2, x27
    bl fat_memcpy
    b 44f
43:
    mov x1, x27
    bl fat_zero_bytes
44:
    mov x0, x25
    bl fat_cache_commit
    cbnz x0, 9f
5:
    cbz x21, 6f
    add x21, x21, x27
6:
    sub x22, x22, x27
    add x26, x26, x27
    cbz x22, 8f
    cmp x26, x24
    b.lo 3b
    mov x26, #0
    mov x0, x19
    bl fat_get
    cbnz x0, 9f
    mov x19, x1
    b 3b
8:
    mov x0, #0
9:
    leave

// x0=info buffer, x1=short entry (0 for the root), x2=ASCII name.
// Writes an EFI_FILE_INFO and returns its size.
fat_fill_info:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x0, x21
    bl fat_strlen
    add x22, x0, #1
    lsl x22, x22, #1
    add x22, x22, #80
    mov x0, x19
    mov x1, #80
    bl fat_zero_bytes
    str x22, [x19]
    mov x2, #0x10
    cbz x20, 1f
    ldr w2, [x20, #28]
    str x2, [x19, #8]
    ldv x3, fat_cluster_bytes
    add x4, x2, x3
    sub x4, x4, #1
    udiv x4, x4, x3
    mul x4, x4, x3
    str x4, [x19, #16]
    add x0, x19, #24
    ldrh w1, [x20, #16]
    ldrh w2, [x20, #14]
    bl fat_efi_time
    add x0, x19, #40
    ldrh w1, [x20, #18]
    mov w2, #0
    bl fat_efi_time
    add x0, x19, #56
    ldrh w1, [x20, #24]
    ldrh w2, [x20, #22]
    bl fat_efi_time
    ldrb w2, [x20, #11]
    mov x3, #0x37
    and x2, x2, x3
1:
    str x2, [x19, #72]
    add x3, x19, #80
    mov x4, #0
2:
    ldrb w5, [x21, x4]
    strh w5, [x3, x4, lsl #1]
    add x4, x4, #1
    cbnz w5, 2b
    mov x0, x22
    leave

// x0=EFI_TIME destination, w1=DOS date, w2=DOS time.
fat_efi_time:
    cbz w1, 1f
    ubfx w3, w1, #9, #7
    add w3, w3, #1980
    strh w3, [x0]
    ubfx w3, w1, #5, #4
    strb w3, [x0, #2]
    and w3, w1, #31
    strb w3, [x0, #3]
    ubfx w3, w2, #11, #5
    strb w3, [x0, #4]
    ubfx w3, w2, #5, #6
    strb w3, [x0, #5]
    and w3, w2, #31
    lsl w3, w3, #1
    strb w3, [x0, #6]
    mov w3, #0x7ff              // EFI_UNSPECIFIED_TIMEZONE
    strh w3, [x0, #12]
1:
    ret

// x0=guid, x1=guid. Returns x0=1 when equal.
fat_guid_eq:
    mov x2, #0
1:
    ldrb w3, [x0, x2]
    ldrb w4, [x1, x2]
    cmp w3, w4
    b.ne 2f
    add x2, x2, #1
    cmp x2, #16
    b.lo 1b
    mov x0, #1
    ret
2:
    mov x0, #0
    ret

// x0=UTF-16 string, x1=ASCII destination (260 bytes). Returns x0=status.
fat_utf16_to_ascii:
    mov x2, #0
1:
    ldrh w3, [x0, x2, lsl #1]
    cbz w3, 2f
    cmp w3, #0x20
    b.lo 3f
    cmp w3, #0x7f
    b.hs 3f
    strb w3, [x1, x2]
    add x2, x2, #1
    cmp x2, #259
    b.hs 3f
    b 1b
2:
    strb wzr, [x1, x2]
    mov x0, #0
    ret
3:
    efierr x0, 2
    ret

// ---------------------------------------------------------------------------
// EFI_FILE_PROTOCOL implementation.

// Open(This, NewHandle, FileName, OpenMode, Attributes)
fat_efi_open:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    cmp x22, #1
    b.eq 1f
    cmp x22, #3
    b.eq 1f
    mov x2, #3
    orr x2, x2, #0x8000000000000000
    cmp x22, x2
    b.ne fat_open_invalid
1:
    mov x0, x21
    address x1, fat_open_path
    bl fat_utf16_to_ascii
    cbnz x0, fat_open_return
    address x24, fat_open_path
    mov x25, #0
    mov x26, #0
    mov x27, #NO_INDEX
    mov x28, #NO_INDEX
    ldrb w2, [x24]
    cmp w2, #'\\'
    b.eq fat_open_walk
    ldrb w2, [x19, #OBJ_FLAGS]
    tbz w2, #1, fat_open_notfound
    tbnz w2, #2, fat_open_walk
    mov x0, x19
    bl fat_obj_cluster
    cbnz x0, fat_open_return
    mov x25, x1
    ldr w26, [x19, #OBJ_PARENT]
    ldr w27, [x19, #OBJ_INDEX]
    ldr w28, [x19, #OBJ_FIRST]
fat_open_walk:
    ldrb w2, [x24]
    cmp w2, #'\\'
    b.ne 1f
    add x24, x24, #1
    b fat_open_walk
1:
    cbz w2, fat_open_current
    address x3, fat_open_comp
    mov x4, #0
2:
    ldrb w2, [x24]
    cbz w2, 3f
    cmp w2, #'\\'
    b.eq 3f
    strb w2, [x3, x4]
    add x4, x4, #1
    add x24, x24, #1
    cmp x4, #255
    b.hi fat_open_invalid
    b 2b
3:
    strb wzr, [x3, x4]
4:
    ldrb w2, [x24]
    cmp w2, #'\\'
    b.ne 5f
    add x24, x24, #1
    b 4b
5:
    cmp w2, #0
    cset x21, eq                // final component?
    ldrb w2, [x3]
    cmp w2, #'.'
    b.ne fat_open_lookup
    ldrb w2, [x3, #1]
    cbz w2, fat_open_dot
    cmp w2, #'.'
    b.ne fat_open_lookup
    ldrb w2, [x3, #2]
    cbnz w2, fat_open_lookup
    cbz x25, fat_open_dot       // ".." at the root stays at the root
    b fat_open_lookup
fat_open_dot:
    cbnz x21, fat_open_current
    b fat_open_walk
fat_open_lookup:
    mov x0, x25
    address x1, fat_open_comp
    bl fat_dir_lookup
    cbz x0, fat_open_found
    efierr x2, 14
    cmp x0, x2
    b.ne fat_open_return
    cbz x21, fat_open_notfound
    b fat_open_create
fat_open_found:
    mov x26, x25
    ldv x27, fat_de_index
    ldv x28, fat_de_first
    address x0, fat_de_entry
    bl fat_entry_get_cluster
    mov x19, x0
    address x2, fat_de_entry
    ldrb w3, [x2, #11]
    cbnz x21, fat_open_final
    tbz w3, #4, fat_open_notfound
    mov x25, x19
    cbnz x25, fat_open_walk
    mov x27, #NO_INDEX
    b fat_open_walk
fat_open_final:
    tbnz w3, #4, 1f
    tbz x22, #1, fat_open_make
    tbnz w3, #0, fat_open_denied    // read-only file opened for writing
    b fat_open_make
1:
    cbnz x19, fat_open_make_dir
    b fat_open_root                 // ".." entry naming the root
fat_open_current:
    mov x2, #NO_INDEX
    cmp x27, x2
    b.eq fat_open_root
fat_open_make_dir:
    mov x19, #OF_DIR
    b 1f
fat_open_make:
    mov x19, #0
1:
    tbz x22, #1, 2f
    orr x19, x19, #OF_WRITE
2:
    bl fat_obj_alloc
    cbz x0, fat_open_resources
    str w26, [x0, #OBJ_PARENT]
    str w27, [x0, #OBJ_INDEX]
    str w28, [x0, #OBJ_FIRST]
    strb w19, [x0, #OBJ_FLAGS]
    str x0, [x20]
    mov x0, #0
    b fat_open_return
fat_open_root:
    bl fat_obj_alloc
    cbz x0, fat_open_resources
    mov x2, #NO_INDEX
    str w2, [x0, #OBJ_INDEX]
    str w2, [x0, #OBJ_FIRST]
    mov x19, #(OF_DIR | OF_ROOT)
    tbz x22, #1, 1f
    orr x19, x19, #OF_WRITE
1:
    strb w19, [x0, #OBJ_FLAGS]
    str x0, [x20]
    mov x0, #0
    b fat_open_return
fat_open_create:
    tbz x22, #63, fat_open_notfound
    address x0, fat_open_comp
    bl fat_valid_long
    cbnz x0, fat_open_return
    mov x2, #0x37
    and x23, x23, x2
    address x0, fat_open_comp
    address x1, fat_new_short
    bl fat_make_short
    mov x19, x0                 // long name needed
    mov x21, x1                 // NT case flags
    cbz x19, 1f
    mov x0, x25
    address x1, fat_new_short
    bl fat_unique_short
    cbnz x0, fat_open_return
    mov x21, #0
1:
    mov x24, #0                 // new directory cluster
    tbz x23, #4, 2f
    bl fat_alloc
    cbnz x0, fat_open_return
    mov x24, x1
    mov x0, x24
    bl fat_zero_cluster
    cbnz x0, fat_open_create_fail
    address x0, fat_dot_short
    mov x1, #0x10
    mov x2, #0
    mov x3, x24
    bl fat_build_entry
    mov x0, x24
    mov x1, #0
    bl fat_open_put_entry
    cbnz x0, fat_open_create_fail
    address x0, fat_dotdot_short
    mov x1, #0x10
    mov x2, #0
    mov x3, x25                 // parent; 0 also means root on FAT32
    bl fat_build_entry
    mov x0, x24
    mov x1, #1
    bl fat_open_put_entry
    cbnz x0, fat_open_create_fail
2:
    address x0, fat_new_short
    mov x1, x23
    mov x2, x21
    mov x3, x24
    bl fat_build_entry
    cbz x19, 3f
    address x0, fat_open_comp
    bl fat_strlen
    add x0, x0, #12
    mov x1, #13
    udiv x19, x0, x1
3:
    mov x0, x25
    add x1, x19, #1
    bl fat_dir_alloc
    cbnz x0, fat_open_create_fail
    mov x28, x1
    mov x0, x25
    mov x1, x28
    address x2, fat_open_comp
    mov x3, x19
    bl fat_dir_write_set
    cbnz x0, fat_open_create_fail
    mov x27, x1
    mov x26, x25
    tbnz x23, #4, fat_open_make_dir
    b fat_open_make
fat_open_create_fail:
    mov x19, x0
    cbz x24, 1f
    mov x0, x24
    bl fat_free_chain
1:
    mov x0, x19
    b fat_open_return
fat_open_resources:
    efierr x0, 9
    b fat_open_return
fat_open_denied:
    efierr x0, 15
    b fat_open_return
fat_open_notfound:
    efierr x0, 14
    b fat_open_return
fat_open_invalid:
    efierr x0, 2
fat_open_return:
    leave

// x0=directory, x1=index: copy fat_new_entry there and write it.
fat_open_put_entry:
    enter
    bl fat_dir_entry
    cbnz x0, 9f
    mov x19, x1
    mov x0, x1
    address x1, fat_new_entry
    mov x2, #32
    bl fat_memcpy
    mov x0, x19
    bl fat_cache_commit
9:
    leave

// Close(This)
fat_efi_close:
    ldrb w2, [x0, #OBJ_FLAGS]
    tbnz w2, #3, 1f
    str xzr, [x0, #OBJ_MAGIC]
1:
    mov x0, #0
    ret

// Delete(This): remove the entry (directories must be empty) and close.
fat_efi_delete:
    enter
    mov x19, x0
    ldrb w2, [x19, #OBJ_FLAGS]
    tbnz w2, #2, 8f
    mov x0, x19
    bl fat_obj_entry
    cbnz x0, 8f
    mov x0, x1
    bl fat_entry_get_cluster
    mov x20, x0
    ldrb w2, [x19, #OBJ_FLAGS]
    tbz w2, #1, 3f
    cbz x20, 8f
    mov x21, #0
1:
    mov x0, x20
    mov x1, x21
    bl fat_dir_read
    cbz x0, 2f
    efierr x2, 14
    cmp x0, x2
    b.eq 3f
    b 8f
2:
    address x0, fat_de_name
    address x1, fat_dot_name
    bl fat_strcmp
    cbz x0, 21f
    address x0, fat_de_name
    address x1, fat_dotdot_name
    bl fat_strcmp
    cbnz x0, 8f
21:
    ldv x21, fat_de_next
    b 1b
3:
    ldr w0, [x19, #OBJ_PARENT]
    ldr w1, [x19, #OBJ_FIRST]
    ldr w2, [x19, #OBJ_INDEX]
    bl fat_dir_delete_set
    cbnz x0, 8f
    mov x0, x19
    mov x1, #0
    mov x2, #0
    mov x3, #NO_INDEX
    bl fat_obj_retarget
    mov x0, x20
    bl fat_free_chain
    mov x0, x19
    bl fat_efi_close
    mov x0, #0
    leave
8:
    mov x0, x19
    bl fat_efi_close
    mov x0, #2                  // EFI_WARN_DELETE_FAILURE
    leave

// Read(This, BufferSize, Buffer)
fat_efi_read:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    ldrb w2, [x19, #OBJ_FLAGS]
    tbnz w2, #1, fat_read_dir
    mov x0, x19
    bl fat_obj_entry
    cbnz x0, 9f
    ldr w22, [x1, #28]
    mov x0, x1
    bl fat_entry_get_cluster
    mov x23, x0
    ldr x24, [x19, #OBJ_POS]
    ldr x25, [x20]
    cmp x24, x22
    b.hs 7f
    sub x2, x22, x24
    cmp x25, x2
    csel x25, x25, x2, lo
    mov x0, x23
    mov x1, x24
    mov x2, x21
    mov x3, x25
    mov x4, #0
    bl fat_file_io
    cbnz x0, 9f
    add x24, x24, x25
    str x24, [x19, #OBJ_POS]
    str x25, [x20]
    mov x0, #0
    b 9f
7:
    str xzr, [x20]
    mov x0, #0
    b 9f
fat_read_dir:
    mov x0, x19
    bl fat_obj_cluster
    cbnz x0, 9f
    mov x22, x1
    ldr w1, [x19, #OBJ_DIRPOS]
    mov x0, x22
    bl fat_dir_read
    cbz x0, 1f
    efierr x2, 14
    cmp x0, x2
    b.ne 9f
    str xzr, [x20]
    mov x0, #0
    b 9f
1:
    address x0, fat_de_name
    bl fat_strlen
    add x23, x0, #1
    lsl x23, x23, #1
    add x23, x23, #80
    ldr x2, [x20]
    cmp x2, x23
    b.hs 2f
    str x23, [x20]
    efierr x0, 5                // EFI_BUFFER_TOO_SMALL
    b 9f
2:
    mov x0, x21
    address x1, fat_de_entry
    address x2, fat_de_name
    bl fat_fill_info
    str x0, [x20]
    ldv x2, fat_de_next
    str w2, [x19, #OBJ_DIRPOS]
    mov x0, #0
9:
    leave

// Write(This, BufferSize, Buffer)
fat_efi_write:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    ldrb w2, [x19, #OBJ_FLAGS]
    tbnz w2, #1, fat_write_unsupported
    tbz w2, #0, fat_write_denied
    ldr x22, [x20]
    cbz x22, fat_write_done
    ldr x23, [x19, #OBJ_POS]
    adds x24, x23, x22
    b.cs fat_write_full
    mov x2, #0xffffffff
    cmp x24, x2
    b.hi fat_write_full
    mov x0, x19
    bl fat_obj_entry
    cbnz x0, fat_write_return
    ldr w25, [x1, #28]
    mov x0, x19
    mov x1, x24
    bl fat_obj_ensure
    cbnz x0, fat_write_rollback
    mov x0, x19
    bl fat_obj_entry
    cbnz x0, fat_write_rollback
    mov x0, x1
    bl fat_entry_get_cluster
    mov x26, x0
    cmp x23, x25
    b.ls 1f
    mov x0, x26                 // writing past EOF: zero the gap
    mov x1, x25
    mov x2, #0
    sub x3, x23, x25
    mov x4, #1
    bl fat_file_io
    cbnz x0, fat_write_rollback
1:
    mov x0, x26
    mov x1, x23
    mov x2, x21
    mov x3, x22
    mov x4, #1
    bl fat_file_io
    cbnz x0, fat_write_rollback
    mov x0, x19
    bl fat_obj_entry
    cbnz x0, fat_write_return
    mov x27, x1
    cmp x24, x25
    csel x2, x24, x25, hi
    str w2, [x27, #28]
    ldrb w2, [x27, #11]
    orr w2, w2, #0x20           // archive
    strb w2, [x27, #11]
    bl fat_now
    strh w1, [x27, #22]
    strh w0, [x27, #24]
    strh w0, [x27, #18]
    mov x0, x27
    bl fat_cache_commit
    cbnz x0, fat_write_return
    str x24, [x19, #OBJ_POS]
fat_write_done:
    mov x0, #0
    b fat_write_return
fat_write_rollback:
    mov x28, x0
    mov x0, x19
    mov x1, x25
    bl fat_obj_truncate_chain
    str xzr, [x20]
    mov x0, x28
    b fat_write_return
fat_write_full:
    efierr x0, 11
    b fat_write_return
fat_write_unsupported:
    efierr x0, 3
    b fat_write_return
fat_write_denied:
    efierr x0, 15
fat_write_return:
    leave

// GetPosition(This, Position)
fat_efi_getpos:
    ldrb w2, [x0, #OBJ_FLAGS]
    tbnz w2, #1, 1f
    ldr x2, [x0, #OBJ_POS]
    str x2, [x1]
    mov x0, #0
    ret
1:
    efierr x0, 3
    ret

// SetPosition(This, Position): all ones means end of file.
fat_efi_setpos:
    enter
    mov x19, x0
    mov x20, x1
    ldrb w2, [x19, #OBJ_FLAGS]
    tbz w2, #1, 1f
    cbnz x20, 8f
    str wzr, [x19, #OBJ_DIRPOS]
    mov x0, #0
    b 9f
1:
    cmn x20, #1
    b.ne 2f
    mov x0, x19
    bl fat_obj_entry
    cbnz x0, 9f
    ldr w20, [x1, #28]
2:
    str x20, [x19, #OBJ_POS]
    mov x0, #0
    b 9f
8:
    efierr x0, 3
9:
    leave

// GetInfo(This, InformationType, BufferSize, Buffer)
fat_efi_getinfo:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x0, x20
    address x1, file_info_guid
    bl fat_guid_eq
    cbnz x0, 1f
    mov x0, x20
    address x1, fat_fs_info_guid
    bl fat_guid_eq
    cbnz x0, 5f
    efierr x0, 3
    b 9f
1:
    ldrb w2, [x19, #OBJ_FLAGS]
    tbz w2, #2, 2f
    mov x23, #0                 // root: no entry, empty name
    address x24, fat_empty_name
    b 3f
2:
    mov x0, x19
    bl fat_obj_load_name
    cbnz x0, 9f
    address x23, fat_de_entry
    address x24, fat_de_name
3:
    mov x0, x24
    bl fat_strlen
    add x2, x0, #1
    lsl x2, x2, #1
    add x2, x2, #80
    ldr x3, [x21]
    cmp x3, x2
    b.hs 4f
    str x2, [x21]
    efierr x0, 5
    b 9f
4:
    mov x0, x22
    mov x1, x23
    mov x2, x24
    bl fat_fill_info
    str x0, [x21]
    mov x0, #0
    b 9f
5:
    ldr x3, [x21]
    mov x2, #38
    cmp x3, x2
    b.hs 6f
    str x2, [x21]
    efierr x0, 5
    b 9f
6:
    mov x0, x22
    mov x1, #38
    bl fat_zero_bytes
    mov x2, #38
    str x2, [x22]
    ldv x23, fat_cluster_bytes
    ldv x2, fat_clusters
    mul x2, x2, x23
    str x2, [x22, #16]
    bl fat_count_free
    cbnz x0, 9f
    mul x1, x1, x23
    str x1, [x22, #24]
    str w23, [x22, #32]
    mov x2, #38
    str x2, [x21]
    mov x0, #0
9:
    leave

// SetInfo(This, InformationType, BufferSize, Buffer): attributes,
// modification time, size and name (rename or move) of an EFI_FILE_INFO.
fat_efi_setinfo:
    enter
    mov x19, x0
    mov x20, x3
    mov x21, x2
    mov x0, x1
    address x1, file_info_guid
    bl fat_guid_eq
    cbz x0, fat_set_unsupported
    cmp x21, #82
    b.lo fat_set_invalid
    ldrb w2, [x19, #OBJ_FLAGS]
    tbnz w2, #2, fat_set_denied
    mov x0, x19
    bl fat_obj_entry
    cbnz x0, fat_set_return
    mov x22, x1
    ldr x2, [x20, #72]
    mov x3, #0x37
    bic x4, x2, x3
    cbnz x4, fat_set_invalid
    ldrb w5, [x22, #11]
    eor x6, x2, x5
    tbnz x6, #4, fat_set_denied
    mov w7, #0x27
    and w2, w2, w7
    bic w5, w5, w7
    orr w5, w5, w2
    strb w5, [x22, #11]
    add x0, x20, #56
    bl pack_efi_time
    cbz w0, 1f
    strh w1, [x22, #22]
    strh w0, [x22, #24]
1:
    mov x0, x22
    bl fat_cache_commit
    cbnz x0, fat_set_return
    ldrb w2, [x19, #OBJ_FLAGS]
    tbnz w2, #1, 4f             // directory sizes are not settable
    ldr x23, [x20, #8]
    mov x0, x19
    bl fat_obj_entry
    cbnz x0, fat_set_return
    ldr w24, [x1, #28]
    cmp x23, x24
    b.eq 4f
    mov x2, #0xffffffff
    cmp x23, x2
    b.hi fat_set_full
    cmp x23, x24
    b.hi 2f
    mov x0, x19
    mov x1, x23
    bl fat_obj_truncate_chain
    cbnz x0, fat_set_return
    b 3f
2:
    mov x0, x19
    mov x1, x23
    bl fat_obj_ensure
    cbnz x0, fat_set_rollback
    mov x0, x19
    bl fat_obj_entry
    cbnz x0, fat_set_return
    mov x0, x1
    bl fat_entry_get_cluster
    mov x1, x24
    mov x2, #0
    sub x3, x23, x24
    mov x4, #1
    bl fat_file_io
    cbnz x0, fat_set_rollback
3:
    mov x0, x19
    bl fat_obj_entry
    cbnz x0, fat_set_return
    str w23, [x1, #28]
    mov x0, x1
    bl fat_cache_commit
    cbnz x0, fat_set_return
4:
    add x0, x20, #80
    address x1, fat_open_path
    bl fat_utf16_to_ascii
    cbnz x0, fat_set_return
    mov x0, x19
    bl fat_obj_load_name
    cbnz x0, fat_set_return
    address x0, fat_de_name
    address x1, fat_open_path
    bl fat_strcmp
    cbz x0, fat_set_return
    mov x0, x19
    bl fat_rename
    b fat_set_return
fat_set_rollback:
    mov x25, x0
    mov x0, x19
    mov x1, x24
    bl fat_obj_truncate_chain
    mov x0, x25
    b fat_set_return
fat_set_full:
    efierr x0, 11
    b fat_set_return
fat_set_unsupported:
    efierr x0, 3
    b fat_set_return
fat_set_invalid:
    efierr x0, 2
    b fat_set_return
fat_set_denied:
    efierr x0, 15
fat_set_return:
    leave

// Other open objects naming the same directory slot as x0 must follow it:
// x1=new parent, x2=new first entry, x3=new index (NO_INDEX: the entry was
// deleted, so mark them OF_GONE). Without this a second handle on a deleted
// or moved file would read or write whatever file next reuses the slot.
fat_obj_retarget:
    ldr w4, [x0, #OBJ_PARENT]
    ldr w5, [x0, #OBJ_INDEX]
    address x6, fat_objects
    mov x7, #0
1:
    cmp x6, x0
    b.eq 3f
    ldr x8, [x6, #OBJ_MAGIC]
    cbz x8, 3f
    ldrb w8, [x6, #OBJ_VOL]
    ldrb w9, [x0, #OBJ_VOL]
    cmp w8, w9
    b.ne 3f
    ldrb w8, [x6, #OBJ_FLAGS]
    tbnz w8, #2, 3f             // the root object has no slot
    ldr w9, [x6, #OBJ_PARENT]
    cmp w9, w4
    b.ne 3f
    ldr w9, [x6, #OBJ_INDEX]
    cmp w9, w5
    b.ne 3f
    mov w9, #NO_INDEX
    cmp w3, w9
    b.ne 2f
    orr w8, w8, #OF_GONE
    strb w8, [x6, #OBJ_FLAGS]
    b 3f
2:
    str w1, [x6, #OBJ_PARENT]
    str w2, [x6, #OBJ_FIRST]
    str w3, [x6, #OBJ_INDEX]
3:
    add x6, x6, #OBJ_SIZE
    add x7, x7, #1
    cmp x7, #FAT_OBJECTS
    b.lo 1b
    ret

// x0=object; fat_open_path holds the new name (bare, or absolute path).
fat_rename:
    enter
    mov x19, x0
    address x20, fat_open_path
    ldrb w2, [x20]
    cmp w2, #'\\'
    b.eq 1f
    ldr w21, [x19, #OBJ_PARENT]
    mov x22, x20
    mov x2, #0
11:
    ldrb w3, [x22, x2]
    cbz w3, 3f
    cmp w3, #'\\'
    b.eq fat_ren_denied
    add x2, x2, #1
    b 11b
1:
    mov x2, #0
    mov x3, #0
12:
    ldrb w4, [x20, x2]
    cbz w4, 13f
    cmp w4, #'\\'
    b.ne 14f
    mov x3, x2
14:
    add x2, x2, #1
    b 12b
13:
    add x22, x20, x3
    add x22, x22, #1
    address x0, fat_rename_name
    mov x1, x22
    bl fat_strcpy_to
    address x22, fat_rename_name
    strb wzr, [x20, x3]
    mov x0, x20
    bl fat_resolve_dir
    cbnz x0, fat_ren_return
    mov x21, x1
3:
    mov x0, x22
    bl fat_valid_long
    cbnz x0, fat_ren_return
    // A directory may not move below itself.
    ldrb w2, [x19, #OBJ_FLAGS]
    tbz w2, #1, 4f
    mov x0, x19
    bl fat_obj_cluster
    cbnz x0, fat_ren_return
    mov x23, x1
    mov x24, x21
    mov x25, #256
31:
    cmp x24, x23
    b.eq fat_ren_denied
    cbz x24, 4f
    subs x25, x25, #1
    b.eq fat_ren_denied
    mov x0, x24
    address x1, fat_dotdot_name
    bl fat_dir_lookup
    cbnz x0, fat_ren_return
    address x0, fat_de_entry
    bl fat_entry_get_cluster
    mov x24, x0
    b 31b
4:
    mov x23, #0                 // 1 when only the spelling of this entry changes
    mov x0, x21
    mov x1, x22
    bl fat_dir_lookup
    cbz x0, 41f
    efierr x2, 14
    cmp x0, x2
    b.ne fat_ren_return
    b 5f
41:
    ldr w2, [x19, #OBJ_PARENT]
    cmp x2, x21
    b.ne fat_ren_denied
    ldv x3, fat_de_index
    ldr w4, [x19, #OBJ_INDEX]
    cmp x3, x4
    b.ne fat_ren_denied
    mov x23, #1
5:
    mov x0, x19
    bl fat_obj_entry
    cbnz x0, fat_ren_return
    address x0, fat_rename_entry
    mov x2, #32
    bl fat_memcpy
    cbz x23, 6f
    ldr w0, [x19, #OBJ_PARENT]
    ldr w1, [x19, #OBJ_FIRST]
    ldr w2, [x19, #OBJ_INDEX]
    bl fat_dir_delete_set
    cbnz x0, fat_ren_return
6:
    mov x0, x22
    address x1, fat_new_short
    bl fat_make_short
    mov x24, x0
    mov x25, x1
    cbz x24, 7f
    mov x0, x21
    address x1, fat_new_short
    bl fat_unique_short
    cbnz x0, fat_ren_restore
    mov x25, #0
7:
    address x0, fat_new_entry
    address x1, fat_rename_entry
    mov x2, #32
    bl fat_memcpy
    address x0, fat_new_entry
    address x1, fat_new_short
    mov x2, #11
    bl fat_memcpy
    address x2, fat_new_entry
    strb w25, [x2, #12]
    mov x26, #0
    cbz x24, 8f
    mov x0, x22
    bl fat_strlen
    add x0, x0, #12
    mov x1, #13
    udiv x26, x0, x1
8:
    mov x0, x21
    add x1, x26, #1
    bl fat_dir_alloc
    cbnz x0, fat_ren_restore
    mov x27, x1
    mov x0, x21
    mov x1, x27
    mov x2, x22
    mov x3, x26
    bl fat_dir_write_set
    cbnz x0, fat_ren_restore
    mov x28, x1
    cbnz x23, 9f
    ldr w0, [x19, #OBJ_PARENT]
    ldr w1, [x19, #OBJ_FIRST]
    ldr w2, [x19, #OBJ_INDEX]
    bl fat_dir_delete_set
    cbnz x0, fat_ren_return
9:
    // A moved directory's ".." must name its new parent.
    ldrb w2, [x19, #OBJ_FLAGS]
    tbz w2, #1, 10f
    ldr w2, [x19, #OBJ_PARENT]
    cmp x2, x21
    b.eq 10f
    address x0, fat_rename_entry
    bl fat_entry_get_cluster
    cbz x0, 10f
    mov x1, #1
    bl fat_dir_entry
    cbnz x0, fat_ren_return
    ldrb w2, [x1]
    cmp w2, #'.'
    b.ne 10f
    ldrb w2, [x1, #1]
    cmp w2, #'.'
    b.ne 10f
    mov x24, x1
    mov x0, x1
    mov x1, x21
    bl fat_entry_set_cluster
    mov x0, x24
    bl fat_cache_commit
    cbnz x0, fat_ren_return
10:
    mov x0, x19
    mov x1, x21
    mov x2, x27
    mov x3, x28
    bl fat_obj_retarget
    str w21, [x19, #OBJ_PARENT]
    str w27, [x19, #OBJ_FIRST]
    str w28, [x19, #OBJ_INDEX]
    mov x0, #0
    b fat_ren_return
fat_ren_restore:
    // Same-directory respelling deleted the old entries first: put the
    // short entry back so the file is never lost.
    mov x26, x0
    cbz x23, 1f
    ldr w0, [x19, #OBJ_PARENT]
    ldr w1, [x19, #OBJ_INDEX]
    bl fat_dir_entry
    cbnz x0, 1f
    mov x27, x1
    mov x0, x1
    address x1, fat_rename_entry
    mov x2, #32
    bl fat_memcpy
    mov x0, x27
    bl fat_cache_commit
    ldr w2, [x19, #OBJ_INDEX]
    str w2, [x19, #OBJ_FIRST]
1:
    mov x0, x26
    b fat_ren_return
fat_ren_denied:
    efierr x0, 15
fat_ren_return:
    leave

// Flush(This)
fat_efi_flush:
    b fat_flush_device

// ---------------------------------------------------------------------------
// Small leaf helpers.

// x0=destination, x1=source, x2=length.
fat_memcpy:
    cbz x2, 2f
    mov x3, #0
1:
    ldrb w4, [x1, x3]
    strb w4, [x0, x3]
    add x3, x3, #1
    cmp x3, x2
    b.lo 1b
2:
    ret

// x0=destination, x1=length.
fat_zero_bytes:
    cbz x1, 2f
    mov x2, #0
1:
    strb wzr, [x0, x2]
    add x2, x2, #1
    cmp x2, x1
    b.lo 1b
2:
    ret

fat_strlen:
    mov x1, x0
1:
    ldrb w2, [x1], #1
    cbnz w2, 1b
    sub x0, x1, x0
    sub x0, x0, #1
    ret

// x0=source, x1=destination.
fat_strcpy:
1:
    ldrb w2, [x0], #1
    strb w2, [x1], #1
    cbnz w2, 1b
    ret

// x0=destination, x1=source.
fat_strcpy_to:
1:
    ldrb w2, [x1], #1
    strb w2, [x0], #1
    cbnz w2, 1b
    ret

// Returns x0=0 when equal.
fat_strcmp:
1:
    ldrb w2, [x0], #1
    ldrb w3, [x1], #1
    cmp w2, w3
    b.ne 2f
    cbnz w2, 1b
    mov x0, #0
    ret
2:
    mov x0, #1
    ret

fat_strcasecmp:
1:
    ldrb w2, [x0], #1
    ldrb w3, [x1], #1
    sub w4, w2, #'a'
    cmp w4, #25
    b.hi 2f
    sub w2, w2, #32
2:
    sub w4, w3, #'a'
    cmp w4, #25
    b.hi 3f
    sub w3, w3, #32
3:
    cmp w2, w3
    b.ne 4f
    cbnz w2, 1b
    mov x0, #0
    ret
4:
    mov x0, #1
    ret

.section .data
.balign 8
fat_slot_count: .quad FAT_SLOTS_DEFAULT
fat_vol_count: .quad 1          // slot 0 is the boot volume
.section .rodata
.balign 8
block_io_guid:
    .long 0x964e5b21
    .short 0x6459, 0x11d2
    .byte 0x8e,0x39,0x00,0xa0,0xc9,0x69,0x72,0x3b
fat_fs_info_guid:
    .long 0x09576e93
    .short 0x6d3f, 0x11d2
    .byte 0x8e,0x39,0x00,0xa0,0xc9,0x69,0x72,0x3b
fat_lfn_offsets: .byte 1,3,5,7,9,14,16,18,20,22,24,28,30
fat_short_specials: .asciz "!#$%&'()-@^_`{}~"
fat_long_invalid: .asciz "\\/:*?\"<>|"
fat_dot_short: .ascii ".          "
fat_dotdot_short: .ascii "..         "
fat_dot_name: .asciz "."
fat_dotdot_name: .asciz ".."
fat_empty_name: .asciz ""
fat_backend_fat12: .asciz "Storage: native FAT12 driver"
fat_backend_fat16: .asciz "Storage: native FAT16 driver"
fat_backend_fat32: .asciz "Storage: native FAT32 driver"
fat_backend_blockio: .asciz " over UEFI Block I/O\r\n"
fat_backend_virtio: .asciz " over the native virtio-blk driver\r\n"
fat_backend_sd: .asciz " over the native SD card driver\r\n"
fat_backend_firmware: .asciz "Storage: UEFI firmware file system (native FAT driver unavailable)\r\n"

.section .bss
.balign 8
.global boot_read_only
boot_read_only: .skip 8
.balign 16
fat_mounted: .skip 8
fat_device: .skip 8
fat_blockio: .skip 8
fat_media_id: .skip 8
fat_bps: .skip 8
fat_spc: .skip 8
fat_cluster_bytes: .skip 8
fat_type: .skip 8
fat_fat_start: .skip 8
fat_fat_sectors: .skip 8
fat_num_fats: .skip 8
fat_root_start: .skip 8
fat_root_entries: .skip 8
fat_data_start: .skip 8
fat_clusters: .skip 8
fat_root_cluster: .skip 8
fat_next_free: .skip 8
fat_backend: .skip 8            // 0 boot disk (Block I/O or virtio), 1 driver
fat_drv_rw: .skip 8
fat_total_sectors: .skip 8
fat_root_obj: .skip 8
fat_cache_buffers: .skip 8
fat_cache_clock: .skip 8
fat_cache_lba: .skip 8 * FAT_SLOTS
fat_cache_stamp: .skip 8 * FAT_SLOTS
fat_de_index: .skip 8
fat_dew_dir: .skip 8            // last fat_dir_entry walk: directory cluster,
fat_dew_ord: .skip 8            // cluster ordinal reached in its chain
fat_dew_clu: .skip 8            // and that cluster (fat_dew_dir 0: none)
fat_de_first: .skip 8
fat_de_next: .skip 8
fat_de_entry: .skip 32
fat_new_entry: .skip 32
fat_rename_entry: .skip 32
fat_new_short: .skip 16
fat_basis_tmp: .skip 16
fat_digits: .skip 16
fat_short_tmp: .skip 16
fat_de_name: .skip 264
fat_lfn_buf: .skip 264
fat_open_path: .skip 264
fat_open_comp: .skip 264
fat_rename_comp: .skip 264
fat_rename_name: .skip 264
.balign 16
fat_boot_copy: .skip 96
.balign 16
fat_vols: .skip FAT_VOLS * VOL_SIZE
fat_cur_vol: .skip 8
.balign 16
fat_objects: .skip FAT_OBJECTS * OBJ_SIZE
