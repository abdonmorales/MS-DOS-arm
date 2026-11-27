// SPDX-License-Identifier: MIT
.equ NLS_FILE_MAX, 32768
.equ NLS_TABLE_ROOM, 64
// National language support (NLS): 38h country information, 65h extended
// country information and the code page 437 tables from DOSMES.ASM.
.section .text

// x0 = country code. Returns x0 = record (u16 id, u16 code page, 34-byte
// information block, 2 pad bytes) or 0.
nls_find_country:
    address x9, nls_loaded
    ldrh w10, [x9]
    cbz w10, 4f
    cmp x10, x0
    b.eq 3f
4:
    address x9, nls_countries
1:
    ldrh w10, [x9]
    cbz w10, 2f
    cmp x10, x0
    b.eq 3f
    add x9, x9, #40
    b 1b
2:
    mov x0, #0
    ret
3:
    mov x0, x9
    ret

// Code page 437 upper case (MAP_CASE / Ucase). x0 = character.
nls_upper:
    and w0, w0, #255
    cmp w0, #'a'
    b.lo 1f
    cmp w0, #'z'
    b.hi 2f
    sub w0, w0, #32
    ret
2:
    cmp w0, #128
    b.lo 1f
    address x9, nls_upper_data
    sub w10, w0, #128
    ldrb w0, [x9, x10]
1:
    ret

// 38h: x0 = 34-byte buffer, x1 = country (0 = current). With x0 = 0 the
// country x1 becomes current (what COUNTRY= does). Returns x0 = x2 = country.
dos_country:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    cbnz x20, 1f
    address x9, dos_country_code
    ldr x20, [x9]
1:
    mov x0, x20
    bl nls_find_country
    cbnz x0, 11f
    cbnz x19, 3f                // only setting may load from COUNTRY.SYS
    mov x0, x20
    mov x1, #0
    bl nls_reload
    cbnz x1, 3f
    mov x0, x20
    bl nls_find_country
    cbz x0, 3f
11:
    cbnz x19, 2f
    address x9, dos_country_code
    str x20, [x9]
    b 4f
2:
    add x0, x0, #4
    mov x1, x19
    mov x2, #34
    bl copy_bytes
4:
    mov x0, x20
    mov x2, x20
    mov x1, #0
    b 5f
3:
    mov x0, #2
    mov x1, #1
5:
    ldp x19, x20, [sp], #16
    unframe

// 65h: x0 = information id.
//   01h-07h: x1 = code page (FFFFh current), x2 = country (FFFFh current),
//            x3 = buffer, x4 = buffer size; x0 = bytes stored.
//            01h: id, u16 size, u16 country, u16 code page, 38h block.
//            02h upper case, 04h file upper case, 05h file characters,
//            06h collating, 07h DBCS: id byte then a u64 table pointer.
//   20h: x1 = character -> x0 upper case.  21h: x1 = buffer, x2 = length.
//   22h: x1 = ASCIIZ string.  23h: x1 = character -> 0 no, 1 yes, 2 neither.
dos_ext_country:
    cmp x0, #0x20
    b.eq nls_upper_char
    cmp x0, #0x21
    b.eq nls_upper_buffer
    cmp x0, #0x22
    b.eq nls_upper_string
    cmp x0, #0x23
    b.eq nls_yes_no
    cmp x0, #7
    b.hi nls_bad_function
    cbz x0, nls_bad_function
    cmp x0, #3
    b.eq nls_bad_function
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x3
    mov x21, x4
    and x9, x1, #0xffff
    mov x10, #0xffff
    cmp x9, x10
    b.eq 1f
    address x11, nls_code_page
    ldr x11, [x11]
    cmp x9, x11
    b.ne nls_not_found
1:
    and x22, x2, #0xffff
    cmp x22, x10
    b.ne 2f
    address x9, dos_country_code
    ldr x22, [x9]
