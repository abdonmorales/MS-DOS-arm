// SPDX-License-Identifier: MIT
// ARM BASIC [file]: a BASIC interpreter for ARM DOS, in the style of the
// Microsoft BASICs that came with MS-DOS, written natively in AArch64.
// Numbers are 64-bit integers (/ and \ both divide to an integer); strings
// hold up to 255 bytes. Program lines are kept as typed (keywords and names
// upper-cased) and interpreted directly.
//
// Statements: PRINT (?), LET, INPUT, IF..THEN..ELSE, GOTO, GOSUB, RETURN,
// ON..GOTO/GOSUB, FOR..TO..STEP, NEXT, WHILE, WEND, END, STOP, REM ('),
// DIM, DATA, READ, RESTORE, RANDOMIZE, CLS, CLEAR, and the commands RUN,
// LIST, NEW, LOAD, SAVE and SYSTEM. Functions: ABS SGN INT SQR RND LEN ASC
// VAL CHR$ STR$ LEFT$ RIGHT$ MID$ INSTR SPACE$; PRINT also takes TAB( and
// SPC(. Operators: ^ * / \ MOD + - = <> < > <= >= NOT AND OR.
//
// Register use: x28 is the text pointer everywhere. Routines save what
// they use of x19-x26 (benter/bleave), never x28; an error resets sp.
.include "lib.inc"

.equ PROG_SIZE, 65536
.equ VAR_MAX, 512
.equ VAR_SIZE, 48               // name[16], kind, value/data, upper bound
.equ HEAP_SIZE, 1048576
.equ TEMP_SIZE, 32768
.equ CTL_MAX, 64
.equ CTL_SIZE, 48               // type, var, limit, step, line, position
.equ SLOT, 256                  // a string: length byte + 255 bytes
.equ K_NUM, 0
.equ K_STR, 1
.equ K_NUMARR, 2
.equ K_STRARR, 3
.equ C_GOSUB, 1
.equ C_FOR, 2
.equ C_WHILE, 3

.equ E_SYNTAX, 0
.equ E_RETURN, 1
.equ E_DATA, 2
.equ E_ILLEGAL, 3
.equ E_MEMORY, 4
.equ E_LINE, 5
.equ E_SUBSCRIPT, 6
.equ E_REDIM, 7
.equ E_DIV0, 8
.equ E_TYPE, 9
.equ E_STRSPACE, 10
.equ E_STRLONG, 11
.equ E_NEXT, 12
.equ E_WEND, 13
.equ E_WHILE, 14
.equ E_FOR, 15
.equ E_FILE, 16
.equ E_DIRECTFILE, 17
.equ E_FILEIO, 18
.equ E_BREAK, 19

