// SPDX-License-Identifier: MIT
// CHKDSK [d:][path][filename] [/F] [/V] (v4.0/src/CMD/CHKDSK): walks every
// directory and FAT chain, reports cross-links, allocation errors and lost
// chains (converted to FILEnnnn.CHK or freed with /F), the disk and memory
// summary, and for a file specification whether the files are contiguous.
.include "lib.inc"
.include "fatlib.inc"
.equ DIR_SIZE, 262144
.equ POOL_SIZE, 131072
.equ MAX_SPECS, 64

main:
    enter
    mov x19, x0
    mov x20, #0                 // flags: 1 /F, 2 /V
    address x0, spec
    strb wzr, [x0]
1:
    mov x0, x19
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, 3f
    cmp w2, #'/'
    b.ne 2f
    ldrb w0, [x0, #1]
    bl toupper
    mov x2, #1
    cmp w0, #'F'
    b.eq 11f
    mov x2, #2
    cmp w0, #'V'
    b.ne bad_switch
11:
    orr x20, x20, x2
    b 1b
2:
    address x1, spec
    bl strcpy
    b 1b
3:
    address x9, opt_flags
    str x20, [x9]
    address x0, spec            // the drive: from the specification
    bl path_drive_letter
    address x9, root_text
    strb w0, [x9]
    address x9, error_drive
    strb w0, [x9]
    address x9, chk_name        // FILEnnnn.CHK goes on the checked drive
    strb w0, [x9]
    sub x0, x0, #('A' - 1)
    address x9, fl_drive
    str x0, [x9]
    bl fl_init
    cbnz x1, disk_error
    flp x2, FL_BPS
    flp x3, FL_SPC
    mul x2, x2, x3
    address x9, cluster_bytes
    str x2, [x9]
    // Cluster bitmap, one bit per cluster number.
    flp x0, FL_CLUSTERS
    add x0, x0, #2 + 7
    lsr x0, x0, #3
    address x9, bitmap_bytes
    str x0, [x9]
    dos 0x48
    cbnz x1, no_memory
    address x9, bitmap
    str x0, [x9]
    bl clear_bitmap
    bl collect_specs
    // FAT32: the root directory's own chain.
    flp x2, FL_TYPE
    cmp x2, #32
    b.ne 4f
    flp x0, FL_ROOT_CLUSTER
    mov x1, #1
    bl walk_chain
4:
    address x0, path
    address x1, root_text
    bl strcpy
    mov x0, #0
    bl check_directory
    bl lost_chains
    bl summary
    bl report_contiguity
    mov x0, #0
    leave
bad_switch:
    say "Invalid parameter\r\n"
    mov x0, #1
    leave
no_memory:
    say "Insufficient memory\r\n"
    mov x0, #1
    leave
disk_error:
    say "Disk error reading drive "
    address x0, error_drive
    bl puts
    bl crlf
    mov x0, #1
    leave

clear_bitmap:
    address x9, bitmap
    ldr x0, [x9]
    address x9, bitmap_bytes
    ldr x1, [x9]
1:
    cbz x1, 2f
    strb wzr, [x0], #1
    sub x1, x1, #1
    b 1b
2:
    ret

// x0 = cluster. Sets its bit; returns x0 = 1 if it was already set.
mark_cluster:
    address x9, bitmap
    ldr x9, [x9]
    lsr x1, x0, #3
    and x2, x0, #7
    ldrb w3, [x9, x1]
    mov w4, #1
    lsl w4, w4, w2
    tst w3, w4
    cset x0, ne
    orr w3, w3, w4
    strb w3, [x9, x1]
    ret

// x0 = cluster. Returns x0 = 1 if marked.
is_marked:
    address x9, bitmap
    ldr x9, [x9]
    lsr x1, x0, #3
    and x2, x0, #7
    ldrb w3, [x9, x1]
    lsr w3, w3, w2
    and x0, x3, #1
    ret

// x0 = first cluster, x1 = 1 to stay quiet. Marks the chain. Returns
// x0 = clusters, x1 = 0 ok / 1 cross-linked / 2 invalid cluster,
// x2 = cluster where the problem was seen, x3 = non-contiguous blocks.
walk_chain:
    enter
    mov x19, x0
    mov x20, #0                 // count
    mov x21, #0                 // status
    mov x22, #0
    mov x23, #1                 // contiguous blocks
    bl fl_eoc
    mov x24, x0
    flp x25, FL_CLUSTERS
    add x25, x25, #2
    mov x26, #0                 // previous cluster
1:
    cmp x19, #2
    b.lo 8f
    cmp x19, x24
    b.hs 9f
    cmp x19, x25
    b.hs 8f
    cbz x26, 11f
    add x2, x26, #1
    cmp x2, x19
    b.eq 11f
    add x23, x23, #1
11:
    mov x0, x19
    bl mark_cluster
    cbz x0, 2f
    cbnz x21, 2f
    mov x21, #1
    mov x22, x19
2:
    add x20, x20, #1
    mov x26, x19
    mov x0, x19
    bl fl_get
    cbz x0, 8f                  // a free entry inside a chain
    mov x19, x0
    mov x2, #0x100000
    cmp x20, x2
    b.hi 8f                     // loop guard
    b 1b
8:
    cbnz x21, 9f
    mov x21, #2
    mov x22, x26
9:
    mov x0, x20
    mov x1, x21
    mov x2, x22
    mov x3, x23
    leave

// x0 = directory cluster (0 = root); `path` holds its name.
check_directory:
    enter
    mov x19, x0
    address x9, depth
    ldr x2, [x9]
    add x2, x2, #1
    str x2, [x9]
    cmp x2, #32
    b.hi 99f
    address x0, pool_used
    ldr x20, [x0]               // subdirectories recorded from here
    mov x21, x20
    mov x0, x19
    address x1, dir
    mov x2, #DIR_SIZE
    bl fl_dir_load
    cbnz x1, 99f
    mov x22, x0                 // bytes
    mov x23, #0                 // offset
    mov x28, #0                 // directory changed (fixes)
1:
    cmp x23, x22
    b.hs 7f
    address x24, dir
    add x24, x24, x23
    ldrb w2, [x24]
    cbz w2, 7f
    cmp w2, #0xe5
    b.eq 6f
    ldrb w25, [x24, #11]
    cmp w25, #0x0f
    b.eq 6f
    tbnz w25, #3, volume_entry
    cmp w2, #'.'
    b.eq 6f
    // Full name of this entry.
    address x0, path
    bl strlen
    mov x26, x0
    mov x0, x24
    address x1, path
    add x1, x1, x26
    bl fl_entry_name
    address x9, opt_flags
    ldr x9, [x9]
    tbz x9, #1, 2f
    address x0, path
    bl puts
    bl crlf
2:
    mov x0, x24
    bl fl_entry_cluster
    mov x27, x0
    tbnz w25, #4, subdirectory
    // A file.
    ldr w3, [x24, #28]
    cbz x27, 5f                 // empty file
    mov x0, x27
    mov x1, #0
    bl walk_chain
    stp x0, x3, [sp, #-16]!
    bl chain_problem
    ldp x0, x3, [sp]
    bl spec_check
    ldp x0, x3, [sp], #16
    address x9, cluster_bytes
    ldr x9, [x9]
    mul x4, x0, x9
    ldr w3, [x24, #28]
    // Size must fit the chain: (clusters - 1) * bytes < size <= clusters * bytes
    cmp x3, x4
    b.hi 3f
    sub x5, x4, x9
    cmp x3, x5
    b.hi 4f
3:
    address x0, path
    bl puts
    say "\r\n   Allocation error, size adjusted\r\n"
    address x9, errors
    mov x2, #1
    str x2, [x9]
    address x9, opt_flags
    ldr x9, [x9]
    tbz x9, #0, 4f
    str w4, [x24, #28]
    mov x28, #1
4:
    tbz w25, #1, 41f
    address x9, hidden_files
    ldr x2, [x9]
    add x2, x2, #1
    str x2, [x9]
    address x9, hidden_bytes
    b 42f
41:
    address x9, user_files
    ldr x2, [x9]
    add x2, x2, #1
    str x2, [x9]
    address x9, user_bytes
42:
    ldr x2, [x9]
    add x2, x2, x4
    str x2, [x9]
    b 5f
subdirectory:
    mov x0, x27
    mov x1, #0
    bl walk_chain
    stp x0, x3, [sp, #-16]!
    bl chain_problem
    ldp x0, x3, [sp], #16
    address x9, cluster_bytes
    ldr x9, [x9]
    mul x4, x0, x9
    address x9, dir_count
    ldr x2, [x9]
    add x2, x2, #1
    str x2, [x9]
    address x9, dir_bytes
    ldr x2, [x9]
    add x2, x2, x4
    str x2, [x9]
    // Remember it: cluster, then its name.
    address x9, pool
    add x0, x9, x21
    mov x2, #(POOL_SIZE - 512)
    cmp x21, x2
    b.hs 5f
    str x27, [x0]
    add x1, x0, #8
    address x0, path
    add x0, x0, x26
    bl strcpy
    address x9, pool
    sub x0, x0, x9
    add x21, x0, #1
    add x21, x21, #7
    and x21, x21, #~7
5:
    address x0, path            // drop the name again
    strb wzr, [x0, x26]
6:
    add x23, x23, #32
    b 1b
volume_entry:
    address x9, volume_entry_copy
    ldp x2, x3, [x24]
    stp x2, x3, [x9]
    ldp x2, x3, [x24, #16]
    stp x2, x3, [x9, #16]
    b 6b
7:
    cbz x28, 71f
    address x0, dir
    bl fl_dir_write
71:
    address x9, pool_used
    str x21, [x9]
    // Children.
    mov x22, x20
8:
    cmp x22, x21
    b.hs 99f
    address x9, pool
    add x23, x9, x22
    ldr x24, [x23]
    add x25, x23, #8
    address x0, path
    bl strlen
    mov x26, x0
    mov x0, x25
    address x1, path
    add x1, x1, x26
    bl strcpy
    mov w2, #'\\'
    strb w2, [x0]
    strb wzr, [x0, #1]
    mov x0, x24
    bl check_directory
    address x0, path
    strb wzr, [x0, x26]
    mov x0, x25
    bl strlen
    add x22, x22, #8
    add x22, x22, x0
    add x22, x22, #1
    add x22, x22, #7
    and x22, x22, #~7
    b 8b
99:
    address x9, pool_used
    str x20, [x9]
    address x9, depth
    ldr x2, [x9]
    sub x2, x2, #1
    str x2, [x9]
    leave

// After walk_chain (x1 status, x2 cluster): prints problems for `path`.
chain_problem:
    frame
    cbz x1, 9f
    stp x1, x2, [sp, #-16]!
    address x9, errors
    mov x3, #1
    str x3, [x9]
    address x0, path
    bl puts
    ldp x1, x2, [sp], #16
    cmp x1, #1
    b.ne 1f
    stp x1, x2, [sp, #-16]!
    say "\r\n   Is cross linked on allocation unit "
    ldp x1, x0, [sp], #16
    mov x1, #0
    bl put_dec
    bl crlf
    b 9f
1:
    say "\r\n   Has invalid allocation unit, file truncated\r\n"
9:
    unframe

// Lost clusters: allocated in the FAT but in no chain.
lost_chains:
    enter
    bl fl_eoc
    mov x19, x0
    flp x20, FL_CLUSTERS
    add x20, x20, #2
    // Second bitmap marks clusters that some lost cluster points to.
    address x9, bitmap_bytes
    ldr x0, [x9]
    dos 0x48
    cbnz x1, 9f
    mov x21, x0
    address x9, bitmap_bytes
    ldr x2, [x9]
    mov x3, #0
1:
    cmp x3, x2
    b.hs 2f
    strb wzr, [x21, x3]
    add x3, x3, #1
    b 1b
2:
    mov x22, #2                 // cluster
    mov x23, #0                 // lost clusters
    mov x24, #0                 // free clusters
    mov x25, #0                 // bad clusters
3:
    cmp x22, x20
    b.hs 5f
    mov x0, x22
    bl fl_get
    cbnz x0, 31f
    add x24, x24, #1
    b 4f
31:
    sub x2, x19, #1             // bad cluster marker is EOC base - 1
    cmp x0, x2
    b.ne 32f
    add x25, x25, #1
    b 4f
32:
    mov x26, x0
    mov x0, x22
    bl is_marked
    cbnz x0, 4f
    add x23, x23, #1
    cmp x26, #2
    b.lo 4f
    cmp x26, x20
    b.hs 4f
    lsr x1, x26, #3             // referenced by a lost cluster
    and x2, x26, #7
    ldrb w3, [x21, x1]
    mov w4, #1
    lsl w4, w4, w2
    orr w3, w3, w4
    strb w3, [x21, x1]
4:
    add x22, x22, #1
    b 3b
5:
    address x9, free_clusters
    str x24, [x9]
    address x9, bad_clusters
    str x25, [x9]
    cbz x23, 9f
    address x9, errors
    mov x2, #1
    str x2, [x9]
    address x9, opt_flags
    ldr x9, [x9]
    tbnz x9, #0, 51f
    say "Errors found, F parameter not specified\r\nCorrections will not be written to disk\r\n\r\n"
51:
    // Count chain heads.
    mov x22, #2
    mov x26, #0
6:
    cmp x22, x20
    b.hs 7f
    mov x0, x22
    bl is_marked
    cbnz x0, 61f
    mov x0, x22
    bl fl_get
    cbz x0, 61f
    sub x2, x19, #1
    cmp x0, x2
    b.eq 61f
    lsr x1, x22, #3
    and x2, x22, #7
    ldrb w3, [x21, x1]
    lsr w3, w3, w2
    tbnz w3, #0, 61f
    add x26, x26, #1
61:
    add x22, x22, #1
    b 6b
7:
    mov x0, x23
    mov x1, #0
    bl put_dec
    say " lost allocation units found in "
    mov x0, x26
    mov x1, #0
    bl put_dec
    say " chains.\r\n"
    address x0, convert_question
    bl ask_yn
    mov x27, x0
    address x9, opt_flags
    ldr x9, [x9]
    tbz x9, #0, 8f
    // /F: convert each chain to a file, or free it.
    mov x22, #2
    mov x28, #0                 // file number
71:
    cmp x22, x20
    b.hs 8f
    mov x0, x22
    bl is_marked
    cbnz x0, 72f
    mov x0, x22
    bl fl_get
    cbz x0, 72f
    sub x2, x19, #1
    cmp x0, x2
    b.eq 72f
    lsr x1, x22, #3
    and x2, x22, #7
    ldrb w3, [x21, x1]
    lsr w3, w3, w2
    tbnz w3, #0, 72f
    mov x0, x22
    mov x1, x27
    mov x2, x28
    bl recover_chain
    add x28, x0, #1
72:
    add x22, x22, #1
    b 71b
8:
    address x9, cluster_bytes
    ldr x9, [x9]
    mul x0, x23, x9
    mov x1, #10
    bl put_dec
    say " bytes disk space\r\n           "
    address x9, opt_flags
    ldr x9, [x9]
    tbnz x9, #0, 80f
    say "would be "
80:
    cbz x27, 81f
    say "converted to files\r\n"
    b 82f
81:
    say "freed\r\n"
82:
    address x9, opt_flags
    ldr x9, [x9]
    tbz x9, #0, 9f
    // Freed space now counts as free.
    cbnz x27, 9f
    address x9, free_clusters
    ldr x2, [x9]
    add x2, x2, x23
    str x2, [x9]
9:
    leave

// x0 = chain head, x1 = 1 convert / 0 free, x2 = file number.
recover_chain:
    enter
    mov x19, x0
    mov x20, x2
    cbnz x1, 3f
    // Free every cluster of the chain.
    bl fl_eoc
    mov x21, x0
    flp x23, FL_CLUSTERS
    add x23, x23, #2
1:
    cmp x19, #2
    b.lo 9f
    cmp x19, x21
    b.hs 9f
    // Stop at a cluster outside the volume, or one that already belongs to
    // a live file (cross-link) or was freed: never free someone else's data.
    cmp x19, x23
    b.hs 9f
    mov x0, x19
    bl is_marked
    cbnz x0, 9f
    mov x0, x19
    bl fl_get
    mov x22, x0
    mov x0, x19
    mov x1, #0
    bl fl_set
    mov x0, x19
    bl mark_cluster
    mov x19, x22
    b 1b
3:
    // Mark the chain and count it.
    mov x0, x19
    mov x1, #1
    bl walk_chain
    mov x21, x0
    cmp x1, #2                  // links outside the volume: end it at the
    b.ne 30f                    // last good cluster
    mov x22, x2
    bl fl_eoc
    mov x1, x0
    mov x0, x22
    bl fl_set
    // Create d:\FILEnnnn.CHK, then point its entry at the chain. Like DOS,
    // skip numbers already in use so earlier recoveries are never truncated.
30:
    address x0, chk_name
    mov x3, x20
    mov x6, #10
    mov x4, #10
31:
    udiv x7, x3, x6
    msub x5, x7, x6, x3
    add w5, w5, #'0'
    strb w5, [x0, x4]
    mov x3, x7
    sub x4, x4, #1
    cmp x4, #7
    b.hs 31b
    mov x1, #0
    dos 0x5b                    // create new: fails if the name exists
    cbz x1, 32f
    cmp x0, #80                 // file exists: try the next number
    b.ne 9f
    add x20, x20, #1
    mov x9, #10000
    cmp x20, x9
    b.lo 30b
    b 9f
32:
    bl fclose
    mov x0, #0
    address x1, dir
    mov x2, #DIR_SIZE
    bl fl_dir_load
    cbnz x1, 9f
    mov x22, x0
    address x23, dir
    add x24, x23, x22
    address x0, chk_name
    add x0, x0, #3              // past "d:\"
    address x1, chk_short
    mov x2, #0
4:
    ldrb w3, [x0], #1
    cmp w3, #'.'
    b.eq 41f
    strb w3, [x1, x2]
    add x2, x2, #1
    b 4b
41:
    ldrb w3, [x0], #1
    strb w3, [x1, #8]
    ldrb w3, [x0], #1
    strb w3, [x1, #9]
    ldrb w3, [x0], #1
    strb w3, [x1, #10]
5:
    cmp x23, x24
    b.hs 9f
    mov x2, #0
51:
    ldrb w3, [x23, x2]
    ldrb w4, [x1, x2]
    cmp w3, w4
    b.ne 6f
    add x2, x2, #1
    cmp x2, #11
    b.lo 51b
    strh w19, [x23, #26]
    lsr x2, x19, #16
    strh w2, [x23, #20]
    address x9, cluster_bytes
    ldr x9, [x9]
    mul x2, x21, x9
    str w2, [x23, #28]
    address x0, dir
    bl fl_dir_write
    b 9f
6:
    add x23, x23, #32
    b 5b
9:
    mov x0, x20                 // the file number used (for the next chain)
    leave

summary:
    enter
    bl crlf
    address x9, volume_entry_copy
    ldrb w2, [x9]
    cbz w2, 1f
    say " Volume "
    address x0, volume_entry_copy
    address x1, text
    mov x2, #0
11:
    ldrb w3, [x0, x2]
    strb w3, [x1, x2]
    add x2, x2, #1
    cmp x2, #11
    b.lo 11b
    strb wzr, [x1, #11]
    address x0, text
    bl puts
    say " created "
    address x9, volume_entry_copy
    ldrh w19, [x9, #24]
    ubfx x0, x19, #5, #4
    mov x1, #2
    bl put_dec0
    mov x0, #'-'
    bl putc
    and x0, x19, #31
    mov x1, #2
    bl put_dec0
    mov x0, #'-'
    bl putc
    lsr x0, x19, #9
    add x0, x0, #1980
    mov x1, #4
    bl put_dec
    mov x0, #' '
    bl putc
    address x9, volume_entry_copy
    ldrh w19, [x9, #22]
    lsr x20, x19, #11
    mov x21, #'a'
    cmp x20, #12
    b.lo 12f
    mov x21, #'p'
    sub x20, x20, #12
12:
    cbnz x20, 13f
    mov x20, #12
13:
    mov x0, x20
    mov x1, #2
    bl put_dec
    mov x0, #':'
    bl putc
    ubfx x0, x19, #5, #6
    mov x1, #2
    bl put_dec0
    mov x0, x21
    bl putc
    bl crlf
1:
    mov x0, #0
    address x9, fl_drive
    ldr x1, [x9]
    address x2, media
    dos 0x69
    cbnz x1, 2f
    say " Volume Serial Number is "
    address x0, media
    ldrh w0, [x0, #4]
    mov x1, #4
    bl put_hex
    mov x0, #'-'
    bl putc
    address x0, media
    ldrh w0, [x0, #2]
    mov x1, #4
    bl put_hex
    bl crlf
2:
    bl crlf
    address x9, cluster_bytes
    ldr x19, [x9]
    flp x20, FL_CLUSTERS
    mul x0, x20, x19
    mov x1, #12
    bl put_dec
    say " bytes total disk space\r\n"
    address x9, bad_clusters
    ldr x0, [x9]
    cbz x0, 3f
    mul x0, x0, x19
    mov x1, #12
    bl put_dec
    say " bytes in bad sectors\r\n"
3:
    address x9, hidden_files
    ldr x21, [x9]
    cbz x21, 4f
    address x9, hidden_bytes
    ldr x0, [x9]
    mov x1, #12
    bl put_dec
    say " bytes in "
    mov x0, x21
    mov x1, #0
    bl put_dec
    say " hidden files\r\n"
4:
    address x9, dir_count
    ldr x21, [x9]
    cbz x21, 5f
    address x9, dir_bytes
    ldr x0, [x9]
    mov x1, #12
    bl put_dec
    say " bytes in "
    mov x0, x21
    mov x1, #0
    bl put_dec
    say " directories\r\n"
5:
    address x9, user_bytes
    ldr x0, [x9]
    mov x1, #12
    bl put_dec
    say " bytes in "
    address x9, user_files
    ldr x0, [x9]
    mov x1, #0
    bl put_dec
    say " user files\r\n"
    address x9, free_clusters
    ldr x21, [x9]
    mul x0, x21, x19
    mov x1, #12
    bl put_dec
    say " bytes available on disk\r\n\r\n"
    mov x0, x19
    mov x1, #12
    bl put_dec
    say " bytes in each allocation unit\r\n"
    mov x0, x20
    mov x1, #12
    bl put_dec
    say " total allocation units on disk\r\n"
    mov x0, x21
    mov x1, #12
    bl put_dec
    say " available allocation units on disk\r\n\r\n"
    dos 0x52
    ldr x19, [x0, #88]
    ldr x20, [x0, #96]
    cbz x19, 6f
    mov x0, x19
    mov x1, #12
    bl put_dec
    say " total bytes memory\r\n"
    mov x0, x20
    mov x1, #12
    bl put_dec
    say " bytes free\r\n"
6:
    leave

// File specification: truenames of the matching files, checked as the
// walk meets them.
collect_specs:
    enter
    address x0, spec
    ldrb w2, [x0]
    cbz w2, 9f
    bl is_directory
    cbnz x0, 9f
    address x0, spec
    address x1, spec_dir
    bl strcpy
    address x0, spec_dir
    bl basename
    address x1, spec_dir
    sub x19, x0, x1
    address x0, dta
    mov x1, #280
    dos 0x1a
    address x0, spec
    mov x1, #0
    dos 0x4e
    cbnz x1, 8f
    mov x20, #0
1:
    cmp x20, #MAX_SPECS
    b.hs 8f
    address x0, dta
    add x0, x0, #24
    address x1, spec_dir
    add x1, x1, x19
    bl strcpy
    address x0, spec_dir
    address x1, specs
    lsl x2, x20, #7
    add x1, x1, x2
    dos 0x60
    cbnz x1, 2f
    add x20, x20, #1
2:
    dos 0x4f
    cbz x1, 1b
8:
    address x9, spec_count
    str x20, [x9]
    address x9, spec_active
    mov x2, #1
    str x2, [x9]
9:
    leave

// x0 = clusters, x3 = contiguous blocks, `path` = file: records it if it
// is one of the specified files.
spec_check:
    enter
    mov x19, x3
    address x9, spec_count
    ldr x20, [x9]
    mov x21, #0
1:
    cmp x21, x20
    b.hs 9f
    address x0, specs
    lsl x2, x21, #7
    add x0, x0, x2
    address x1, path
    bl strcmpi
    cbz x0, 2f
    add x21, x21, #1
    b 1b
2:
    cmp x19, #1
    b.ls 9f
    address x9, fragmented
    mov x2, #1
    str x2, [x9]
    address x0, path
    bl puts
    say "\r\n   Contains "
    mov x0, x19
    mov x1, #0
    bl put_dec
    say " non-contiguous blocks\r\n"
9:
    leave

report_contiguity:
    frame
    address x9, spec_active
    ldr x2, [x9]
    cbz x2, 1f
    address x9, fragmented
    ldr x2, [x9]
    cbnz x2, 1f
    bl crlf
    say "All specified file(s) are contiguous\r\n"
1:
    unframe

.section .rodata
convert_question: .asciz "Convert lost chains to files (Y/N)? "
.section .data
chk_name: .asciz "A:\\FILE0000.CHK"
.section .bss
.balign 8
opt_flags: .skip 8
cluster_bytes: .skip 8
bitmap: .skip 8
bitmap_bytes: .skip 8
pool_used: .skip 8
depth: .skip 8
errors: .skip 8
user_files: .skip 8
user_bytes: .skip 8
hidden_files: .skip 8
hidden_bytes: .skip 8
dir_count: .skip 8
dir_bytes: .skip 8
free_clusters: .skip 8
bad_clusters: .skip 8
spec_count: .skip 8
spec_active: .skip 8
fragmented: .skip 8
volume_entry_copy: .skip 32
chk_short: .skip 16
media: .skip 32
text: .skip 16
dta: .skip 288
spec: .skip 256
spec_dir: .skip 256
path: .skip 1024
specs: .skip 128 * MAX_SPECS
dir: .skip DIR_SIZE
pool: .skip POOL_SIZE
.section .data
root_text: .asciz "A:\\"
error_drive: .asciz "A"