2:
    mov x0, x22
    bl nls_find_country
    cbz x0, nls_not_found
    cmp x19, #1
    b.ne nls_table_pointer
    cmp x21, #7                 // room for the 7-byte header at least
    b.lo nls_too_small
    mov x9, x0
    mov w2, #1
    strb w2, [x20]
    mov w2, #38
    strb w2, [x20, #1]
    strb wzr, [x20, #2]
    strb w22, [x20, #3]
    lsr w2, w22, #8
    strb w2, [x20, #4]
    address x2, nls_code_page
    ldr x2, [x2]
    strb w2, [x20, #5]
    lsr w2, w2, #8
    strb w2, [x20, #6]
    // Copy as much of the 34-byte block as the caller's buffer holds.
    sub x2, x21, #7
    cmp x2, #34
    mov x3, #34
    csel x2, x2, x3, lo
    add x0, x9, #4
    add x1, x20, #7
    add x22, x2, #7
    bl copy_bytes
    mov x0, x22
    b nls_done
nls_table_pointer:
    cmp x21, #9
    b.lo nls_too_small
    address x0, nls_upper_table
    cmp x19, #2
    b.eq 3f
    address x0, nls_upper_table  // the file-name table is the same data
    cmp x19, #4
    b.eq 3f
    address x0, nls_file_chars
    cmp x19, #5
    b.eq 3f
    address x0, nls_collate_table
    cmp x19, #6
    b.eq 3f
    address x0, nls_dbcs_table
3:
    strb w19, [x20]
    mov x2, #1
4:
    strb w0, [x20, x2]
    lsr x0, x0, #8
    add x2, x2, #1
    cmp x2, #9
    b.lo 4b
    mov x0, #9
nls_done:
    mov x1, #0
    b nls_return
nls_too_small:
    mov x0, #1
    mov x1, #1
    b nls_return
nls_not_found:
    mov x0, #2
    mov x1, #1
nls_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe
nls_bad_function:
    mov x0, #1
    mov x1, #1
    ret
nls_upper_char:
    frame
    mov x0, x1
    bl nls_upper
    mov x1, #0
    unframe
nls_upper_buffer:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x1
    mov x20, x2
1:
    cbz x20, 2f
    ldrb w0, [x19]
    bl nls_upper
    strb w0, [x19], #1
    sub x20, x20, #1
    b 1b
2:
    mov x0, #0
    mov x1, #0
    ldp x19, x20, [sp], #16
    unframe
nls_upper_string:
    frame
    str x19, [sp, #-16]!
    mov x19, x1
1:
    ldrb w0, [x19]
    cbz w0, 2f
    bl nls_upper
    strb w0, [x19], #1
    b 1b
2:
    mov x0, #0
    mov x1, #0
    ldr x19, [sp], #16
    unframe
// YESNO.ASM: Y/y yes, N/n no.
nls_yes_no:
    mov w9, #0xdf
    and w1, w1, w9
    mov x0, #1
    cmp w1, #'Y'
    b.eq 1f
    mov x0, #0
    cmp w1, #'N'
    b.eq 1f
    mov x0, #2
1:
    mov x1, #0
    ret

// x0 = country, x1 = code page (0: the file's first for that country).
// Loads them from COUNTRY.SYS (nls_file) if one was found at boot. Returns
// x1 = 0, or x1 = 1 with x0 = 2.
nls_reload:
    frame
    address x2, nls_file
    ldrb w3, [x2]
    cbz w3, 1f
    bl nls_load
    cbz x1, 2f
1:
    mov x0, #2
    mov x1, #1
2:
    unframe

// x0 = country, x1 = code page (0: the first listed for the country),
// x2 = path of a DOS 4.0 COUNTRY.SYS (built from MKCNTRY.ASM): makes its
// country information, case maps, file-name characters, collating and DBCS
// tables current. Returns x1 = 0, or x1 = 1 with x0 = 2 (no such file) or
// x0 = 3 (no such country and code page in it).
nls_load:
    enter
    mov x19, x0
    mov x20, x1
    mov x0, x2
    mov x1, #0
    bl dos_open
    cbnz x1, 8f
    mov x21, x0
    address x22, nls_buffer
    mov x23, #0                 // bytes read
1:
    mov x0, x21
    add x1, x22, x23
    mov x2, #NLS_FILE_MAX
    sub x2, x2, x23
    cbz x2, 2f
    bl dos_read
    cbnz x1, 2f
    cbz x0, 2f
    add x23, x23, x0
    b 1b
2:
    mov x0, x21
    bl dos_close
    cmp x23, #23
    b.lo 9f
    ldrb w0, [x22]
    cmp w0, #0xff
    b.ne 9f
    add x0, x22, #19            // the country table
    bl nls_u32
    mov x24, x0
    add x2, x24, #2
    cmp x2, x23
    b.hi 9f
    add x0, x22, x24
    bl nls_u16
    mov x25, x0                 // entries
    add x24, x24, #2
3:
    cbz x25, 9f
    add x2, x24, #14
    cmp x2, x23
    b.hi 9f
    add x0, x22, x24
    add x0, x0, #2
    bl nls_u16
    cmp x0, x19
    b.ne 4f
    cbz x20, 5f
    add x0, x22, x24
    add x0, x0, #4
    bl nls_u16
    cmp x0, x20
    b.eq 5f
4:
    add x24, x24, #14
    sub x25, x25, #1
    b 3b
5:
    add x0, x22, x24
    add x0, x0, #4
    bl nls_u16
    mov x20, x0                 // the code page found
    add x0, x22, x24
    add x0, x0, #10
    bl nls_u32
    mov x24, x0                 // its data: u16 count, 8-byte items
    add x2, x24, #2
    cmp x2, x23
    b.hi 9f
    add x0, x22, x24
    bl nls_u16
    mov x25, x0
    add x24, x24, #2
6:
    cbz x25, 7f
    add x2, x24, #8
    cmp x2, x23
    b.hi 9f
    add x0, x22, x24
    ldrb w26, [x0, #2]          // type
    add x0, x0, #4
    bl nls_u32
    mov x27, x0                 // table: FFh, 7-byte name, u16 length
    add x2, x27, #10
    cmp x2, x23
    b.hi 9f
    add x0, x22, x27
    add x0, x0, #8
    bl nls_u16
    mov x28, x0
    add x27, x27, #10
    add x2, x27, x28
    cmp x2, x23
    b.hi 9f
    add x0, x22, x27            // x0 = the table's data, x28 = its length
    mov x1, x28
    mov x2, x26
    bl nls_apply
    add x24, x24, #8
    sub x25, x25, #1
    b 6b
7:
    address x9, nls_loaded
    strh w19, [x9]
    strh w20, [x9, #2]
    address x9, nls_code_page
    str x20, [x9]
    address x9, dos_country_code
    str x19, [x9]
    mov x1, #0
    leave
8:
    mov x0, #2
    mov x1, #1
    leave
9:
    mov x0, #3
    mov x1, #1
    leave

// x0 = table data, x1 = length, x2 = type (MKCNTRY.INC SETxxx).
nls_apply:
    frame
    cmp x2, #1                  // country information: id, code page, block
    b.ne 1f
    cmp x1, #38
    b.lo 9f
    add x0, x0, #4
    address x1, nls_loaded + 4
    mov x2, #34
    bl copy_bytes
    b 9f
1:
    cmp x2, #2                  // upper case (the file-name map is the same)
    b.ne 2f
    cmp x1, #128
    b.ne 9f
    address x1, nls_upper_data
    mov x2, #128
    bl copy_bytes
    b 9f
2:
    cmp x2, #5                  // file-name characters
    b.ne 3f
    cmp x1, #NLS_TABLE_ROOM
    b.hi 9f
    address x9, nls_file_chars
    strh w1, [x9]
    mov x2, x1
    add x1, x9, #2
    bl copy_bytes
    b 9f
3:
    cmp x2, #6                  // collating sequence
    b.ne 4f
    cmp x1, #256
    b.ne 9f
    address x1, nls_collate_data
    mov x2, #256
    bl copy_bytes
    b 9f
4:
    cmp x2, #7                  // DBCS lead-byte ranges and their 0,0 end
    b.ne 9f
    cmp x1, #NLS_TABLE_ROOM - 2
    b.hi 9f
    address x9, nls_dbcs_table
    strh w1, [x9]
    add x2, x1, #2
    add x1, x9, #2
    bl copy_bytes
9:
    unframe

// x0 = address: little-endian u16 / u32 at any alignment.
nls_u16:
    ldrb w1, [x0]
    ldrb w2, [x0, #1]
    orr w0, w1, w2, lsl #8
    ret
nls_u32:
    ldrb w1, [x0]
    ldrb w2, [x0, #1]
    orr w1, w1, w2, lsl #8
    ldrb w2, [x0, #2]
    orr w1, w1, w2, lsl #16
    ldrb w2, [x0, #3]
    orr w0, w1, w2, lsl #24
    ret

.section .rodata
.balign 4
// Country records adapted from COUNTRY.SYS (MKCNTRY.ASM), code page 437:
// u16 country, u16 code page, then the 34-byte 38h information block.
nls_countries:
    .short 1, 437
    .byte 0,0,36,0,0,0,0,44,0,46,0,45,0,58,0,0,2,0,0,0,0,0,44,0,0,0,0,0,0,0,0,0,0,0
    .byte 0, 0
    .short 44, 437
    .byte 1,0,156,0,0,0,0,44,0,46,0,45,0,58,0,0,2,0,0,0,0,0,44,0,0,0,0,0,0,0,0,0,0,0
    .byte 0, 0
    .short 33, 437
    .byte 1,0,70,0,0,0,0,32,0,44,0,47,0,58,0,3,2,1,0,0,0,0,59,0,0,0,0,0,0,0,0,0,0,0
    .byte 0, 0
    .short 49, 437
    .byte 1,0,68,77,0,0,0,46,0,44,0,46,0,46,0,2,2,1,0,0,0,0,59,0,0,0,0,0,0,0,0,0,0,0
    .byte 0, 0
    .short 34, 437
    .byte 1,0,158,0,0,0,0,46,0,44,0,47,0,58,0,3,2,1,0,0,0,0,59,0,0,0,0,0,0,0,0,0,0,0
    .byte 0, 0
    .short 39, 437
    .byte 1,0,76,46,0,0,0,46,0,44,0,47,0,58,0,0,0,1,0,0,0,0,59,0,0,0,0,0,0,0,0,0,0,0
    .byte 0, 0
    .short 46, 437
    .byte 2,0,83,69,75,0,0,46,0,44,0,45,0,46,0,2,2,1,0,0,0,0,59,0,0,0,0,0,0,0,0,0,0,0
    .byte 0, 0
    .short 41, 437
    .byte 1,0,70,114,0,0,0,39,0,46,0,46,0,46,0,2,2,1,0,0,0,0,44,0,0,0,0,0,0,0,0,0,0,0
    .byte 0, 0
    .short 31, 437
    .byte 1,0,159,0,0,0,0,46,0,44,0,45,0,58,0,2,2,1,0,0,0,0,59,0,0,0,0,0,0,0,0,0,0,0
    .byte 0, 0
    .short 32, 437
    .byte 1,0,66,69,70,0,0,46,0,44,0,47,0,58,0,2,2,1,0,0,0,0,59,0,0,0,0,0,0,0,0,0,0,0
    .byte 0, 0
    .short 358, 437
    .byte 1,0,109,107,0,0,0,32,0,44,0,46,0,46,0,3,2,1,0,0,0,0,59,0,0,0,0,0,0,0,0,0,0,0
    .byte 0, 0
    .short 3, 437
    .byte 1,0,36,0,0,0,0,44,0,46,0,47,0,58,0,3,2,1,0,0,0,0,59,0,0,0,0,0,0,0,0,0,0,0
    .byte 0, 0
    .short 61, 437
    .byte 1,0,36,0,0,0,0,44,0,46,0,45,0,58,0,0,2,0,0,0,0,0,44,0,0,0,0,0,0,0,0,0,0,0
    .byte 0, 0
    .short 0, 0
.section .data
.balign 4
// The country loaded from COUNTRY.SYS (country 0: none), as above.
nls_loaded: .skip 40
nls_code_page: .quad 437
nls_system_code_page: .quad 437
.balign 2
// UCASE_TAB / FILE_UCASE_TAB: u16 length, then characters 80h-FFh.
nls_upper_table:
    .short 128
nls_upper_data:
    .byte 128,154,69,65,142,65,143,128,69,69,69,73,73,73,142,143
    .byte 144,146,146,79,153,79,85,85,89,153,154,155,156,157,158,159
    .byte 65,73,79,85,165,165,166,167,168,169,170,171,172,173,174,175
    .byte 176,177,178,179,180,181,182,183,184,185,186,187,188,189,190,191
    .byte 192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207
    .byte 208,209,210,211,212,213,214,215,216,217,218,219,220,221,222,223
    .byte 224,225,226,227,228,229,230,231,232,233,234,235,236,237,238,239
    .byte 240,241,242,243,244,245,246,247,248,249,250,251,252,253,254,255
.balign 2
// FILE_CHAR_TAB: characters that may not appear in file names.
nls_file_chars:
    .short 22
    .byte 1, 0, 255
    .byte 0, 0, 0x20
    .byte 2, 14
    .ascii ".\"/\\[]:|<>+=;,"
    .skip NLS_TABLE_ROOM - 22
.balign 2
// COLLATE_TAB: sort weights for all 256 characters.
nls_collate_table:
    .short 256
nls_collate_data:
    .byte 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    .byte 16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    .byte 32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47
    .byte 48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63
    .byte 64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79
    .byte 80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95
    .byte 96,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79
    .byte 80,81,82,83,84,85,86,87,88,89,90,123,124,125,126,127
    .byte 67,85,69,65,65,65,65,67,69,69,69,73,73,73,65,65
    .byte 69,65,65,79,79,79,85,85,89,79,85,36,36,36,36,36
    .byte 65,73,79,85,78,78,166,167,63,169,170,171,172,33,34,34
    .byte 176,177,178,179,180,181,182,183,184,185,186,187,188,189,190,191
    .byte 192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207
    .byte 208,209,210,211,212,213,214,215,216,217,218,219,220,221,222,223
    .byte 224,83,226,227,228,229,230,231,232,233,234,235,236,237,238,239
    .byte 240,241,242,243,244,245,246,247,248,249,250,251,252,253,254,255
.balign 2
// DBCS_TAB: no lead-byte ranges in code page 437.
nls_dbcs_table:
    .short 0
    .skip NLS_TABLE_ROOM

.section .bss
.balign 8
dos_country_code: .skip 8
nls_file: .skip 128             // COUNTRY.SYS found at boot ("" if none)
.balign 16
nls_buffer: .skip NLS_FILE_MAX
