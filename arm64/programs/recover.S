// SPDX-License-Identifier: MIT
// RECOVER [d:][path]filename | RECOVER d: (v4.0/src/CMD/RECOVER).
// For a file: reads every allocation unit; unreadable ones are marked bad
// and dropped from the chain, and the size is adjusted ("n of m bytes
// recovered"). For a drive: every root directory entry becomes FILEnnnn.REC.
.include "lib.inc"
.include "fatlib.inc"
.equ DIR_SIZE, 262144

main:
    enter
    bl next_arg
    mov x19, x0
    ldrb w2, [x19]
    cbz w2, missing
    mov x0, x19                 // the drive named (fl_resolve also sets it)
    bl path_drive_letter
    address x9, drive_text
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
    ldrb w2, [x19, #1]
    cmp w2, #':'
    b.ne recover_file
    ldrb w2, [x19, #2]
    cbz w2, recover_drive
recover_file:
    mov x0, x19
    address x1, dir
    mov x2, #DIR_SIZE
    bl fl_resolve
    cbnz x1, disk_error
    cbz x0, not_found
    mov x20, x0                 // the entry
    ldrb w2, [x20, #11]
    tbnz w2, #4, not_found      // directories are not files
    bl press_to_begin
    ldr w21, [x20, #28]         // original size
    mov x0, x20
    bl fl_entry_cluster
    mov x22, x0                 // cluster
    mov x23, #0                 // previous good cluster
    mov x24, #0                 // good clusters
    bl fl_eoc
    mov x25, x0
1:
    cmp x22, #2
    b.lo 5f
    sub x9, x25, #1             // the bad-cluster marker ends the walk too
    cmp x22, x9
    b.hs 5f
    mov x0, x22
    bl fl_get
    mov x26, x0                 // next
    mov x0, x22
    bl fl_cluster_sector
    flp x1, FL_SPC
    address x2, cluster
    bl fl_read
    cbz x1, 3f
    // Unreadable: mark bad and unlink.
    mov x0, x22
    sub x1, x25, #1
    bl fl_set
    cbz x23, 2f
    mov x0, x23
    mov x1, x26
    bl fl_set
    b 4f
2:
    sub x9, x25, #1             // the file now starts at the next unit,
    cmp x26, x9                 // or at none (0) when that is the end, a
    csel x2, xzr, x26, hs       // bad-cluster mark, free or reserved
    cmp x26, #2
    csel x2, xzr, x2, lo
    strh w2, [x20, #26]
    lsr x2, x2, #16
    strh w2, [x20, #20]
    b 4f
3:
    add x24, x24, #1
    mov x23, x22
4:
    mov x22, x26
    b 1b
5:
    address x9, cluster_bytes
    ldr x9, [x9]
    mul x2, x24, x9
    cmp x2, x21
    csel x2, x2, x21, lo        // recovered bytes
    mov x27, x2
    str w27, [x20, #28]
    address x0, dir
    bl fl_dir_write
    cbnz x1, disk_error
    mov x0, x27
    mov x1, #0
    bl put_dec
    say " of "
    mov x0, x21
    mov x1, #0
    bl put_dec
    say " bytes recovered\r\n"
    mov x0, #0
    leave

recover_drive:
    mov w0, w2
    bl press_to_begin
    mov x0, #0
    address x1, dir
    mov x2, #DIR_SIZE
    bl fl_dir_load
    cbnz x1, disk_error
    mov x20, x0
    mov x21, #0                 // offset
    mov x22, #0                 // files
1:
    cmp x21, x20
    b.hs 5f
    address x23, dir
    add x23, x23, x21
    ldrb w2, [x23]
    cbz w2, 5f
    cmp w2, #0xe5
    b.eq 4f
    ldrb w3, [x23, #11]
    cmp w3, #0x0f
    b.ne 2f
    mov w2, #0xe5               // long names go
    strb w2, [x23]
    b 4f
2:
    tbnz w3, #3, 4f             // keep the volume label
    mov w24, w3
    add x22, x22, #1
    // FILEnnnnREC
    address x9, rec_name
    ldp x4, x5, [x9]
    str x4, [x23]
    strh w5, [x23, #8]
    lsr x5, x5, #16
    strb w5, [x23, #10]
    mov x3, x22
    mov x6, #10
    mov x4, #7
3:
    udiv x7, x3, x6
    msub x5, x7, x6, x3
    add w5, w5, #'0'
    strb w5, [x23, x4]
    mov x3, x7
    sub x4, x4, #1
    cmp x4, #4
    b.hs 3b
    // Directories become files sized by their chain.
    tbz w24, #4, 4f
    mov w2, #0x20
    strb w2, [x23, #11]
    mov x0, x23
    bl fl_entry_cluster
    bl chain_length
    address x9, cluster_bytes
    ldr x9, [x9]
    mul x0, x0, x9
    str w0, [x23, #28]
4:
    add x21, x21, #32
    b 1b
5:
    address x0, dir
    bl fl_dir_write
    cbnz x1, disk_error
    mov x0, x22
    mov x1, #0
    bl put_dec
    say " file(s) recovered\r\n"
    mov x0, #0
    leave
missing:
    say "Invalid number of parameters\r\n"
    mov x0, #1
    leave
not_found:
    say "File not found\r\n"
    mov x0, #1
    leave
disk_error:
    say "Disk error\r\n"
    mov x0, #1
    leave

press_to_begin:
    frame
    say "\r\nPress any key to begin recovery of the\r\nfile(s) on drive "
    address x0, drive_text
    bl puts
    say "\r\n\r\n"
    dos 0x08
    unframe

// x0 = first cluster. Returns x0 = clusters in the chain.
chain_length:
    enter
    mov x19, x0
    mov x20, #0
    bl fl_eoc
    mov x21, x0
1:
    cmp x19, #2
    b.lo 2f
    cmp x19, x21
    b.hs 2f
    add x20, x20, #1
    mov x2, #0x100000
    cmp x20, x2
    b.hs 2f
    mov x0, x19
    bl fl_get
    mov x19, x0
    b 1b
2:
    mov x0, x20
    leave

.section .rodata
.balign 8
rec_name: .ascii "FILE0000REC\0\0\0\0\0"
.section .bss
.balign 8
cluster_bytes: .skip 8
cluster: .skip 65536
dir: .skip DIR_SIZE
.section .data
drive_text: .asciz "A:"
