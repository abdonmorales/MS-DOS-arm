// SPDX-License-Identifier: MIT
// Drive information: allocation data (1Bh/1Ch), drive parameter blocks
// (1Fh/32h/53h), the list of lists (52h), media ID (69h, IOCTL 440Dh) and
// the IOCTL dispatcher (44h, IOCTL.ASM).
//
// Native DPB (64 bytes): the DOS 4.0 layout for the first 33 bytes, then
// 32-bit fields that FAT32 needs: 40 sectors per FAT, 44 first data sector,
// 48 highest cluster, 52 root cluster (FAT32), 56 FAT type, 60 total sectors.
.section .text

// Store a 16-bit little-endian value byte by byte (DPB fields are unaligned).
.macro st16 reg, base, off, tmp
    strb \reg, [\base, #\off]
    lsr \tmp, \reg, #8
    strb \tmp, [\base, #(\off + 1)]
.endm

// x0 = drive (0 default, 1 A:). Returns x1 = 0 when it names the FAT volume.
disk_check_drive:
    cmp x0, #1
    b.hi 1f
    adrp x9, fat_mounted
    ldr x9, [x9, :lo12:fat_mounted]
    cbz x9, 1f
    mov x1, #0
    ret
1:
    mov x0, #15
    mov x1, #1
    ret

// 1Bh / 1Ch (x0 = drive): x0 sectors per cluster, x2 bytes per sector,
// x3 clusters, x4 media byte, x5 = pointer to the media byte.
dos_alloc_info_default:
    mov x0, #0
dos_alloc_info:
    frame
    bl disk_check_drive
    cbnz x1, 1f
    address x5, fat_boot_copy
    add x5, x5, #21
    ldrb w4, [x5]
    ldv x0, fat_spc
    ldv x2, fat_bps
    ldv x3, fat_clusters
    mov x1, #0
1:
    unframe

// x0 = BPB (boot sector + 11), x1 = 64-byte DPB, x2 = drive number.
dpb_from_bpb:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x0, x20
    mov x1, #64
    str x2, [sp, #-16]!
    bl fat_zero_bytes
    ldr x2, [sp], #16
    strb w2, [x20]              // drive
    strb w2, [x20, #1]          // unit
    le16 w21, x19, 0, w3        // bytes per sector
    st16 w21, x20, 2, w3
    ldrb w22, [x19, #2]         // sectors per cluster
    sub w3, w22, #1
    strb w3, [x20, #4]
    rbit w3, w22
    clz w3, w3                  // log2(sectors per cluster)
    strb w3, [x20, #5]
    le16 w23, x19, 3, w3        // reserved sectors = first FAT sector
    st16 w23, x20, 6, w3
    ldrb w24, [x19, #5]         // number of FATs
    strb w24, [x20, #8]
    le16 w9, x19, 6, w3         // root entries
    st16 w9, x20, 9, w3
    le16 w10, x19, 11, w3       // sectors per FAT (16-bit)
    mov x15, #0                 // root cluster
    cbnz w10, 1f
    ldrb w10, [x19, #25]
    ldrb w3, [x19, #26]
    orr w10, w10, w3, lsl #8
    ldrb w3, [x19, #27]
    orr w10, w10, w3, lsl #16
    ldrb w3, [x19, #28]
    orr w10, w10, w3, lsl #24
    ldrb w15, [x19, #33]
    ldrb w3, [x19, #34]
    orr w15, w15, w3, lsl #8
    ldrb w3, [x19, #35]
    orr w15, w15, w3, lsl #16
    ldrb w3, [x19, #36]
    orr w15, w15, w3, lsl #24
1:
    le16 w11, x19, 8, w3        // total sectors (16-bit)
    cbnz w11, 2f
    ldrb w11, [x19, #21]
    ldrb w3, [x19, #22]
    orr w11, w11, w3, lsl #8
    ldrb w3, [x19, #23]
    orr w11, w11, w3, lsl #16
    ldrb w3, [x19, #24]
    orr w11, w11, w3, lsl #24
2:
    ldrb w3, [x19, #10]         // media byte
    strb w3, [x20, #23]
    madd x12, x24, x10, x23     // first root directory sector
    st16 w12, x20, 17, w3
    lsl x13, x9, #5
    add x13, x13, x21
    sub x13, x13, #1
    cbz x21, 3f
    udiv x13, x13, x21
3:
    add x13, x12, x13           // first data sector
    sub x14, x11, x13
    cbz x22, 4f
    udiv x14, x14, x22
4:
    add x14, x14, #1            // highest cluster number
    mov x3, #0xffff
    cmp x13, x3
    csel x4, x13, x3, lo
    st16 w4, x20, 11, w5
    cmp x14, x3
    csel x4, x14, x3, lo
    st16 w4, x20, 13, w5
    cmp x10, x3
    csel x4, x10, x3, lo
    st16 w4, x20, 15, w5
    mov w4, #0xff
    strb w4, [x20, #25]         // next DPB: FFFFFFFFh (end of chain)
    strb w4, [x20, #26]
    strb w4, [x20, #27]
    strb w4, [x20, #28]
    mov w4, #2
    st16 w4, x20, 29, w5        // next free cluster hint
    mov w4, #0xffff
    st16 w4, x20, 31, w5        // free clusters unknown
    str w10, [x20, #40]
    str w13, [x20, #44]
    str w14, [x20, #48]
    str w15, [x20, #52]
    sub x14, x14, #1            // cluster count -> FAT type (FAT.ASM rule)
    mov x4, #12
    mov x5, #4085
    cmp x14, x5
    b.lo 5f
    mov x4, #16
    mov x5, #65525
    cmp x14, x5
    b.lo 5f
    mov x4, #32
5:
    str w4, [x20, #56]
    str w11, [x20, #60]
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// 1Fh / 32h (x0 = drive): x0 = DPB of the drive.
dos_get_dpb_default:
    mov x0, #0
dos_get_dpb:
    frame
    bl disk_check_drive
    cbnz x1, 1f
    address x0, fat_boot_copy
    add x0, x0, #11
    address x1, dos_dpb
    mov x2, #0
    bl dpb_from_bpb
    address x0, dos_dpb
    mov x1, #0
1:
    unframe

// 53h: x0 = BPB (bytes per sector first), x1 = DPB destination.
dos_translate_bpb:
    frame
    cbz x0, 1f
    cbz x1, 1f
    mov x2, #0
    bl dpb_from_bpb
    mov x0, #0
    mov x1, #0
    unframe
1:
    mov x0, #1
    mov x1, #1
    unframe

// 52h: x0 = list of lists (ABI.md): DPB, handle table, CLOCK$ and CON
// devices, largest sector, block devices, LASTDRIVE, NUL device (head of the
// device chain), current directory, BUFFERS and FILES.
dos_list_of_lists:
    frame
    bl dos_get_dpb_default
    address x9, dos_sysvars
    cbnz x1, 1f
    str x0, [x9]
    b 2f
1:
    str xzr, [x9]
2:
    address x0, handles
    str x0, [x9, #8]
    address x0, dev_objects
    add x1, x0, #(DEV_CLOCK * DEV_OBJ_SIZE)
    str x1, [x9, #16]
    str x0, [x9, #24]           // CON
    ldv x1, fat_bps
    cbnz x1, 3f
    mov x1, #512
3:
    strh w1, [x9, #32]
    mov w1, #1
    strb w1, [x9, #34]
    address x1, config_lastdrive
    ldr x1, [x1]
    strb w1, [x9, #35]
    add x1, x0, #(DEV_NUL * DEV_OBJ_SIZE)
    str x1, [x9, #40]
    address x1, current_directory
    str x1, [x9, #48]
    address x1, config_buffers
    ldr x1, [x1]
    str x1, [x9, #56]
    address x1, config_files
    ldr x1, [x1]
    str x1, [x9, #64]
    // Memory (what MEM reports): arena table, its size, the native arena's
    // total and free bytes (0 in firmware mode), and the kernel's owner id.
    address x1, arena_table
    str x1, [x9, #72]
    mov x1, #64
    str x1, [x9, #80]
    mov x1, #0
    mov x2, #0
    ldv x3, platform_native
    cbz x3, 5f
    mov x1, #PLAT_ARENA_BYTES
    address x3, plat_granule_map
    mov x4, #0
4:
    ldrh w5, [x3, x4, lsl #1]
    cbnz w5, 41f
    add x2, x2, #(1 << PLAT_GRANULE_SHIFT)
41:
    add x4, x4, #1
    cmp x4, #PLAT_GRANULES
    b.lo 4b
5:
    str x1, [x9, #88]
    str x2, [x9, #96]
    address x1, image_handle
    ldr x1, [x1]
    str x1, [x9, #104]
    mov x0, x9
    mov x1, #0
    unframe

// 69h: x0 = 0 get / 1 set, x1 = drive, x2 = 25-byte media ID buffer:
// u16 info level (0), u32 serial, 11-byte label, 8-byte file system type.
dos_media_id:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x2
    cmp x19, #1
    b.hi media_invalid
    cbz x20, media_invalid
    mov x0, x1
    bl disk_check_drive
    cbnz x1, media_return
    mov x0, #0
    bl fat_cache_read
    cbnz x0, media_device_error
    mov x21, x1                 // boot sector in the cache
    mov x22, #38                // FAT12/16 extended boot record
    ldv x2, fat_type
    cmp x2, #32
    b.ne 1f
    mov x22, #66
1:
    ldrb w2, [x21, x22]
    cmp w2, #0x29
    b.ne media_denied
    add x9, x21, x22
    cbnz x19, media_set
    strb wzr, [x20]
    strb wzr, [x20, #1]
    add x0, x9, #1
    add x1, x20, #2
    mov x2, #23                 // serial, label, type are contiguous
    bl copy_bytes
    b media_success
media_set:
    add x0, x20, #2
    add x1, x9, #1
    mov x2, #23
    bl copy_bytes
    mov x0, x21
    bl fat_cache_commit
    cbnz x0, media_device_error
    mov x0, x21
    address x1, fat_boot_copy
    mov x2, #96
    bl copy_bytes
media_success:
    mov x0, #0
    mov x1, #0
    b media_return
media_device_error:
    bl efi_error_to_dos
    mov x1, #1
    b media_return
media_denied:
    mov x0, #5
    mov x1, #1
    b media_return
media_invalid:
    mov x0, #1
    mov x1, #1
media_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// ---------------------------------------------------------------------------
// 44h IOCTL: x0 = handle or drive, x1 = subfunction.
//  00 device information -> x0 (and x2)    01 set device information (x2)
//  02-05 control strings: no driver here accepts them (error 1)
//  06 input status, 07 output status -> x0 = FFh ready / 0
//  08 removable (x0 drive) -> x0 = 0 removable, 1 fixed
//  09 remote drive (x0 drive) -> x2 attributes; 0Ah remote handle -> x2
//  0Bh sharing retry (x2 retries, x3 delay) accepted
//  0Ch generic character IOCTL: error 1
//  0Dh generic block IOCTL: x0 drive, x2 = category/minor (0866h get media
//      ID, 0846h set media ID), x3 = buffer
//  0Eh get logical drive map -> x0 = 0; 0Fh set logical drive map
dos_ioctl:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x22, x2
    cmp x20, #0x0f
    b.hi ioctl_invalid
    adr x9, ioctl_table
    ldrsw x10, [x9, x20, lsl #2]
    add x10, x9, x10
    br x10
.balign 4
ioctl_table:
    .word ioctl_get_info - ioctl_table
    .word ioctl_set_info - ioctl_table
    .word ioctl_char_control - ioctl_table
    .word ioctl_char_control - ioctl_table
    .word ioctl_block_control - ioctl_table
    .word ioctl_block_control - ioctl_table
    .word ioctl_input_status - ioctl_table
    .word ioctl_output_status - ioctl_table
    .word ioctl_removable - ioctl_table
    .word ioctl_remote_drive - ioctl_table
    .word ioctl_remote_handle - ioctl_table
    .word ioctl_retry - ioctl_table
    .word ioctl_char_control - ioctl_table
    .word ioctl_generic_block - ioctl_table
    .word ioctl_get_map - ioctl_table
    .word ioctl_set_map - ioctl_table

// x19 = handle. Returns x0 = object, or 0 for an unredirected standard
// console handle (0-2); fails the IOCTL for anything else.
ioctl_handle_object:
    cmp x19, #32
    b.hs 1f
    address x9, handles
    ldr x0, [x9, x19, lsl #3]
    cbnz x0, 2f
    cmp x19, #2
    b.hi 1f
    address x0, dev_objects     // standard console handle
2:
    mov x1, #0
    ret
1:
    mov x0, #6
    mov x1, #1
    ret

ioctl_get_info:
    bl ioctl_handle_object
    cbnz x1, ioctl_error
    address x9, handles
    ldr x9, [x9, x19, lsl #3]
    cbnz x9, 1f
    mov x0, #0x82               // unredirected console: input 81h, output 82h
    cbnz x19, ioctl_value
    mov x0, #0x81
    b ioctl_value
1:
    mov x21, x0
    bl dev_id_of
    cmn x0, #1
    b.eq 2f
    ldr x0, [x21, #DEV_ATTR]
    b ioctl_value
2:
    mov x0, #0                  // disk file on drive A:, written
    b ioctl_value

ioctl_set_info:
    bl ioctl_handle_object
    cbnz x1, ioctl_error
    mov x21, x0
    bl dev_id_of
    cmn x0, #1
    b.eq ioctl_invalid          // files: DOS refuses (error 1)
    cmp x22, #0xff
    b.hi ioctl_invalid          // DH must be 0
    // Only the raw (binary) bit 5 is changeable; the rest is fixed.
    ldr x2, [x21, #DEV_ATTR]
    bic x2, x2, #0x20
    and x3, x22, #0x20
    orr x2, x2, x3
    str x2, [x21, #DEV_ATTR]
    mov x0, x2
    b ioctl_value

ioctl_char_control:
    bl ioctl_handle_object
    cbnz x1, ioctl_error
    b ioctl_invalid

ioctl_block_control:
    mov x0, x19
    bl disk_check_drive
    cbnz x1, ioctl_error
    b ioctl_invalid

ioctl_input_status:
    bl ioctl_handle_object
    cbnz x1, ioctl_error
    mov x21, x0
    bl dev_id_of
    cmn x0, #1
    b.eq ioctl_file_input
    cmp x0, #DEV_AUX
    b.hi 1f
    bl poll_key
    cmp x0, #0
    mov x0, #255
    csel x0, x0, xzr, ne
    b ioctl_value
1:
    cmp x0, #DEV_CLOCK
    mov x0, #255
    csel x0, x0, xzr, eq        // NUL and PRN have no input
    b ioctl_value
ioctl_file_input:
    sub sp, sp, #16
    mov x0, x21
    mov x1, sp
    ldr x3, [x0, #48]           // GetPosition
    blr x3
    ldr x19, [sp]
    add sp, sp, #16
    cbnz x0, ioctl_efi_error
    mov x0, x21
    bl get_file_info
    cbnz x0, ioctl_efi_error
    ldr x2, [x1, #8]
    cmp x19, x2
    mov x0, #255
    csel x0, x0, xzr, lo
    b ioctl_value

ioctl_output_status:
    bl ioctl_handle_object
    cbnz x1, ioctl_error
    mov x0, #255
    b ioctl_value

ioctl_removable:
    mov x0, x19
    bl disk_check_drive
    cbnz x1, ioctl_error
    mov x0, #1                  // fixed disk
    b ioctl_value

ioctl_remote_drive:
    mov x0, x19
    bl disk_check_drive
    cbnz x1, ioctl_error
    mov x0, #0
    b ioctl_value

ioctl_remote_handle:
    bl ioctl_handle_object
    cbnz x1, ioctl_error
    mov x0, #0
    b ioctl_value

ioctl_retry:
    mov x0, #0
    b ioctl_value

ioctl_generic_block:
    mov x0, x19
    bl disk_check_drive
    cbnz x1, ioctl_error
    and x9, x22, #0xffff
    mov x10, #0x0860
    cmp x9, x10
    b.eq ioctl_device_params
    mov x10, #0x0861
    cmp x9, x10
    b.eq ioctl_read_sectors
    mov x10, #0x0841
    cmp x9, x10
    b.eq ioctl_write_sectors
    mov x10, #0x0866
    cmp x9, x10
    b.eq 1f
    mov x10, #0x0846
    cmp x9, x10
    b.ne ioctl_invalid
    mov x0, #1
    b 2f
1:
    mov x0, #0
2:
    mov x1, x19
    mov x2, x3
    bl dos_media_id
    cbnz x1, ioctl_error
    b ioctl_value

// 0860h: x3 = 88-byte buffer: u64 bytes per sector, sectors per cluster,
// FAT type, first data sector, clusters, first FAT sector, sectors per FAT,
// FAT copies, first root sector, root entries, root cluster.
ioctl_device_params:
    cbz x3, ioctl_invalid
    ldv x9, fat_bps
    str x9, [x3]
    ldv x9, fat_spc
    str x9, [x3, #8]
    ldv x9, fat_type
    str x9, [x3, #16]
    ldv x9, fat_data_start
    str x9, [x3, #24]
    ldv x9, fat_clusters
    str x9, [x3, #32]
    ldv x9, fat_fat_start
    str x9, [x3, #40]
    ldv x9, fat_fat_sectors
    str x9, [x3, #48]
    ldv x9, fat_num_fats
    str x9, [x3, #56]
    ldv x9, fat_root_start
    str x9, [x3, #64]
    ldv x9, fat_root_entries
    str x9, [x3, #72]
    ldv x9, fat_root_cluster
    str x9, [x3, #80]
    mov x0, #0
    b ioctl_value

// 0861h read / 0841h write sectors (DOS's read/write track): x3 = block of
// u64 first sector (volume relative), u64 count, u64 buffer. Goes through
// the sector cache, so the filesystem sees the same data.
ioctl_read_sectors:
    mov x21, #0
    b 1f
ioctl_write_sectors:
    mov x21, #1
1:
    cbz x3, ioctl_invalid
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    ldr x23, [x3]               // sector
    ldr x24, [x3, #8]           // count
    ldr x25, [x3, #16]          // buffer
2:
    cbz x24, 5f
    mov x0, x23
    cbnz x21, 3f
    bl fat_cache_read
    cbnz x0, 6f
    mov x0, x1
    mov x1, x25
    ldv x2, fat_bps
    bl copy_bytes
    b 4f
3:
    bl fat_cache_claim
    cbnz x0, 6f
    mov x26, x1
    mov x0, x25
    ldv x2, fat_bps
    bl copy_bytes
    mov x0, x26
    bl fat_cache_commit
    cbnz x0, 6f
4:
    ldv x2, fat_bps
    add x25, x25, x2
    add x23, x23, #1
    sub x24, x24, #1
    b 2b
5:
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    mov x0, #0
    b ioctl_value
6:
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    b ioctl_efi_error

ioctl_get_map:
    mov x0, x19
    bl disk_check_drive
    cbnz x1, ioctl_error
    mov x0, #0                  // only one letter names this drive
    b ioctl_value

ioctl_set_map:
    mov x0, x19
    bl disk_check_drive
    cbnz x1, ioctl_error
    mov x0, #0
    b ioctl_value

ioctl_value:
    mov x2, x0
    mov x1, #0
    b ioctl_return
ioctl_invalid:
    mov x0, #1
    b ioctl_error
ioctl_efi_error:
    bl efi_error_to_dos
ioctl_error:
    mov x1, #1
ioctl_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

.section .bss
.balign 16
dos_dpb: .skip 64
dos_sysvars: .skip 112