.macro benter
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
.endm
.macro bleave
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x23, x24, [sp, #48]
    ldp x25, x26, [sp, #64]
    ldp x29, x30, [sp], #80
    ret
.endm
.macro gld reg, sym
    adrp \reg, \sym
    ldr \reg, [\reg, :lo12:\sym]
.endm
.macro gst reg, sym
    adrp x16, \sym
    str \reg, [x16, :lo12:\sym]
.endm
.macro err code
    mov x0, #\code
    b basic_error
.endm

// ---------------------------------------------------------------------------
main:
    enter
    mov x19, x0
    mov x0, sp
    gst x0, err_sp
    // BREAK ON while BASIC runs, and Ctrl-C only sets a flag (vector 23h):
    // the kernel then notices it on any call without eating typed keys.
    mov x0, #0
    dos 0x33
    gst x2, break_saved
    mov x0, #1
    mov x1, #1
    dos 0x33
    mov x0, #0x23
    address x1, break_handler
    dos 0x25
    say "ARM BASIC 1.0 for ARM DOS (native AArch64)\r\n"
    say "64-bit integers and strings. SYSTEM returns to DOS.\r\n"
    bl clear_program
    mov x0, x19
    bl next_arg
    ldrb w2, [x0]
    cbz w2, ready
    // BASIC file: run it as if RUN "file" were typed.
    mov x1, x0
    address x0, linebuf
    mov w2, #'R'
    strb w2, [x0], #1
    mov w2, #'U'
    strb w2, [x0], #1
    mov w2, #'N'
    strb w2, [x0], #1
    mov w2, #' '
    strb w2, [x0], #1
    mov w2, #'"'
    strb w2, [x0], #1
    mov x3, #0
1:
    ldrb w2, [x1, x3]
    cbz w2, 2f
    cmp x3, #70
    b.hs 2f
    strb w2, [x0], #1
    add x3, x3, #1
    b 1b
2:
    mov w2, #'"'
    strb w2, [x0], #1
    strb wzr, [x0]
    address x28, linebuf
    b exec_line

ready:
    gld x0, col                 // Ok starts a line
    cbz x0, 1f
    bl crlf
1:
    say "Ok\r\n"
    gst xzr, col
prompt_loop:
    gld x0, err_sp
    mov sp, x0
    gst xzr, cur_line
    address x0, inbuf
    mov w1, #255
    strb w1, [x0]
    bl read_console_line
    gst xzr, col
    address x1, linebuf
    bl crunch
    address x28, linebuf
    bl skip_sp
    cbz w0, prompt_loop
    sub w1, w0, #'0'
    cmp w1, #9
    b.hi exec_line
    bl parse_uint
    mov x1, x28
    bl edit_line
    b prompt_loop
exec_line:
    gst xzr, break_flag
    gst xzr, cur_line
    bl run_statements
    b ready

// Ctrl-C (vector 23h): note it; x0 = 0 lets the program continue.
break_handler:
    adrp x9, break_flag
    mov x10, #1
    str x10, [x9, :lo12:break_flag]
    mov x0, #0
    ret

// The interpreter: statements from x28 until the direct line ends, or the
// program ends or stops.
run_statements:
    benter
1:
    address x0, temp_area
    gst x0, temp_ptr
    gld x0, poll_count          // every 64 statements a call, so BREAK ON
    add x0, x0, #1              // sees Ctrl-C even in a one-line loop
    gst x0, poll_count
    tst x0, #63
    b.ne 11f
    dos 0x0b
11:
    gld x0, break_flag
    cbnz x0, 8f
    bl exec_statement
    gld x0, jumped
    cbz x0, 2f
    gst xzr, jumped
    b 1b
2:
    bl skip_sp
    cmp w0, #':'
    b.ne 21f
    add x28, x28, #1
    b 1b
21:
    address x0, kw_else         // after a THEN branch: skip the ELSE part
    bl match_kw
    cbz x0, 3f
    bl stmt_else
    ldrb w0, [x28]
3:
    cbnz w0, syntax_error
    gld x1, cur_line
    cbz x1, 9f
    ldr w2, [x1, #4]
    add x1, x1, x2
    gld x3, prog_end
    cmp x1, x3
    b.hs 7f
    gst x1, cur_line
    add x28, x1, #8
    b 1b
7:
    gst xzr, cur_line
9:
    bleave
8:
    gst xzr, break_flag
    err E_BREAK

// x0 = error code: report it ("Syntax error in 20") and return to Ok.
basic_error:
    mov x19, x0
    gld x0, err_sp
    mov sp, x0
    gld x0, load_handle
    cbz x0, 1f
    gst xzr, load_handle
    bl fclose
1:
    gld x0, col
    cbz x0, 2f
    bl out_crlf
2:
    address x0, err_table
    ldrsw x1, [x0, x19, lsl #2]
    add x0, x0, x1
    bl puts
    gld x19, cur_line
    cbz x19, 3f
    say " in "
    ldr w0, [x19]
    mov x1, #0
    bl put_dec
3:
    bl crlf
    gst xzr, col
    gst xzr, ctl_sp
    gst xzr, cur_line
    b ready

syntax_error:
    err E_SYNTAX
type_mismatch:
    err E_TYPE
illegal_call:
    err E_ILLEGAL
out_of_memory:
    err E_MEMORY
undefined_line:
    err E_LINE
subscript_error:
    err E_SUBSCRIPT
div_zero:
    err E_DIV0
string_space:
    err E_STRSPACE
string_too_long:
    err E_STRLONG

// ---------------------------------------------------------------------------
// Program storage: records [u32 line][u32 record size][text NUL], sorted.

clear_program:
    address x0, prog_area
    gst x0, prog_end
    b clear_vars

clear_vars:
    gst xzr, var_count
    address x0, heap_area
    gst x0, heap_ptr
    gst xzr, ctl_sp
    gst xzr, data_rec
    gst xzr, data_pos
    ret

// x0 = line number, x1 = its text: replaces, inserts or (empty) deletes.
edit_line:
    benter
    mov x19, x0
    mov x20, x1
    cbz x19, syntax_error
    mov x9, #65529
    cmp x19, x9
    b.hi syntax_error
    gst xzr, ctl_sp             // records move: loops and DATA restart
    gst xzr, data_rec
    gst xzr, data_pos
1:
    ldrb w0, [x20]              // the text starts after the blanks
    cmp w0, #' '
    b.ne 2f
    add x20, x20, #1
    b 1b
2:
    address x21, prog_area
    gld x22, prog_end
3:
    cmp x21, x22                // the first record at or after the number
    b.hs 5f
    ldr w9, [x21]
    cmp x9, x19
    b.hs 4f
    ldr w9, [x21, #4]
    add x21, x21, x9
    b 3b
4:
    b.ne 5f
    ldr w23, [x21, #4]          // same number: delete the old line
    add x1, x21, x23
    mov x0, x21
    sub x2, x22, x1
    bl copy_bytes
    sub x22, x22, x23
    gst x22, prog_end
5:
    mov x0, x20
    bl strlen
    cbz x0, 9f
    mov x24, x0
    add x23, x24, #12           // header, text, NUL, rounded to 4
    bic x23, x23, #3
    address x9, prog_area + PROG_SIZE
    add x10, x22, x23
    cmp x10, x9
    b.hi out_of_memory
    // Open a gap at x21 (copy backwards).
    sub x9, x22, x21
6:
    cbz x9, 7f
    sub x9, x9, #1
    ldrb w10, [x21, x9]
    add x11, x21, x23
    strb w10, [x11, x9]
    b 6b
7:
    str w19, [x21]
    str w23, [x21, #4]
    mov x0, x20
    add x1, x21, #8
    bl strcpy
    add x22, x22, x23
    gst x22, prog_end
9:
    bleave

// x0 = line number. Returns x0 = its record, or 0. Leaf.
find_line:
    address x9, prog_area
    gld x10, prog_end
1:
    cmp x9, x10
    b.hs 3f
    ldr w11, [x9]
    cmp x11, x0
    b.eq 2f
    b.hi 3f
    ldr w11, [x9, #4]
    add x9, x9, x11
    b 1b
2:
    mov x0, x9
    ret
3:
    mov x0, #0
    ret

// x0 = typed text, x1 = destination: upper-cases outside strings and
// comments, turns tabs into blanks, keeps at most 255 bytes. Leaf.
crunch:
    mov x9, #0                  // in a string
    mov x12, #0                 // count
1:
    ldrb w10, [x0], #1
    cbz w10, 9f
    cmp x12, #255
    b.hs 9f
    cmp w10, #9
    b.ne 2f
    mov w10, #' '
2:
    cmp w10, #'"'
    b.ne 3f
    eor x9, x9, #1
    b 5f
3:
    cbnz x9, 5f
    cmp w10, #'\''
    b.eq 7f
    sub w11, w10, #'a'
    cmp w11, #25
    b.hi 4f
    sub w10, w10, #32
4:
    cmp w10, #'M'               // ...REM: the rest stays as typed
    b.ne 5f
    cmp x12, #2
    b.lo 5f
    ldurb w11, [x1, #-2]
    cmp w11, #'R'
    b.ne 5f
    ldurb w11, [x1, #-1]
    cmp w11, #'E'
    b.ne 5f
    strb w10, [x1], #1
    add x12, x12, #1
    b 7f
5:
    strb w10, [x1], #1
    add x12, x12, #1
    b 1b
6:
    strb w10, [x1], #1
    add x12, x12, #1
7:
    cmp w10, #'\''
    b.ne 8f
    cmp x12, #255
    b.hs 9f
    strb w10, [x1], #1
    add x12, x12, #1
8:
    ldrb w10, [x0], #1          // copy the comment unchanged
    cbz w10, 9f
    cmp x12, #255
    b.hs 9f
    cmp w10, #9
    b.ne 6b
    mov w10, #' '
    b 6b
9:
    strb wzr, [x1]
    ret

// ---------------------------------------------------------------------------
// Scanning helpers. x28 is the text pointer.

// Returns w0 = the next non-blank character (x28 points to it). Leaf.
skip_sp:
1:
    ldrb w0, [x28]
    cmp w0, #' '
    b.ne 2f
    add x28, x28, #1
    b 1b
2:
    ret

// x0 = keyword. Returns x0 = its length if the text at x28 starts with it,
// else 0. x28 is unchanged. Leaf (x9-x11).
match_kw:
    mov x9, #0
1:
    ldrb w10, [x0, x9]
    cbz w10, 2f
    ldrb w11, [x28, x9]
    cmp w10, w11
    b.ne 3f
    add x9, x9, #1
    b 1b
2:
    mov x0, x9
    ret
3:
    mov x0, #0
    ret

// x0 = keyword: skips blanks and the keyword if present; x0 = its length.
accept_kw:
    frame
    str x0, [sp, #-16]!
    bl skip_sp
    ldr x0, [sp], #16
    bl match_kw
    add x28, x28, x0
    unframe

// w9 = character that must come next. Preserves x0-x8. Leaf (x9-x11).
expect_char:
1:
    ldrb w11, [x28]
    cmp w11, #' '
    b.ne 2f
    add x28, x28, #1
    b 1b
2:
    cmp w11, w9
    b.ne syntax_error
    add x28, x28, #1
    ret
arg_open:
    mov w9, #'('
    b expect_char
arg_close:
    mov w9, #')'
    b expect_char
arg_comma:
    mov w9, #','
    b expect_char

// Decimal digits at x28: x0 = their value. Leaf.
parse_uint:
    mov x0, #0
    mov x10, #10
1:
    ldrb w9, [x28]
    sub w9, w9, #'0'
    cmp w9, #9
    b.hi 2f
    madd x0, x0, x10, x9
    add x28, x28, #1
    b 1b
2:
    ret

// A line number (required): x0.
parse_linenum:
    frame
    bl skip_sp
    sub w1, w0, #'0'
    cmp w1, #9
    b.hi syntax_error
    bl parse_uint
    unframe

// x0 = text, x1 = length: a number as VAL reads it (blanks, sign, digits,
// a fraction that is dropped). Returns x0 = value, x1 = bytes used,
// x2 = digits seen. Leaf.
parse_val:
    mov x9, #0
    mov x10, #0
    mov x11, #0
    mov x12, #0
    mov x14, #10
1:
    cmp x9, x1
    b.hs 5f
    ldrb w13, [x0, x9]
    cmp w13, #' '
    b.ne 2f
    add x9, x9, #1
    b 1b
2:
    cmp w13, #'-'
    b.ne 3f
    mov x11, #1
    add x9, x9, #1
    b 4f
3:
    cmp w13, #'+'
    b.ne 4f
    add x9, x9, #1
4:
    cmp x9, x1
    b.hs 5f
    ldrb w13, [x0, x9]
    sub w13, w13, #'0'
    cmp w13, #9
    b.hi 6f
    madd x10, x10, x14, x13
    add x12, x12, #1
    add x9, x9, #1
    b 4b
6:
    ldrb w13, [x0, x9]
    cmp w13, #'.'
    b.ne 5f
    add x9, x9, #1
7:
    cmp x9, x1
    b.hs 5f
    ldrb w13, [x0, x9]
    sub w13, w13, #'0'
    cmp w13, #9
    b.hi 5f
    add x9, x9, #1
    b 7b
5:
    cmp x11, #0
    cneg x0, x10, ne
    mov x1, x9
    mov x2, x12
    ret

// x0 = text: bytes up to a comma or the end. Leaf.
field_len:
    mov x9, #0
1:
    ldrb w10, [x0, x9]
    cbz w10, 2f
    cmp w10, #','
    b.eq 2f
    add x9, x9, #1
    b 1b
2:
    mov x0, x9
    ret

// x0 = destination, x1 = source, x2 = bytes (forward). Leaf.
copy_bytes:
    cbz x2, 2f
1:
    ldrb w9, [x1], #1
    strb w9, [x0], #1
    subs x2, x2, #1
    b.ne 1b
2:
    ret

// ---------------------------------------------------------------------------
// Output, tracking the column for "," and TAB.

// x0 = bytes, x1 = count.
out_bytes:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    cbz x20, 9f
    bl write_out
    gld x2, col
    mov x3, #0
1:
    ldrb w4, [x19, x3]
    cmp w4, #13
    b.eq 2f
    cmp w4, #10
    b.eq 2f
    add x2, x2, #1
    b 3f
2:
    mov x2, #0
3:
    add x3, x3, #1
    cmp x3, x20
    b.lo 1b
    gst x2, col
9:
    ldp x19, x20, [sp], #16
    unframe

out_cstr:
    frame
    str x0, [sp, #-16]!
    bl strlen
    mov x1, x0
    ldr x0, [sp], #16
    bl out_bytes
    unframe

out_char:
    frame
    sub sp, sp, #16
    strb w0, [sp]
    mov x0, sp
    mov x1, #1
    bl out_bytes
    add sp, sp, #16
    unframe

out_crlf:
    frame
    address x0, crlf_text
    mov x1, #2
    bl out_bytes
    unframe

// x0 = count (none if not positive).
out_spaces:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
1:
    cmp x19, #0
    b.le 2f
    mov x0, #' '
    bl out_char
    sub x19, x19, #1
    b 1b
2:
    ldr x19, [sp], #16
    unframe

// x0 = number: x0 = text (blank or '-' then digits), x2 = its length.
fmt_num:
    frame
    str x19, [sp, #-16]!
    mov w19, #' '
    tbz x0, #63, 1f
    neg x0, x0
    mov w19, #'-'
1:
    address x1, numbuf
    bl utoa
    sub x0, x0, #1
    strb w19, [x0]
    address x2, numbuf + 23
    sub x2, x2, x0
    ldr x19, [sp], #16
    unframe

// ---------------------------------------------------------------------------
// Variables: name[16] (NUL padded, '$' kept), kind, value (a number, a
// string slot, or array data), upper bound.

// A name at x28 into namebuf (up to 14 characters plus '$'). Returns
// x0 = 1 for a string name. Leaf.
read_name:
    address x9, namebuf
    stp xzr, xzr, [x9]
    mov x10, #0
1:
    ldrb w11, [x28]
    sub w12, w11, #'A'
    cmp w12, #25
    b.ls 2f
    sub w12, w11, #'0'
    cmp w12, #9
    b.ls 2f
    cmp w11, #'.'
    b.ne 3f
2:
    cmp x10, #14
    b.hs 21f
    strb w11, [x9, x10]
    add x10, x10, #1
21:
    add x28, x28, #1
    b 1b
3:
    mov x0, #0
    cmp w11, #'$'
    b.ne 4f
    strb w11, [x9, x10]
    add x28, x28, #1
    mov x0, #1
4:
    ret

// x0 = kind: the variable named in namebuf, or 0. Leaf.
find_var:
    address x9, namebuf
    ldp x10, x11, [x9]
    address x12, vars
    gld x13, var_count
1:
    cbz x13, 3f
    ldp x14, x15, [x12]
    cmp x14, x10
    b.ne 2f
    cmp x15, x11
    b.ne 2f
    ldr x14, [x12, #16]
    cmp x14, x0
    b.eq 4f
2:
    add x12, x12, #VAR_SIZE
    sub x13, x13, #1
    b 1b
3:
    mov x0, #0
    ret
4:
    mov x0, x12
    ret

// x0 = kind: a new variable named in namebuf (a string gets its slot).
new_var:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    gld x9, var_count
    cmp x9, #VAR_MAX
    b.hs out_of_memory
    address x10, vars
    mov x11, #VAR_SIZE
    madd x20, x9, x11, x10
    add x9, x9, #1
    gst x9, var_count
    address x9, namebuf
    ldp x10, x11, [x9]
    stp x10, x11, [x20]
    str x19, [x20, #16]
    str xzr, [x20, #24]
    str xzr, [x20, #32]
    cmp x19, #K_STR
    b.ne 1f
    mov x0, #SLOT
    bl heap_alloc
    str x0, [x20, #24]
1:
    mov x0, x20
    ldp x19, x20, [sp], #16
    unframe

// x0 = bytes: zeroed memory from the variable heap. Leaf.
heap_alloc:
    add x0, x0, #7
    bic x0, x0, #7
    gld x9, heap_ptr
    add x10, x9, x0
    address x11, heap_area + HEAP_SIZE
    cmp x10, x11
    b.hi out_of_memory
    gst x10, heap_ptr
    mov x11, x9
1:
    cmp x11, x10
    b.hs 2f
    str xzr, [x11], #8
    b 1b
2:
    mov x0, x9
    ret

// x0 = bytes: room for an intermediate string (reset every statement).
temp_alloc:
    gld x9, temp_ptr
    add x10, x9, x0
    address x11, temp_area + TEMP_SIZE
    cmp x10, x11
    b.hi string_space
    gst x10, temp_ptr
    mov x0, x9
    ret

// x0 = 1 for strings, x1 = upper bound: a new array named in namebuf.
make_array:
    benter
    mov x19, x0
    mov x20, x1
    add x0, x19, #K_NUMARR
    bl new_var
    mov x21, x0
    str x20, [x21, #32]
    add x0, x20, #1
    lsl x0, x0, #3
    cbz x19, 1f
    lsl x0, x0, #5              // 256 bytes an element
1:
    bl heap_alloc
    str x0, [x21, #24]
    mov x0, x21
    bleave

// After read_name (x0 = 1 for a string): the variable or array element.
// Returns x0 = the value cell (a number) or the string slot, x1 = 1 for a
// string. A missing variable is created; a missing array gets DIM 10.
var_ref_named:
    benter
    mov x19, x0
    bl skip_sp
    cmp w0, #'('
    b.eq 5f
    mov x0, x19
    bl find_var
    cbnz x0, 1f
    mov x0, x19
    bl new_var
1:
    add x0, x0, #24
    cbz x19, 2f
    ldr x0, [x0]
2:
    mov x1, x19
    bleave
5:
    add x28, x28, #1
    address x9, namebuf         // the index may use other names
    ldp x20, x21, [x9]
    bl eval_num
    mov x22, x0
    bl arg_close
    address x9, namebuf
    stp x20, x21, [x9]
    add x0, x19, #K_NUMARR
    bl find_var
    cbnz x0, 6f
    mov x0, x19
    mov x1, #10
    bl make_array
6:
    ldr x9, [x0, #32]
    cmp x22, x9
    b.hi subscript_error        // unsigned: negative indexes too
    ldr x10, [x0, #24]
    cbz x19, 7f
    add x0, x10, x22, lsl #8
    b 8f
7:
    add x0, x10, x22, lsl #3
8:
    mov x1, x19
    bleave

// A variable reference at x28 (for LET, INPUT, READ, FOR, NEXT).
get_var_ref:
    frame
    bl skip_sp
    sub w1, w0, #'A'
    cmp w1, #25
    b.hi syntax_error
    bl read_name
    bl var_ref_named
    unframe

// x0 = slot, x1 = text, x2 = length: stores a string (the source may be a
// later part of the same slot). Leaf.
assign_str:
    cmp x2, #255
    b.hi string_too_long
    strb w2, [x0]
    add x0, x0, #1
    mov x9, #0
1:
    cmp x9, x2
    b.hs 2f
    ldrb w10, [x1, x9]
    strb w10, [x0, x9]
    add x9, x9, #1
    b 1b
2:
    ret

// ---------------------------------------------------------------------------
// Expressions. Each returns x0 = number (x1 = 0) or x0 = text, x2 = length
// (x1 = 1).

eval_expr:
    b eval_or

eval_num:
    frame
    bl eval_expr
    cbnz x1, type_mismatch
    unframe

eval_str:
    frame
    bl eval_expr
    cbz x1, type_mismatch
    unframe

eval_or:
    benter
    bl eval_and
    mov x19, x0
    mov x20, x1
    mov x21, x2
1:
    address x0, kw_or
    bl accept_kw
    cbz x0, 9f
    cbnz x20, type_mismatch
    bl eval_and
    cbnz x1, type_mismatch
    orr x19, x19, x0
    b 1b
9:
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bleave

eval_and:
    benter
    bl eval_not
    mov x19, x0
    mov x20, x1
    mov x21, x2
1:
    address x0, kw_and
    bl accept_kw
    cbz x0, 9f
    cbnz x20, type_mismatch
    bl eval_not
    cbnz x1, type_mismatch
    and x19, x19, x0
    b 1b
9:
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bleave

eval_not:
    frame
    address x0, kw_not
    bl accept_kw
    cbz x0, 1f
    bl eval_not
    cbnz x1, type_mismatch
    mvn x0, x0
    unframe
1:
    bl eval_rel
    unframe

// Comparisons give -1 (true) or 0.
eval_rel:
    benter
    bl eval_add
    mov x19, x0
    mov x20, x1
    mov x21, x2
1:
    bl skip_sp
    mov x22, #0                 // 1 <, 2 =, 4 >
2:
    ldrb w0, [x28]
    cmp w0, #'<'
    b.ne 3f
    orr x22, x22, #1
    add x28, x28, #1
    b 2b
3:
    cmp w0, #'='
    b.ne 4f
    orr x22, x22, #2
    add x28, x28, #1
    b 2b
4:
    cmp w0, #'>'
    b.ne 5f
    orr x22, x22, #4
    add x28, x28, #1
    b 2b
5:
    cbz x22, 9f
    bl eval_add
    cmp x1, x20
    b.ne type_mismatch
    cbnz x20, 6f
    mov x9, #1
    mov x10, #2
    mov x11, #4
    cmp x19, x0
    csel x9, x9, x10, lt
    csel x9, x11, x9, gt
    b 7f
6:
    mov x3, x2
    mov x2, x0
    mov x0, x19
    mov x1, x21
    bl str_compare
    mov x9, x0
7:
    tst x9, x22
    csetm x19, ne
    mov x20, #0
    b 1b
9:
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bleave

// x0, x1 = a and length, x2, x3 = b and length: x0 = 1 a<b, 2 equal,
// 4 a>b. Leaf.
str_compare:
    mov x9, #0
1:
    cmp x9, x1
    b.hs 3f
    cmp x9, x3
    b.hs 5f
    ldrb w10, [x0, x9]
    ldrb w11, [x2, x9]
    cmp w10, w11
    b.lo 4f
    b.hi 5f
    add x9, x9, #1
    b 1b
3:
    cmp x9, x3
    b.lo 4f
    mov x0, #2
    ret
4:
    mov x0, #1
    ret
5:
    mov x0, #4
    ret

eval_add:
    benter
    bl eval_mul
    mov x19, x0
    mov x20, x1
    mov x21, x2
1:
    bl skip_sp
    cmp w0, #'+'
    b.eq 2f
    cmp w0, #'-'
    b.ne 9f
2:
    mov w22, w0
    add x28, x28, #1
    bl eval_mul
    cmp x1, x20
    b.ne type_mismatch
    cbnz x20, 4f
    cmp w22, #'+'
    b.ne 3f
    add x19, x19, x0
    b 1b
3:
    sub x19, x19, x0
    b 1b
4:
    cmp w22, #'+'               // strings: + joins them
    b.ne type_mismatch
    mov x23, x0
    mov x24, x2
    add x25, x21, x24
    cmp x25, #255
    b.hi string_too_long
    mov x0, x25
    bl temp_alloc
    mov x26, x0
    mov x1, x19
    mov x2, x21
    bl copy_bytes
    add x0, x26, x21
    mov x1, x23
    mov x2, x24
    bl copy_bytes
    mov x19, x26
    mov x21, x25
    b 1b
9:
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bleave

eval_mul:
    benter
    bl eval_neg
    mov x19, x0
    mov x20, x1
    mov x21, x2
1:
    bl skip_sp
    mov w22, w0
    cmp w0, #'*'
    b.eq 2f
    cmp w0, #'/'
    b.eq 2f
    cmp w0, #'\\'
    b.eq 2f
    address x0, kw_mod
    bl match_kw
    cbz x0, 9f
    add x28, x28, x0
    mov w22, #'M'
    b 3f
2:
    add x28, x28, #1
3:
    cbnz x20, type_mismatch
    bl eval_neg
    cbnz x1, type_mismatch
    cmp w22, #'*'
    b.ne 4f
    mul x19, x19, x0
    b 1b
4:
    cbz x0, div_zero
    sdiv x9, x19, x0
    cmp w22, #'M'
    b.ne 5f
    msub x19, x9, x0, x19
    b 1b
5:
    mov x19, x9
    b 1b
9:
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bleave

eval_neg:
    frame
    bl skip_sp
    cmp w0, #'-'
    b.ne 1f
    add x28, x28, #1
    bl eval_neg
    cbnz x1, type_mismatch
    neg x0, x0
    unframe
1:
    cmp w0, #'+'
    b.ne 2f
    add x28, x28, #1
    bl eval_neg
    cbnz x1, type_mismatch
    unframe
2:
    bl eval_pow
    unframe

eval_pow:
    benter
    bl eval_atom
    mov x19, x0
    mov x20, x1
    mov x21, x2
1:
    bl skip_sp
    cmp w0, #'^'
    b.ne 9f
    add x28, x28, #1
    cbnz x20, type_mismatch
    bl eval_neg
    cbnz x1, type_mismatch
    tbnz x0, #63, 5f
    mov x9, #1                  // by squaring
2:
    cbz x0, 3f
    tbz x0, #0, 21f
    mul x9, x9, x19
21:
    mul x19, x19, x19
    lsr x0, x0, #1
    b 2b
3:
    mov x19, x9
    b 1b
5:
    cbz x19, div_zero           // a negative power: an integer result
    cmp x19, #1
    b.eq 1b
    cmn x19, #1
    b.ne 6f
    tbnz x0, #0, 1b
    mov x19, #1
    b 1b
6:
    mov x19, #0
    b 1b
9:
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bleave

eval_atom:
    benter
    bl skip_sp
    sub w1, w0, #'0'
    cmp w1, #9
    b.ls 10f
    cmp w0, #'"'
    b.eq 20f
    cmp w0, #'('
    b.eq 30f
    cmp w0, #'&'
    b.eq 40f
    sub w1, w0, #'A'
    cmp w1, #25
    b.ls 50f
    b syntax_error
10:                             // a number (a fraction is dropped)
    bl parse_uint
    mov x19, x0
    ldrb w0, [x28]
    cmp w0, #'.'
    b.ne 11f
    add x28, x28, #1
    bl parse_uint
11:
    mov x0, x19
    mov x1, #0
    bleave
20:                             // "text"
    add x28, x28, #1
    mov x19, x28
21:
    ldrb w0, [x28]
    cbz w0, 22f
    cmp w0, #'"'
    b.eq 22f
    add x28, x28, #1
    b 21b
22:
    sub x2, x28, x19
    cbz w0, 23f
    add x28, x28, #1
23:
    mov x0, x19
    mov x1, #1
    bleave
30:                             // ( expression )
    add x28, x28, #1
    bl eval_expr
    bl arg_close
    bleave
40:                             // &H hexadecimal
    ldrb w0, [x28, #1]
    cmp w0, #'H'
    b.ne syntax_error
    add x28, x28, #2
    mov x19, #0
41:
    ldrb w0, [x28]
    sub w1, w0, #'0'
    cmp w1, #9
    b.ls 42f
    sub w1, w0, #'A'
    cmp w1, #5
    b.hi 43f
    add w1, w1, #10
42:
    lsl x19, x19, #4
    orr x19, x19, x1
    add x28, x28, #1
    b 41b
43:
    mov x0, x19
    mov x1, #0
    bleave
50:                             // a function or a variable
    bl read_name
    mov x19, x0
    bl find_function
    cbz x0, 51f
    blr x0
    bleave
51:
    mov x0, x19
    bl var_ref_named
    cbnz x1, 52f
    ldr x0, [x0]
    bleave
52:
    ldrb w2, [x0]
    add x0, x0, #1
    bleave

// The function named in namebuf: x0 = its handler, or 0. Leaf.
find_function:
    address x12, func_table
    mov x9, x12
    address x10, namebuf
1:
    ldrsw x11, [x9]
    cbz x11, 8f
    add x11, x11, x12
    mov x13, #0
2:
    ldrb w14, [x11, x13]
    ldrb w15, [x10, x13]
    cmp w14, w15
    b.ne 3f
    cbz w14, 4f
    add x13, x13, #1
    b 2b
3:
    add x9, x9, #8
    b 1b
4:
    ldrsw x11, [x9, #4]
    add x0, x11, x12
    ret
8:
    mov x0, #0
    ret

// ---------------------------------------------------------------------------
// Functions: called with x28 at the '(' after the name.

fn_abs:
    frame
    bl arg_open
    bl eval_num
    bl arg_close
    cmp x0, #0
    cneg x0, x0, lt
    mov x1, #0
    unframe

fn_sgn:
    frame
    bl arg_open
    bl eval_num
    bl arg_close
    cmp x0, #0
    cset x9, gt
    csetm x10, lt
    orr x0, x9, x10
    mov x1, #0
    unframe

fn_int:
    frame
    bl arg_open
    bl eval_num
    bl arg_close
    mov x1, #0
    unframe

fn_sqr:                         // the integer square root
    frame
    bl arg_open
    bl eval_num
    bl arg_close
    cmp x0, #0
    b.lt illegal_call
    cbz x0, 2f
    mov x9, x0
    mov x10, x0
    add x11, x9, #1
    lsr x11, x11, #1
1:
    cmp x11, x10
    b.hs 2f
    mov x10, x11
    udiv x12, x9, x10
    add x11, x10, x12
    lsr x11, x11, #1
    b 1b
2:
    cbz x0, 3f
    mov x0, x10
3:
    mov x1, #0
    unframe

fn_rnd:                         // RND(n): a random integer 1..n
    frame
    bl arg_open
    bl eval_num
    bl arg_close
    cmp x0, #1
    b.lt illegal_call
    gld x9, rnd_seed
    eor x9, x9, x9, lsl #13
    eor x9, x9, x9, lsr #7
    eor x9, x9, x9, lsl #17
    gst x9, rnd_seed
    udiv x10, x9, x0
    msub x10, x10, x0, x9
    add x0, x10, #1
    mov x1, #0
    unframe

fn_len:
    frame
    bl arg_open
    bl eval_str
    bl arg_close
    mov x0, x2
    mov x1, #0
    unframe

fn_asc:
    frame
    bl arg_open
    bl eval_str
    bl arg_close
    cbz x2, illegal_call
    ldrb w0, [x0]
    mov x1, #0
    unframe

fn_val:
    frame
    bl arg_open
    bl eval_str
    bl arg_close
    mov x1, x2
    bl parse_val
    mov x1, #0
    unframe

fn_chr:
    frame
    str x19, [sp, #-16]!
    bl arg_open
    bl eval_num
    bl arg_close
    cmp x0, #255
    b.hi illegal_call
    mov x19, x0
    mov x0, #1
    bl temp_alloc
    strb w19, [x0]
    mov x1, #1
    mov x2, #1
    ldr x19, [sp], #16
    unframe

fn_str:
    benter
    bl arg_open
    bl eval_num
    bl arg_close
    bl fmt_num
    mov x19, x0
    mov x20, x2
    mov x0, x2
    bl temp_alloc
    mov x21, x0
    mov x1, x19
    mov x2, x20
    bl copy_bytes
    mov x0, x21
    mov x1, #1
    mov x2, x20
    bleave

fn_space:
    benter
    bl arg_open
    bl eval_num
    bl arg_close
    cmp x0, #255
    b.hi illegal_call
    mov x19, x0
    bl temp_alloc
    mov x9, #0
    mov w10, #' '
1:
    cmp x9, x19
    b.hs 2f
    strb w10, [x0, x9]
    add x9, x9, #1
    b 1b
2:
    mov x1, #1
    mov x2, x19
    bleave

fn_left:
    benter
    bl arg_open
    bl eval_str
    mov x19, x0
    mov x20, x2
    bl arg_comma
    bl eval_num
    bl arg_close
    cmp x0, #0
    b.lt illegal_call
    cmp x0, x20
    csel x2, x0, x20, lo
    mov x0, x19
    mov x1, #1
    bleave

fn_right:
    benter
    bl arg_open
    bl eval_str
    mov x19, x0
    mov x20, x2
    bl arg_comma
    bl eval_num
    bl arg_close
    cmp x0, #0
    b.lt illegal_call
    cmp x0, x20
    csel x2, x0, x20, lo
    add x0, x19, x20
    sub x0, x0, x2
    mov x1, #1
    bleave

fn_mid:                         // MID$(s$, start [, length])
    benter
    bl arg_open
    bl eval_str
    mov x19, x0
    mov x20, x2
    bl arg_comma
    bl eval_num
    mov x21, x0
    mov x22, #255
    bl skip_sp
    cmp w0, #','
    b.ne 1f
    add x28, x28, #1
    bl eval_num
    mov x22, x0
1:
    bl arg_close
    cmp x21, #1
    b.lt illegal_call
    cmp x22, #0
    b.lt illegal_call
    mov x2, #0
    mov x0, x19
    cmp x21, x20
    b.hi 2f
    sub x9, x20, x21
    add x9, x9, #1              // available from start
    cmp x22, x9
    csel x2, x22, x9, lo
    add x0, x19, x21
    sub x0, x0, #1
2:
    mov x1, #1
    bleave

fn_instr:                       // INSTR(a$, b$): position of b$ in a$, or 0
    benter
    bl arg_open
    bl eval_str
    mov x19, x0
    mov x20, x2
    bl arg_comma
    bl eval_str
    mov x21, x0
    mov x22, x2
    bl arg_close
    mov x0, #1
    cbz x22, 9f
    mov x0, #0
    cmp x22, x20
    b.hi 9f
    sub x23, x20, x22           // last start
    mov x9, #0
1:
    cmp x9, x23
    b.hi 8f
    mov x10, #0
2:
    cmp x10, x22
    b.hs 3f
    add x11, x9, x10
    ldrb w12, [x19, x11]
    ldrb w13, [x21, x10]
    cmp w12, w13
    b.ne 4f
    add x10, x10, #1
    b 2b
3:
    add x0, x9, #1
    b 9f
4:
    add x9, x9, #1
    b 1b
8:
    mov x0, #0
9:
    mov x1, #0
    bleave

// ---------------------------------------------------------------------------
// Statements.

exec_statement:
    benter
    bl skip_sp
    cbz w0, 9f
    cmp w0, #':'
    b.eq 9f
    cmp w0, #'?'
    b.ne 1f
    add x28, x28, #1
    bl stmt_print
    bleave
1:
    cmp w0, #'\''
    b.ne 2f
    bl stmt_rem
    bleave
2:
    address x19, stmt_table
    mov x20, x19
3:
    ldrsw x21, [x20]
    cbz x21, 5f
    add x0, x19, x21
    bl match_kw
    cbz x0, 4f
    add x28, x28, x0
    ldrsw x21, [x20, #4]
    add x21, x19, x21
    blr x21
    bleave
4:
    add x20, x20, #8
    b 3b
5:
    ldrb w0, [x28]              // name = value
    sub w0, w0, #'A'
    cmp w0, #25
    b.hi syntax_error
    bl stmt_let
9:
    bleave

stmt_let:
    benter
    bl get_var_ref
    mov x19, x0
    mov x20, x1
    mov w9, #'='
    bl expect_char
    bl eval_expr
    cmp x1, x20
    b.ne type_mismatch
    cbnz x20, 1f
    str x0, [x19]
    bleave
1:
    mov x1, x0
    mov x0, x19
    bl assign_str
    bleave

stmt_print:
    benter
    mov x19, #0                 // 1: the last item was ; or , (no newline)
1:
    bl skip_sp
    cbz w0, 8f
    cmp w0, #':'
    b.eq 8f
    address x0, kw_else
    bl match_kw
    cbnz x0, 8f
    ldrb w0, [x28]
    cmp w0, #';'
    b.ne 2f
    add x28, x28, #1
    mov x19, #1
    b 1b
2:
    cmp w0, #','
    b.ne 3f
    add x28, x28, #1
    gld x0, col                 // the next 14-column zone
    mov x9, #14
    udiv x10, x0, x9
    add x10, x10, #1
    mul x10, x10, x9
    sub x0, x10, x0
    bl out_spaces
    mov x19, #1
    b 1b
3:
    address x0, kw_tab
    bl match_kw
    cbz x0, 4f
    add x28, x28, x0
    bl eval_num
    mov x20, x0
    bl arg_close
    sub x20, x20, #1            // TAB(n): to column n, counted from 1
    gld x0, col
    sub x0, x20, x0
    bl out_spaces
    mov x19, #0
    b 1b
4:
    address x0, kw_spc
    bl match_kw
    cbz x0, 5f
    add x28, x28, x0
    bl eval_num
    mov x20, x0
    bl arg_close
    mov x0, x20
    bl out_spaces
    mov x19, #0
    b 1b
5:
    bl eval_expr
    cbnz x1, 6f
    bl fmt_num
    mov x1, x2
    bl out_bytes
    mov x0, #' '
    bl out_char
    b 7f
6:
    mov x1, x2
    bl out_bytes
7:
    mov x19, #0
    b 1b
8:
    cbnz x19, 9f
    bl out_crlf
9:
    bleave

// INPUT ["prompt";|,] var [, var...]
stmt_input:
    benter
    bl skip_sp
    mov x19, #0                 // prompt text
    mov x20, #0                 // and length
    mov x21, #1                 // 1: add "? "
    cmp w0, #'"'
    b.ne 2f
    bl eval_atom
    mov x19, x0
    mov x20, x2
    bl skip_sp
    cmp w0, #';'
    b.eq 1f
    cmp w0, #','
    b.ne syntax_error
    mov x21, #0
1:
    add x28, x28, #1
2:
    mov x22, x28                // the variable list
input_again:
    mov x0, x19
    mov x1, x20
    bl out_bytes
    cbz x21, 3f
    address x0, qmark_text
    mov x1, #2
    bl out_bytes
3:
    address x0, inbuf2
    mov w1, #255
    strb w1, [x0]
    bl read_console_line
    gst xzr, col
    gld x9, break_flag          // ^C typed at the prompt: Break after ENTER
    cbz x9, 31f
    gst xzr, break_flag
    err E_BREAK
31:
    mov x23, x0                 // the typed line
    mov x28, x22
4:
    bl get_var_ref
    mov x24, x0
    mov x25, x1
5:
    ldrb w0, [x23]
    cmp w0, #' '
    b.ne 6f
    add x23, x23, #1
    b 5b
6:
    cbnz x25, 10f
    mov x0, x23                 // a number: the whole field must be one
    bl field_len
    mov x26, x0
    mov x1, x0
    mov x0, x23
    bl parse_val
    cbz x2, input_redo
    add x9, x23, x1
    add x10, x23, x26
7:
    cmp x9, x10
    b.hs 8f
    ldrb w11, [x9]
    cmp w11, #' '
    b.ne input_redo
    add x9, x9, #1
    b 7b
8:
    str x0, [x24]
    add x23, x23, x26
    b 12f
10:
    ldrb w0, [x23]              // a string: "quoted" or up to the comma
    cmp w0, #'"'
    b.ne 11f
    add x23, x23, #1
    mov x26, x23
101:
    ldrb w0, [x23]
    cbz w0, 102f
    cmp w0, #'"'
    b.eq 102f
    add x23, x23, #1
    b 101b
102:
    sub x2, x23, x26
    cbz w0, 103f
    add x23, x23, #1
103:
    mov x0, x24
    mov x1, x26
    bl assign_str
104:
    ldrb w0, [x23]
    cmp w0, #' '
    b.ne 12f
    add x23, x23, #1
    b 104b
11:
    mov x26, x23
    mov x0, x23
    bl field_len
    add x23, x23, x0
    mov x2, x0
111:
    cbz x2, 112f
    sub x9, x2, #1
    ldrb w10, [x26, x9]
    cmp w10, #' '
    b.ne 112f
    mov x2, x9
    b 111b
112:
    mov x0, x24
    mov x1, x26
    bl assign_str
12:
    bl skip_sp
    cmp w0, #','
    b.ne 13f
    add x28, x28, #1
    ldrb w0, [x23]
    cmp w0, #','
    b.ne input_redo
    add x23, x23, #1
    b 4b
13:
    ldrb w0, [x23]
    cbz w0, 14f
    say "?Extra ignored\r\n"
14:
    bleave
input_redo:
    say "?Redo from start\r\n"
    b input_again

stmt_if:
    benter
    bl eval_expr
    cbnz x1, type_mismatch
    mov x19, x0
    address x0, kw_then
    bl accept_kw
    cbnz x0, 1f
    address x0, kw_goto
    bl accept_kw
    cbz x0, syntax_error
1:
    cbz x19, 3f
2:
    bl skip_sp                  // THEN line, or THEN statements
    sub w1, w0, #'0'
    cmp w1, #9
    b.hi 21f
    bl parse_uint
    bl do_goto
    bleave
21:
    bl exec_statement
    bleave
3:
    mov x20, #0                 // false: find this IF's ELSE
31:
    ldrb w0, [x28]
    cbz w0, 9f
    cmp w0, #'"'
    b.ne 32f
33:
    add x28, x28, #1
    ldrb w0, [x28]
    cbz w0, 9f
    cmp w0, #'"'
    b.ne 33b
    add x28, x28, #1
    b 31b
32:
    address x0, kw_if
    bl match_kw
    cbz x0, 34f
    add x28, x28, x0
    add x20, x20, #1
    b 31b
34:
    address x0, kw_else
    bl match_kw
    cbz x0, 35f
    add x28, x28, x0
    cbz x20, 2b
    sub x20, x20, #1
    b 31b
35:
    add x28, x28, #1
    b 31b
9:
    bleave

// REM, ' and ELSE (after a THEN branch ran): the rest of the line. Leaf.
stmt_rem:
stmt_else:
1:
    ldrb w1, [x28]
    cbz w1, 2f
    add x28, x28, #1
    b 1b
2:
    ret

// x0 = line number: continue there.
do_goto:
    frame
    bl find_line
    cbz x0, undefined_line
    gst x0, cur_line
    add x28, x0, #8
    mov x9, #1
    gst x9, jumped
    unframe

stmt_goto:
    frame
    bl parse_linenum
    bl do_goto
    unframe

// x0 = type, x1 = variable, x2 = limit, x3 = step; the line and x28 are
// where to come back to. Leaf.
ctl_push:
    gld x9, ctl_sp
    cmp x9, #CTL_MAX
    b.hs out_of_memory
    address x10, ctl_stack
    mov x11, #CTL_SIZE
    madd x10, x9, x11, x10
    stp x0, x1, [x10]
    stp x2, x3, [x10, #16]
    gld x11, cur_line
    stp x11, x28, [x10, #32]
    add x9, x9, #1
    gst x9, ctl_sp
    ret

stmt_gosub:
    benter
    bl parse_linenum
    mov x19, x0
    mov x0, #C_GOSUB
    mov x1, #0
    mov x2, #0
    mov x3, #0
    bl ctl_push
    mov x0, x19
    bl do_goto
    bleave

stmt_return:
    gld x9, ctl_sp
    address x10, ctl_stack
1:
    cbz x9, 2f
    sub x9, x9, #1
    mov x11, #CTL_SIZE
    madd x12, x9, x11, x10
    ldr x13, [x12]
    cmp x13, #C_GOSUB
    b.ne 1b
    gst x9, ctl_sp
    ldp x13, x28, [x12, #32]
    gst x13, cur_line
    ret
2:
    err E_RETURN

stmt_for:
    benter
    bl get_var_ref
    cbnz x1, type_mismatch
    mov x19, x0
    mov w9, #'='
    bl expect_char
    bl eval_num
    str x0, [x19]
    address x0, kw_to
    bl accept_kw
    cbz x0, syntax_error
    bl eval_num
    mov x20, x0
    mov x21, #1
    address x0, kw_step
    bl accept_kw
    cbz x0, 1f
    bl eval_num
    mov x21, x0
1:
    gld x9, ctl_sp              // a loop on the same variable ends here
    address x10, ctl_stack
2:
    cbz x9, 4f
    sub x9, x9, #1
    mov x11, #CTL_SIZE
    madd x12, x9, x11, x10
    ldr x13, [x12]
    cmp x13, #C_GOSUB
    b.eq 4f
    cmp x13, #C_FOR
    b.ne 2b
    ldr x13, [x12, #8]
    cmp x13, x19
    b.ne 2b
    gst x9, ctl_sp
4:
    ldr x0, [x19]
    tbnz x21, #63, 5f
    cmp x0, x20
    b.gt 6f
    b 7f
5:
    cmp x0, x20
    b.lt 6f
7:
    mov x0, #C_FOR
    mov x1, x19
    mov x2, x20
    mov x3, x21
    bl ctl_push
    bleave
6:
    address x0, kw_for          // no passes: continue after its NEXT
    address x1, kw_next
    mov x2, #E_FOR
    bl scan_block
    bleave

stmt_next:
    benter
1:
    bl skip_sp
    mov x19, #0
    sub w1, w0, #'A'
    cmp w1, #25
    b.hi 2f
    bl get_var_ref
    cbnz x1, type_mismatch
    mov x19, x0
2:
    gld x20, ctl_sp
    address x21, ctl_stack
3:
    cbz x20, 90f
    sub x20, x20, #1
    mov x9, #CTL_SIZE
    madd x22, x20, x9, x21
    ldr x9, [x22]
    cmp x9, #C_FOR
    b.ne 90f
    cbz x19, 4f
    ldr x9, [x22, #8]
    cmp x9, x19
    b.ne 3b
4:
    ldr x9, [x22, #8]
    ldp x10, x11, [x22, #16]    // limit, step
    ldr x12, [x9]
    add x12, x12, x11
    str x12, [x9]
    tbnz x11, #63, 5f
    cmp x12, x10
    b.gt 6f
    b 7f
5:
    cmp x12, x10
    b.lt 6f
7:
    add x20, x20, #1            // again: back to just after the FOR
    gst x20, ctl_sp
    ldp x9, x28, [x22, #32]
    gst x9, cur_line
    bleave
6:
    gst x20, ctl_sp             // done: the loop is dropped
    bl skip_sp
    cmp w0, #','
    b.ne 8f
    add x28, x28, #1
    b 1b
8:
    bleave
90:
    err E_NEXT

stmt_while:
    benter
    mov x19, x28                // the condition
    bl eval_num
    cbz x0, 3f
    gld x9, ctl_sp              // not twice for the same WHILE
    cbz x9, 2f
    sub x9, x9, #1
    address x10, ctl_stack
    mov x11, #CTL_SIZE
    madd x10, x9, x11, x10
    ldr x11, [x10]
    cmp x11, #C_WHILE
    b.ne 2f
    ldr x11, [x10, #40]
    cmp x11, x19
    b.eq 9f
2:
    mov x20, x28
    mov x28, x19
    mov x0, #C_WHILE
    mov x1, #0
    mov x2, #0
    mov x3, #0
    bl ctl_push
    mov x28, x20
9:
    bleave
3:
    address x0, kw_while
    address x1, kw_wend
    mov x2, #E_WHILE
    bl scan_block
    bleave

stmt_wend:
    benter
    gld x9, ctl_sp
    cbz x9, 8f
    sub x9, x9, #1
    address x10, ctl_stack
    mov x11, #CTL_SIZE
    madd x19, x9, x11, x10
    ldr x11, [x19]
    cmp x11, #C_WHILE
    b.ne 8f
    gld x20, cur_line
    mov x21, x28
    ldp x9, x28, [x19, #32]     // test the condition again
    gst x9, cur_line
    bl eval_num
    cbnz x0, 9f                 // true: the body follows the condition
    gld x9, ctl_sp
    sub x9, x9, #1
    gst x9, ctl_sp
    gst x20, cur_line
    mov x28, x21
9:
    bleave
8:
    err E_WEND

// x0 = opening keyword, x1 = closing keyword, x2 = error if unmatched:
// moves x28 (and the line) past the matching closing keyword and, for
// NEXT, its variable names.
scan_block:
    benter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, #1
1:
    ldrb w0, [x28]
    cbnz w0, 3f
    gld x9, cur_line
    cbz x9, 9f
    ldr w10, [x9, #4]
    add x9, x9, x10
    gld x10, prog_end
    cmp x9, x10
    b.hs 9f
    gst x9, cur_line
    add x28, x9, #8
    b 1b
3:
    cmp w0, #'"'
    b.ne 4f
31:
    add x28, x28, #1
    ldrb w0, [x28]
    cbz w0, 1b
    cmp w0, #'"'
    b.ne 31b
    add x28, x28, #1
    b 1b
4:
    cmp w0, #'\''
    b.eq 41f
    address x0, kw_rem
    bl match_kw
    cbz x0, 5f
41:
    bl stmt_rem
    b 1b
5:
    mov x0, x19
    bl match_kw
    cbz x0, 6f
    add x28, x28, x0
    add x22, x22, #1
    b 1b
6:
    mov x0, x20
    bl match_kw
    cbz x0, 7f
    add x28, x28, x0
    subs x22, x22, #1
    b.ne 1b
61:
    bl skip_sp                  // NEXT I, J
    sub w1, w0, #'A'
    cmp w1, #25
    b.hi 8f
    bl read_name
    bl skip_sp
    cmp w0, #','
    b.ne 8f
    add x28, x28, #1
    b 61b
7:
    add x28, x28, #1
    b 1b
8:
    bleave
9:
    mov x0, x21
    b basic_error

stmt_end:
    gst xzr, cur_line
    address x28, empty_line
    ret

stmt_stop:
    err E_BREAK

// DATA: skipped when executed. Leaf.
stmt_data:
1:
    ldrb w0, [x28]
    cbz w0, 9f
    cmp w0, #':'
    b.eq 9f
    cmp w0, #'"'
    b.ne 2f
3:
    add x28, x28, #1
    ldrb w0, [x28]
    cbz w0, 9f
    cmp w0, #'"'
    b.ne 3b
2:
    add x28, x28, #1
    b 1b
9:
    ret

stmt_read:
    benter
1:
    bl get_var_ref
    mov x19, x0
    mov x20, x1
    bl next_data
    cbnz x20, 3f
    mov x1, x2
    bl parse_val
    cbz x2, syntax_error
    str x0, [x19]
    b 4f
3:
    mov x1, x0
    mov x0, x19
    bl assign_str
4:
    bl skip_sp
    cmp w0, #','
    b.ne 9f
    add x28, x28, #1
    b 1b
9:
    bleave

// The next DATA item: x0 = its text, x2 = length. The position is kept in
// data_rec (the line) and data_pos (just after the last item).
next_data:
    benter
    gld x19, data_pos
    gld x20, data_rec
    cbz x19, 2f
    ldrb w0, [x19]
    cmp w0, #','
    b.ne 3f
    add x19, x19, #1
    b 6f
2:
    cbnz x20, 21f
    address x20, prog_area
21:
    gld x9, prog_end
    cmp x20, x9
    b.hs 90f
    add x19, x20, #8
3:
    ldrb w0, [x19]              // look for the next DATA
    cbnz w0, 4f
    ldr w9, [x20, #4]
    add x20, x20, x9
    gld x9, prog_end
    cmp x20, x9
    b.hs 90f
    add x19, x20, #8
    b 3b
4:
    cmp w0, #'"'
    b.ne 5f
41:
    add x19, x19, #1
    ldrb w0, [x19]
    cbz w0, 3b
    cmp w0, #'"'
    b.ne 41b
    add x19, x19, #1
    b 3b
5:
    mov x21, x28
    mov x28, x19
    address x0, kw_data
    bl match_kw
    mov x28, x21
    cbnz x0, 51f
    add x19, x19, #1
    b 3b
51:
    add x19, x19, x0
6:
    ldrb w0, [x19]              // one item
    cmp w0, #' '
    b.ne 61f
    add x19, x19, #1
    b 6b
61:
    cmp w0, #'"'
    b.ne 7f
    add x19, x19, #1
    mov x21, x19
62:
    ldrb w0, [x19]
    cbz w0, 63f
    cmp w0, #'"'
    b.eq 63f
    add x19, x19, #1
    b 62b
63:
    sub x22, x19, x21
    cbz w0, 64f
    add x19, x19, #1
64:
    ldrb w0, [x19]
    cmp w0, #' '
    b.ne 8f
    add x19, x19, #1
    b 64b
7:
    mov x21, x19
71:
    ldrb w0, [x19]
    cbz w0, 72f
    cmp w0, #','
    b.eq 72f
    cmp w0, #':'
    b.eq 72f
    add x19, x19, #1
    b 71b
72:
    sub x22, x19, x21
73:
    cbz x22, 8f
    sub x9, x22, #1
    ldrb w10, [x21, x9]
    cmp w10, #' '
    b.ne 8f
    mov x22, x9
    b 73b
8:
    gst x19, data_pos
    gst x20, data_rec
    mov x0, x21
    mov x2, x22
    bleave
90:
    err E_DATA

stmt_restore:
    benter
    mov x19, #0
    bl skip_sp
    sub w1, w0, #'0'
    cmp w1, #9
    b.hi 1f
    bl parse_uint
    bl find_line
    cbz x0, undefined_line
    mov x19, x0
1:
    gst x19, data_rec
    gst xzr, data_pos
    bleave

stmt_dim:
    benter
1:
    bl skip_sp
    sub w1, w0, #'A'
    cmp w1, #25
    b.hi syntax_error
    bl read_name
    mov x19, x0
    address x9, namebuf
    ldp x20, x21, [x9]
    bl arg_open
    bl eval_num
    mov x22, x0
    bl arg_close
    mov x9, #0x100000           // at most 1 Mi elements
    cmp x22, x9
    b.hi illegal_call           // unsigned: negative bounds too
    address x9, namebuf
    stp x20, x21, [x9]
    add x0, x19, #K_NUMARR
    bl find_var
    cbz x0, 2f
    err E_REDIM
2:
    mov x0, x19
    mov x1, x22
    bl make_array
    bl skip_sp
    cmp w0, #','
    b.ne 9f
    add x28, x28, #1
    b 1b
9:
    bleave

stmt_cls:
    frame
    address x0, cls_text
    mov x1, #7
    bl out_bytes
    gst xzr, col
    unframe

stmt_randomize:
    frame
    bl skip_sp
    cbz w0, 1f
    cmp w0, #':'
    b.eq 1f
    bl eval_num
    b 2f
1:
    dos 0x2c                    // from the clock
    mov x9, #60
    madd x0, x0, x9, x2
    madd x0, x0, x9, x3
    mov x9, #100
    madd x0, x0, x9, x4
2:
    ldr x9, =0x9e3779b97f4a7c15
    add x0, x0, #1
    mul x0, x0, x9
    orr x0, x0, #1
    gst x0, rnd_seed
    unframe

stmt_on:
    benter
    bl eval_num
    mov x19, x0
    mov x20, #0                 // 1: GOSUB
    address x0, kw_goto
    bl accept_kw
    cbnz x0, 1f
    address x0, kw_gosub
    bl accept_kw
    cbz x0, syntax_error
    mov x20, #1
1:
    mov x21, #1
    mov x22, #0
2:
    bl parse_linenum
    cmp x21, x19
    csel x22, x0, x22, eq
    add x21, x21, #1
    bl skip_sp
    cmp w0, #','
    b.ne 3f
    add x28, x28, #1
    b 2b
3:
    cbz x22, 9f
    cbz x20, 4f
    mov x0, #C_GOSUB
    mov x1, #0
    mov x2, #0
    mov x3, #0
    bl ctl_push
4:
    mov x0, x22
    bl do_goto
9:
    bleave

stmt_new:
    frame
    bl clear_program
    gst xzr, cur_line
    address x28, empty_line
    unframe

stmt_clear:
    b clear_vars

stmt_system:
    gld x1, break_saved
    mov x0, #1
    dos 0x33
    mov x0, #0
    b exit

stmt_list:
    benter
    mov x19, #0                 // from
    mov x20, #-1                // to
    bl skip_sp
    sub w1, w0, #'0'
    cmp w1, #9
    b.hi 1f
    bl parse_uint
    mov x19, x0
    mov x20, x0
    bl skip_sp
    cmp w0, #'-'
    b.ne 3f
    add x28, x28, #1
    mov x20, #-1
    bl skip_sp
    sub w1, w0, #'0'
    cmp w1, #9
    b.hi 3f
    bl parse_uint
    mov x20, x0
    b 3f
1:
    cmp w0, #'-'
    b.ne 3f
    add x28, x28, #1
    bl parse_linenum
    mov x20, x0
3:
    address x21, prog_area
4:
    gld x9, prog_end
    cmp x21, x9
    b.hs 9f
    ldr w22, [x21]
    cmp x22, x19
    b.lo 5f
    cmp x22, x20
    b.hi 9f
    mov x0, x22
    address x1, numbuf
    bl utoa
    bl out_cstr
    mov x0, #' '
    bl out_char
    add x0, x21, #8
    bl out_cstr
    bl out_crlf
    dos 0x0b                    // Ctrl-C stops a long listing
    gld x9, break_flag
    cbz x9, 5f
    gst xzr, break_flag
    b 9f
5:
    ldr w9, [x21, #4]
    add x21, x21, x9
    b 4b
9:
    bleave

stmt_run:
    benter
    mov x19, #0
    bl skip_sp
    cmp w0, #'"'
    b.ne 1f
    bl parse_filename
    bl load_file
    b 2f
1:
    sub w1, w0, #'0'
    cmp w1, #9
    b.hi 2f
    bl parse_uint
    mov x19, x0
2:
    bl clear_vars
    address x0, prog_area
    gld x9, prog_end
    cmp x0, x9
    b.hs 8f
    cbz x19, 3f
    mov x0, x19
    bl find_line
    cbz x0, undefined_line
3:
    gst x0, cur_line
    add x28, x0, #8
    mov x9, #1
    gst x9, jumped
    bleave
8:
    gst xzr, cur_line
    address x28, empty_line
    bleave

stmt_load:
    frame
    bl parse_filename
    bl load_file
    gst xzr, cur_line
    address x28, empty_line
    unframe

stmt_save:
    frame
    bl parse_filename
    bl save_file
    unframe

// "name" at x28 into fname; .BAS is added when there is no extension.
parse_filename:
    frame
    mov w9, #'"'
    bl expect_char
    address x9, fname
    mov x10, #0
    mov x11, #0                 // 1: the name has an extension
1:
    ldrb w0, [x28]
    cbz w0, 3f
    add x28, x28, #1
    cmp w0, #'"'
    b.eq 3f
    cmp x10, #70
    b.hs 1b
    cmp w0, #'.'
    cinc x11, x11, eq
    cmp w0, #'\\'
    csel x11, xzr, x11, eq
    strb w0, [x9, x10]
    add x10, x10, #1
    b 1b
3:
    cbnz x10, 4f
    err E_FILEIO
4:
    cbnz x11, 5f
    mov w0, #'.'
    strb w0, [x9, x10]
    add x10, x10, #1
    mov w0, #'B'
    strb w0, [x9, x10]
    add x10, x10, #1
    mov w0, #'A'
    strb w0, [x9, x10]
    add x10, x10, #1
    mov w0, #'S'
    strb w0, [x9, x10]
    add x10, x10, #1
5:
    strb wzr, [x9, x10]
    unframe

load_file:
    benter
    address x0, fname
    mov x1, #0
    bl fopen
    cbz x1, 1f
    err E_FILE
1:
    gst x0, load_handle
    mov x19, x0
    bl clear_program
    address x0, reader
    mov x1, x19
    bl lr_init
2:
    address x0, reader
    address x1, filebuf
    mov x2, #256
    bl lr_getline
    cbnz x1, 8f
    address x0, filebuf
    address x1, loadbuf
    bl crunch
    mov x20, x28
    address x28, loadbuf
    bl skip_sp
    cbz w0, 3f                  // a blank line
    sub w1, w0, #'0'
    cmp w1, #9
    b.ls 21f
    err E_DIRECTFILE
21:
    bl parse_uint
    mov x1, x28
    bl edit_line
3:
    mov x28, x20
    b 2b
8:
    gst xzr, load_handle
    mov x0, x19
    bl fclose
    bleave

save_file:
    benter
    address x0, fname
    mov x1, #0
    bl fcreate
    cbz x1, 1f
    err E_FILEIO
1:
    mov x19, x0
    gst x0, load_handle         // closed if an error ends the save
    address x20, prog_area
2:
    gld x9, prog_end
    cmp x20, x9
    b.hs 8f
    ldr w0, [x20]
    address x1, numbuf
    bl utoa
    address x1, filebuf
    bl strcpy                   // x0 = its NUL
    mov w9, #' '
    strb w9, [x0], #1
    mov x1, x0
    add x0, x20, #8
    bl strcpy
    mov w9, #13
    strb w9, [x0], #1
    mov w9, #10
    strb w9, [x0], #1
    address x1, filebuf
    sub x2, x0, x1
    mov x0, x19
    bl fwrite
    cbnz x1, 9f
    ldr w9, [x20, #4]
    add x20, x20, x9
    b 2b
8:
    gst xzr, load_handle
    mov x0, x19
    bl fclose
    bleave
9:
    err E_FILEIO

// ---------------------------------------------------------------------------
// Tables (relative offsets, so they need no relocation).

.balign 4
.macro entry name, handler
    .word \name - stmt_table, \handler - stmt_table
.endm
stmt_table:
    entry kw_print, stmt_print
    entry kw_let, stmt_let
    entry kw_input, stmt_input
    entry kw_if, stmt_if
    entry kw_goto, stmt_goto
    entry kw_gosub, stmt_gosub
    entry kw_return, stmt_return
    entry kw_for, stmt_for
    entry kw_next, stmt_next
    entry kw_while, stmt_while
    entry kw_wend, stmt_wend
    entry kw_end, stmt_end
    entry kw_stop, stmt_stop
    entry kw_rem, stmt_rem
    entry kw_else, stmt_else
    entry kw_dim, stmt_dim
    entry kw_data, stmt_data
    entry kw_read, stmt_read
    entry kw_restore, stmt_restore
    entry kw_randomize, stmt_randomize
    entry kw_cls, stmt_cls
    entry kw_clear, stmt_clear
    entry kw_on, stmt_on
    entry kw_run, stmt_run
    entry kw_list, stmt_list
    entry kw_new, stmt_new
    entry kw_load, stmt_load
    entry kw_save, stmt_save
    entry kw_system, stmt_system
    .word 0, 0

.macro fentry name, handler
    .word \name - func_table, \handler - func_table
.endm
func_table:
    fentry fname_abs, fn_abs
    fentry fname_sgn, fn_sgn
    fentry fname_int, fn_int
    fentry fname_sqr, fn_sqr
    fentry fname_rnd, fn_rnd
    fentry fname_len, fn_len
    fentry fname_asc, fn_asc
    fentry fname_val, fn_val
    fentry fname_chr, fn_chr
    fentry fname_str, fn_str
    fentry fname_left, fn_left
    fentry fname_right, fn_right
    fentry fname_mid, fn_mid
    fentry fname_instr, fn_instr
    fentry fname_space, fn_space
    .word 0, 0

err_table:
    .word e0 - err_table, e1 - err_table, e2 - err_table, e3 - err_table
    .word e4 - err_table, e5 - err_table, e6 - err_table, e7 - err_table
    .word e8 - err_table, e9 - err_table, e10 - err_table, e11 - err_table
    .word e12 - err_table, e13 - err_table, e14 - err_table, e15 - err_table
    .word e16 - err_table, e17 - err_table, e18 - err_table, e19 - err_table

kw_print: .asciz "PRINT"
kw_let: .asciz "LET"
kw_input: .asciz "INPUT"
kw_if: .asciz "IF"
kw_then: .asciz "THEN"
kw_else: .asciz "ELSE"
kw_goto: .asciz "GOTO"
kw_gosub: .asciz "GOSUB"
kw_return: .asciz "RETURN"
kw_for: .asciz "FOR"
kw_to: .asciz "TO"
kw_step: .asciz "STEP"
kw_next: .asciz "NEXT"
kw_while: .asciz "WHILE"
kw_wend: .asciz "WEND"
kw_end: .asciz "END"
kw_stop: .asciz "STOP"
kw_rem: .asciz "REM"
kw_dim: .asciz "DIM"
kw_data: .asciz "DATA"
kw_read: .asciz "READ"
kw_restore: .asciz "RESTORE"
kw_randomize: .asciz "RANDOMIZE"
kw_cls: .asciz "CLS"
kw_clear: .asciz "CLEAR"
kw_on: .asciz "ON"
kw_run: .asciz "RUN"
kw_list: .asciz "LIST"
kw_new: .asciz "NEW"
kw_load: .asciz "LOAD"
kw_save: .asciz "SAVE"
kw_system: .asciz "SYSTEM"
kw_or: .asciz "OR"
kw_and: .asciz "AND"
kw_not: .asciz "NOT"
kw_mod: .asciz "MOD"
kw_tab: .asciz "TAB("
kw_spc: .asciz "SPC("
fname_abs: .asciz "ABS"
fname_sgn: .asciz "SGN"
fname_int: .asciz "INT"
fname_sqr: .asciz "SQR"
fname_rnd: .asciz "RND"
fname_len: .asciz "LEN"
fname_asc: .asciz "ASC"
fname_val: .asciz "VAL"
fname_chr: .asciz "CHR$"
fname_str: .asciz "STR$"
fname_left: .asciz "LEFT$"
fname_right: .asciz "RIGHT$"
fname_mid: .asciz "MID$"
fname_instr: .asciz "INSTR"
fname_space: .asciz "SPACE$"
e0: .asciz "Syntax error"
e1: .asciz "RETURN without GOSUB"
e2: .asciz "Out of DATA"
e3: .asciz "Illegal function call"
e4: .asciz "Out of memory"
e5: .asciz "Undefined line number"
e6: .asciz "Subscript out of range"
e7: .asciz "Duplicate Definition"
e8: .asciz "Division by zero"
e9: .asciz "Type mismatch"
e10: .asciz "Out of string space"
e11: .asciz "String too long"
e12: .asciz "NEXT without FOR"
e13: .asciz "WEND without WHILE"
e14: .asciz "WHILE without WEND"
e15: .asciz "FOR without NEXT"
e16: .asciz "File not found"
e17: .asciz "Direct statement in file"
e18: .asciz "Bad file name or disk error"
e19: .asciz "Break"
crlf_text: .ascii "\r\n"
qmark_text: .ascii "? "
cls_text: .byte 27, '[', '2', 'J', 27, '[', 'H'
.balign 4
.ltorg

.section .data
.balign 8
rnd_seed: .quad 0x2545f4914f6cdd1d
empty_line: .byte 0
.section .bss
.balign 16
err_sp: .skip 8
cur_line: .skip 8
jumped: .skip 8
prog_end: .skip 8
var_count: .skip 8
heap_ptr: .skip 8
temp_ptr: .skip 8
ctl_sp: .skip 8
data_rec: .skip 8
data_pos: .skip 8
col: .skip 8
break_flag: .skip 8
break_saved: .skip 8
poll_count: .skip 8
load_handle: .skip 8
namebuf: .skip 16
numbuf: .skip 32
fname: .skip 80
inbuf: .skip 264
inbuf2: .skip 264
linebuf: .skip 264
loadbuf: .skip 264
filebuf: .skip 320
reader: .skip LR_SIZE
.balign 16
ctl_stack: .skip CTL_MAX * CTL_SIZE
vars: .skip VAR_MAX * VAR_SIZE
prog_area: .skip PROG_SIZE
temp_area: .skip TEMP_SIZE
heap_area: .skip HEAP_SIZE
