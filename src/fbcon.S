// SPDX-License-Identifier: MIT
// Framebuffer text console for native mode. Every byte plat_putc sends to
// the UART is also drawn here (when a screen exists): an 80x25 grid of 8x16
// character cells (fewer on a small screen), centred, in the CGA colours,
// with an underline cursor and the ANSI subset that ANSI.SYS and the
// firmware console path understand (ESC[2J, ESC[K, ESC[r;cH/f, ESC[A-D,
// ESC[s/u and ESC 7/8, ESC[..m with bold and reverse).
//
// Where the screen comes from:
//  - UEFI GOP, captured by fbcon_capture before ExitBootServices: the first
//    GOP with a linear 32-bit framebuffer (RGBx or BGRx). On QEMU virt that
//    is `-device ramfb`; EDK2's virtio-gpu GOP is Blt-only (it needs flush
//    commands), so it is skipped and such a machine stays serial-only.
//  - Raspberry Pi 3/4 without a GOP: a framebuffer allocated from the
//    VideoCore firmware through the mailbox property channel (fbcon_mailbox).
//
// The console keeps a copy of every cell (character + attribute) and only
// redraws cells whose content changes, so scrolling never reads the
// framebuffer back. All framebuffer stores are aligned 32-bit STR/STP: the
// framebuffer may be mapped as Device memory, where unaligned accesses and
// DC ZVA fault. Without a screen fbcon_active stays 0 and plat_putc never
// calls in here.

.equ FB_COLS_MAX, 80
.equ FB_ROWS_MAX, 25
.equ FB_PARAMS, 8
.equ FB_MBOX_BYTES, 36 * 4     // mailbox property message
// fbcon_state layout
.equ FS_ACTIVE, 0           // 1 once fbcon_setup drew the screen
.equ FS_BASE, 8             // framebuffer (0: none captured)
.equ FS_SIZE, 16
.equ FS_WIDTH, 24           // pixels
.equ FS_HEIGHT, 32
.equ FS_STRIDE, 40          // bytes per scan line
.equ FS_FORMAT, 48          // 0 RGBx (byte 0 red), 1 BGRx (byte 0 blue)
.equ FS_ORIGIN, 56          // top-left pixel of cell 0
.equ FS_COLS, 64
.equ FS_ROWS, 72
.equ FS_COL, 80
.equ FS_ROW, 88
.equ FS_ATTR, 96            // CGA attribute: bits 0-3 foreground, 4-6 background
.equ FS_REVERSE, 104
.equ FS_SAVE_COL, 112
.equ FS_SAVE_ROW, 120
.equ FS_CURSOR, 128         // cell showing the cursor, or -1
.equ FS_ESC, 136            // 0 text, 1 after ESC, 2 in ESC[, 3 in a quoted string
.equ FS_NPARAM, 144         // index of the parameter being read
.equ FS_PARAMS, 152         // FB_PARAMS parameters
.equ FS_PALETTE, 216        // 16 pixel values in the framebuffer's format
.equ FS_CELLS, 280          // u16 per cell: character | attribute << 8
.equ FS_BYTES, (FS_CELLS + FB_COLS_MAX * FB_ROWS_MAX * 2)

.section .text

// Entered by a branch from plat_putc (native mode, screen active) with
// w0 = byte. Draws it, then continues with the UART output. plat_putc's
// callers may rely on it clobbering only x0-x2, so x3-x18 are kept.
fbcon_mirror:
    stp x29, x30, [sp, #-160]!
    mov x29, sp
    stp x0, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    str x18, [sp, #144]
    bl fbcon_putc
    ldp x0, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldr x18, [sp, #144]
    ldp x29, x30, [sp], #160
    b plat_putc_uart

// w0 = byte. Interprets controls and escape sequences, draws text.
fbcon_putc:
    enter
    address x19, fbcon_state
    and w20, w0, #0xff
    ldr x0, [x19, #FS_ACTIVE]
    cbz x0, fb_return
    ldr x0, [x19, #FS_ESC]
    cbnz x0, fb_escape
    cmp w20, #32
    b.hs fb_printable
    cmp w20, #27
    b.eq fb_esc_start
    cmp w20, #13
    b.eq fb_cr
    cmp w20, #10
    b.eq fb_lf
    cmp w20, #8
    b.eq fb_bs
    cmp w20, #9
    b.eq fb_tab
    cmp w20, #7                 // BEL: nothing to show
    b.eq fb_return
    cbz w20, fb_return          // NUL
fb_printable:                   // other controls draw their CP437 glyph
    ldr x1, [x19, #FS_ROW]
    ldr x2, [x19, #FS_COL]
    ldr x3, [x19, #FS_COLS]
    madd x21, x1, x3, x2
    bl fb_effective_attr
    orr w1, w20, w0, lsl #8
    mov x0, x21
    bl fb_put_cell
    ldr x2, [x19, #FS_COL]
    add x2, x2, #1
    ldr x3, [x19, #FS_COLS]
    cmp x2, x3                  // wrap at once, as the PC BIOS does
    b.lo 1f
    str xzr, [x19, #FS_COL]
    bl fb_linefeed
    b fb_done
1:
    str x2, [x19, #FS_COL]
    b fb_done
fb_cr:
    str xzr, [x19, #FS_COL]
    b fb_done
fb_lf:
    bl fb_linefeed
    b fb_done
fb_bs:
    ldr x2, [x19, #FS_COL]
    cbz x2, fb_done
    sub x2, x2, #1
    str x2, [x19, #FS_COL]
    b fb_done
fb_tab:
    ldr x2, [x19, #FS_COL]
    orr x2, x2, #7
    add x2, x2, #1
    ldr x3, [x19, #FS_COLS]
    cmp x2, x3
    b.lo 1f
    str xzr, [x19, #FS_COL]
    bl fb_linefeed
    b fb_done
1:
    str x2, [x19, #FS_COL]
    b fb_done
fb_esc_start:
    mov x0, #1
    str x0, [x19, #FS_ESC]
    b fb_return
fb_done:
    bl fb_show_cursor
fb_return:
    leave

// Escape sequence states; x0 = state, w20 = byte.
fb_escape:
    cmp w20, #27                // ESC restarts a sequence
    b.eq fb_esc_start
    cmp x0, #1
    b.ne 1f
    str xzr, [x19, #FS_ESC]
    cmp w20, #'7'               // ESC 7 / ESC 8 (DEC): save / restore the
    b.eq fb_csi_save            // cursor; ANSI.SYS turns ESC[s/u into them
    cmp w20, #'8'
    b.eq fb_csi_restore
    cmp w20, #'['               // other ESC x sequences: dropped
    b.ne fb_return
    mov x0, #2
    str x0, [x19, #FS_ESC]
    str xzr, [x19, #FS_NPARAM]
    add x1, x19, #FS_PARAMS
    stp xzr, xzr, [x1]
    stp xzr, xzr, [x1, #16]
    stp xzr, xzr, [x1, #32]
    stp xzr, xzr, [x1, #48]
    b fb_return
1:
    cmp x0, #3                  // "string" in a key reassignment: skipped
    b.ne 2f
    cmp w20, #'"'
    b.ne fb_return
    mov x0, #2
    str x0, [x19, #FS_ESC]
    b fb_return
2:
    sub w1, w20, #'0'
    cmp w1, #9
    b.hi 3f
    ldr x2, [x19, #FS_NPARAM]
    cmp x2, #FB_PARAMS
    b.hs fb_return
    add x3, x19, #FS_PARAMS
    ldr x4, [x3, x2, lsl #3]
    mov x5, #10
    madd x4, x4, x5, x1
    mov x5, #9999               // larger values only clamp anyway
    cmp x4, x5
    csel x4, x5, x4, hi
    str x4, [x3, x2, lsl #3]
    b fb_return
3:
    cmp w20, #';'
    b.ne 4f
    ldr x2, [x19, #FS_NPARAM]
    add x2, x2, #1
    str x2, [x19, #FS_NPARAM]
    b fb_return
4:
    cmp w20, #'"'
    b.ne 5f
    mov x0, #3
    str x0, [x19, #FS_ESC]
    b fb_return
5:
    cmp w20, #0x40              // not a final byte ('=', '?', ...): ignored
    b.lo fb_return
    cmp w20, #0x7e
    b.hi fb_return
    str xzr, [x19, #FS_ESC]
    ldr x21, [x19, #FS_PARAMS]       // first parameter
    ldr x22, [x19, #(FS_PARAMS + 8)] // second
    cmp w20, #'H'
    b.eq fb_csi_position
    cmp w20, #'f'
    b.eq fb_csi_position
    cmp w20, #'A'
    b.eq fb_csi_up
    cmp w20, #'B'
    b.eq fb_csi_down
    cmp w20, #'C'
    b.eq fb_csi_right
    cmp w20, #'D'
    b.eq fb_csi_left
    cmp w20, #'J'
    b.eq fb_csi_clear
    cmp w20, #'K'
    b.eq fb_csi_erase_line
    cmp w20, #'m'
    b.eq fb_csi_sgr
    cmp w20, #'s'
    b.eq fb_csi_save
    cmp w20, #'u'
    b.eq fb_csi_restore
fb_esc_end:                     // anything else (h, l, n, p, ...) is ignored
    str xzr, [x19, #FS_ESC]
    b fb_return

// ESC[row;colH: 1-based, 0 or missing means 1, clamped to the screen.
fb_csi_position:
    subs x21, x21, #1
    csel x21, xzr, x21, lo
    ldr x3, [x19, #FS_ROWS]
    sub x3, x3, #1
    cmp x21, x3
    csel x21, x3, x21, hi
    subs x22, x22, #1
    csel x22, xzr, x22, lo
    ldr x3, [x19, #FS_COLS]
    sub x3, x3, #1
    cmp x22, x3
    csel x22, x3, x22, hi
    str x21, [x19, #FS_ROW]
    str x22, [x19, #FS_COL]
    b fb_done
fb_csi_up:
    cmp x21, #1
    csinc x21, x21, xzr, hs     // count 0 means 1
    ldr x2, [x19, #FS_ROW]
    subs x2, x2, x21
    csel x2, xzr, x2, lo
    str x2, [x19, #FS_ROW]
    b fb_done
fb_csi_down:
    cmp x21, #1
    csinc x21, x21, xzr, hs
    ldr x2, [x19, #FS_ROW]
    add x2, x2, x21
    ldr x3, [x19, #FS_ROWS]
    sub x3, x3, #1
    cmp x2, x3
    csel x2, x3, x2, hi
    str x2, [x19, #FS_ROW]
    b fb_done
fb_csi_right:
    cmp x21, #1
    csinc x21, x21, xzr, hs
    ldr x2, [x19, #FS_COL]
    add x2, x2, x21
    ldr x3, [x19, #FS_COLS]
    sub x3, x3, #1
    cmp x2, x3
    csel x2, x3, x2, hi
    str x2, [x19, #FS_COL]
    b fb_done
fb_csi_left:
    cmp x21, #1
    csinc x21, x21, xzr, hs
    ldr x2, [x19, #FS_COL]
    subs x2, x2, x21
    csel x2, xzr, x2, lo
    str x2, [x19, #FS_COL]
    b fb_done

// ESC[2J (any parameter): clear the screen and home the cursor, as
// ANSI.SYS does.
fb_csi_clear:
    bl fb_hide_cursor
    ldr x2, [x19, #FS_COLS]
    ldr x3, [x19, #FS_ROWS]
    mul x22, x2, x3
    mov x21, #0
    b fb_fill_range
// ESC[K: erase to the end of the line; ESC[1K to the cursor; ESC[2K all.
fb_csi_erase_line:
    ldr x1, [x19, #FS_ROW]
    ldr x2, [x19, #FS_COL]
    ldr x3, [x19, #FS_COLS]
    mul x4, x1, x3              // line start
    add x5, x4, x2              // cursor
    add x6, x4, x3              // line end
    cmp x21, #1
    b.eq 1f
    b.hi 2f
    mov x21, x5
    mov x22, x6
    b fb_fill_line
1:
    mov x21, x4
    add x22, x5, #1
    b fb_fill_line
2:
    mov x21, x4
    mov x22, x6
fb_fill_line:
    bl fb_fill
    b fb_done
fb_fill_range:
    bl fb_fill
    str xzr, [x19, #FS_ROW]
    str xzr, [x19, #FS_COL]
    b fb_done

// ESC[..m: 0 normal, 1 bold (bright), 22 normal intensity, 7 reverse,
// 27 not reversed, 30-37 foreground, 39 default, 40-47 background, 49
// default. ESC[m alone is ESC[0m.
fb_csi_sgr:
    ldr x21, [x19, #FS_NPARAM]
    add x21, x21, #1
    cmp x21, #FB_PARAMS
    mov x2, #FB_PARAMS
    csel x21, x2, x21, hi
    ldr x4, [x19, #FS_ATTR]
    ldr x5, [x19, #FS_REVERSE]
    add x6, x19, #FS_PARAMS
    address x7, fbcon_ansi_cga
    mov x8, #0
1:
    ldr x2, [x6, x8, lsl #3]
    cbnz x2, 2f
    mov x4, #0x07
    mov x5, #0
    b 8f
2:
    cmp x2, #1
    b.ne 3f
    orr x4, x4, #0x08
    b 8f
3:
    cmp x2, #22
    b.ne 31f
    bic x4, x4, #0x08
    b 8f
31:
    cmp x2, #7
    b.ne 32f
    mov x5, #1
    b 8f
32:
    cmp x2, #27
    b.ne 33f
    mov x5, #0
    b 8f
33:
    cmp x2, #39
    b.ne 34f
    mov x2, #37
34:
    cmp x2, #49
    b.ne 35f
    mov x2, #40
35:
    sub x3, x2, #30
    cmp x3, #7
    b.hi 4f
    ldrb w3, [x7, x3]
    bic x4, x4, #0x07
    orr x4, x4, x3
    b 8f
4:
    sub x3, x2, #40
    cmp x3, #7
    b.hi 8f
    ldrb w3, [x7, x3]
    bic x4, x4, #0x70
    orr x4, x4, x3, lsl #4
8:
    add x8, x8, #1
    cmp x8, x21
    b.lo 1b
    str x4, [x19, #FS_ATTR]
    str x5, [x19, #FS_REVERSE]
    b fb_return
fb_csi_save:
    ldr x2, [x19, #FS_COL]
    ldr x3, [x19, #FS_ROW]
    str x2, [x19, #FS_SAVE_COL]
    str x3, [x19, #FS_SAVE_ROW]
    b fb_return
fb_csi_restore:
    ldr x2, [x19, #FS_SAVE_COL]
    ldr x3, [x19, #FS_SAVE_ROW]
    str x2, [x19, #FS_COL]
    str x3, [x19, #FS_ROW]
    b fb_done

// Helpers below take x19 = fbcon_state.

// Returns w0 = the attribute new text gets (reverse swaps the colours and
// keeps the intensity on the foreground).
fb_effective_attr:
    ldr x0, [x19, #FS_ATTR]
    ldr x1, [x19, #FS_REVERSE]
    cbz x1, 1f
    ubfx x1, x0, #4, #3
    and x2, x0, #0x08
    orr x1, x1, x2
    and x2, x0, #0x07
    orr x0, x1, x2, lsl #4
1:
    ret

// Cells x21 up to (not including) x22 become blanks in the current colours.
fb_fill:
    frame
    stp x23, x24, [sp, #-16]!
    bl fb_effective_attr
    mov w23, #' '
    orr w23, w23, w0, lsl #8
1:
    cmp x21, x22
    b.hs 2f
    mov x0, x21
    mov w1, w23
    bl fb_put_cell
    add x21, x21, #1
    b 1b
2:
    ldp x23, x24, [sp], #16
    unframe

// Cursor down a line, scrolling at the bottom.
fb_linefeed:
    ldr x2, [x19, #FS_ROW]
    add x2, x2, #1
    ldr x3, [x19, #FS_ROWS]
    cmp x2, x3
    b.hs fb_scroll
    str x2, [x19, #FS_ROW]
    ret

// Move every line up one and blank the last one; only changed cells are
// redrawn.
fb_scroll:
    frame
    stp x21, x22, [sp, #-16]!
    bl fb_hide_cursor
    ldr x2, [x19, #FS_COLS]
    ldr x3, [x19, #FS_ROWS]
    sub x3, x3, #1
    mul x22, x2, x3             // cells that receive the line below
    mov x21, #0
    add x9, x19, #FS_CELLS
1:
    cmp x21, x22
    b.hs 2f
    ldr x2, [x19, #FS_COLS]
    add x3, x21, x2
    add x9, x19, #FS_CELLS
    ldrh w1, [x9, x3, lsl #1]
    mov x0, x21
    bl fb_put_cell
    add x21, x21, #1
    b 1b
2:
    ldr x2, [x19, #FS_COLS]
    add x22, x22, x2
    bl fb_fill
    ldp x21, x22, [sp], #16
    unframe

// x0 = cell index, w1 = character | attribute << 8. Stores and draws it
// unless the screen already shows exactly that.
fb_put_cell:
    add x9, x19, #FS_CELLS
    ldrh w2, [x9, x0, lsl #1]
    ldr x3, [x19, #FS_CURSOR]
    cmp x0, x3
    b.eq 1f
    cmp w2, w1
    b.ne 2f
    ret
1:
    mov x3, #-1                 // the redraw removes the cursor
    str x3, [x19, #FS_CURSOR]
2:
    strh w1, [x9, x0, lsl #1]
    mov w2, #0
    b fb_draw

fb_hide_cursor:
    ldr x0, [x19, #FS_CURSOR]
    tbnz x0, #63, 1f
    mov x3, #-1
    str x3, [x19, #FS_CURSOR]
    add x9, x19, #FS_CELLS
    ldrh w1, [x9, x0, lsl #1]
    mov w2, #0
    b fb_draw
1:
    ret

// Draw the cursor at the current position (and remove it from where it was).
fb_show_cursor:
    frame
    ldr x1, [x19, #FS_ROW]
    ldr x2, [x19, #FS_COL]
    ldr x3, [x19, #FS_COLS]
    madd x4, x1, x3, x2
    ldr x0, [x19, #FS_CURSOR]
    cmp x0, x4
    b.eq 1f
    str x4, [x19, #FS_CURSOR]
    str x4, [sp, #-16]!
    tbnz x0, #63, 2f
    add x9, x19, #FS_CELLS
    ldrh w1, [x9, x0, lsl #1]
    mov w2, #0
    bl fb_draw
2:
    ldr x0, [sp], #16
    add x9, x19, #FS_CELLS
    ldrh w1, [x9, x0, lsl #1]
    mov w2, #1
    bl fb_draw
1:
    unframe

// x0 = cell index, w1 = character | attribute << 8, w2 = 1 to add the
// underline cursor (rows 14 and 15). Leaf; uses x0-x15.
fb_draw:
    ldr x3, [x19, #FS_COLS]
    udiv x4, x0, x3             // row
    msub x5, x4, x3, x0         // column
    ldr x6, [x19, #FS_STRIDE]
    ldr x7, [x19, #FS_ORIGIN]
    lsl x8, x6, #4
    madd x7, x4, x8, x7
    add x7, x7, x5, lsl #5      // 8 pixels of 4 bytes per column
    add x8, x19, #FS_PALETTE
    ubfx x9, x1, #8, #4
    ldr w4, [x8, x9, lsl #2]    // foreground
    ubfx x9, x1, #12, #4
    ldr w5, [x8, x9, lsl #2]    // background
    address x8, fbcon_font
    and x9, x1, #0xff
    add x8, x8, x9, lsl #4
    mov x3, #0
1:
    ldrb w9, [x8, x3]
    cbz w2, 2f
    cmp x3, #14
    b.lo 2f
    mov w9, #0xff
2:
    tst w9, #0x80
    csel w10, w4, w5, ne
    tst w9, #0x40
    csel w11, w4, w5, ne
    tst w9, #0x20
    csel w12, w4, w5, ne
    tst w9, #0x10
    csel w13, w4, w5, ne
    stp w10, w11, [x7]
    stp w12, w13, [x7, #8]
    tst w9, #0x08
    csel w10, w4, w5, ne
    tst w9, #0x04
    csel w11, w4, w5, ne
    tst w9, #0x02
    csel w12, w4, w5, ne
    tst w9, #0x01
    csel w13, w4, w5, ne
    stp w10, w11, [x7, #16]
    stp w12, w13, [x7, #24]
    add x7, x7, x6
    add x3, x3, #1
    cmp x3, #16
    b.lo 1b
    ret

// ---------------------------------------------------------------------------
// Finding the screen.

// Before ExitBootServices: record the first GOP framebuffer we can draw on.
fbcon_capture:
    enter
    sub sp, sp, #32             // handle count, handle buffer, interface
    address x19, fbcon_state
    str xzr, [x19, #FS_BASE]
    address x20, boot_services
    ldr x20, [x20]
    mov x0, #2                  // ByProtocol
    address x1, fbcon_gop_guid
    mov x2, #0
    mov x3, sp
    add x4, sp, #8
    ldr x5, [x20, #312]         // LocateHandleBuffer
    blr x5
    cbnz x0, 9f
    ldr x21, [sp]
    ldr x22, [sp, #8]
    cbz x22, 9f
    cmp x21, #16                // more than any machine has
    mov x2, #16
    csel x21, x2, x21, hi
    mov x23, #0
1:
    cmp x23, x21
    b.hs 8f
    ldr x0, [x22, x23, lsl #3]
    address x1, fbcon_gop_guid
    add x2, sp, #16
    ldr x5, [x20, #152]         // HandleProtocol
    blr x5
    cbnz x0, 2f
    ldr x0, [sp, #16]
    bl fbcon_gop_mode
    cbz x0, 8f
2:
    add x23, x23, #1
    b 1b
8:
    mov x0, x22
    ldr x5, [x20, #72]          // FreePool
    blr x5
9:
    add sp, sp, #32
    leave

// x0 = EFI_GRAPHICS_OUTPUT_PROTOCOL. Returns x0 = 0 when its current mode
// has a usable linear framebuffer (recorded in fbcon_state).
fbcon_gop_mode:
    cbz x0, 9f
    ldr x6, [x0, #24]           // Mode
    cbz x6, 9f
    ldr x7, [x6, #8]            // Info
    cbz x7, 9f
    ldr w5, [x7, #12]           // PixelFormat
    cmp w5, #1
    b.ls 2f                     // 0 RGB-reserved, 1 BGR-reserved
    cmp w5, #2                  // a bit mask: accept the same two layouts
    b.ne 9f
    ldr w1, [x7, #20]           // green mask
    mov w4, #0xff00
    cmp w1, w4
    b.ne 9f
    ldr w1, [x7, #16]           // red mask
    ldr w2, [x7, #24]           // blue mask
    mov w3, #0xff0000
    mov w4, #0xff
    mov w5, #0
    cmp w1, w4
    ccmp w2, w3, #0, eq
    b.eq 2f
    mov w5, #1
    cmp w1, w3
    ccmp w2, w4, #0, eq
    b.ne 9f
2:
    ldr x0, [x6, #24]           // FrameBufferBase
    ldr x1, [x6, #32]           // FrameBufferSize
    ldr w2, [x7, #4]            // HorizontalResolution
    ldr w3, [x7, #8]            // VerticalResolution
    ldr w4, [x7, #32]           // PixelsPerScanLine
    lsl x4, x4, #2
    b fbcon_accept
9:
    mov x0, #1
    ret

// x0 = base, x1 = size, x2 = width, x3 = height, x4 = bytes per line,
// x5 = format. Validates and records them; returns x0 = 0 when usable.
fbcon_accept:
    cbz x0, 9f
    tst x0, #3
    b.ne 9f
    cmp x2, #8
    b.lo 9f
    cmp x3, #16
    b.lo 9f
    mov x6, #8192
    cmp x2, x6
    b.hi 9f
    cmp x3, x6
    b.hi 9f
    tst x4, #3
    b.ne 9f
    cmp x4, x2, lsl #2
    b.lo 9f
    cmp x4, #0x10000
    b.hi 9f
    mul x6, x4, x3
    cmp x6, x1
    b.hi 9f
    address x9, fbcon_state
    str x0, [x9, #FS_BASE]
    str x1, [x9, #FS_SIZE]
    str x2, [x9, #FS_WIDTH]
    str x3, [x9, #FS_HEIGHT]
    str x4, [x9, #FS_STRIDE]
    str x5, [x9, #FS_FORMAT]
    mov x0, #0
    ret
9:
    mov x0, #1
    ret

// After ExitBootServices: start the console on the captured GOP, or on a
// Raspberry Pi (UART in the 3F000000h or FE000000h peripheral window) ask
// the VideoCore firmware for a framebuffer.
fbcon_start:
    frame
    address x9, fbcon_state
    ldr x0, [x9, #FS_BASE]
    cbnz x0, 1f
    ldv x0, plat_uart
    lsr x1, x0, #24
    cmp x1, #0x3f               // Pi 3 (BCM2837)
    b.eq 2f
    cmp x1, #0xfe               // Pi 4 (BCM2711)
    b.ne 9f
2:
    and x0, x0, #0xff000000
    bl fbcon_mailbox
    cbnz x0, 9f
1:
    // The kernel's own tables map non-RAM as Device memory: make the
    // framebuffer Normal non-cacheable (write-combining). No-op without them.
    address x9, fbcon_state
    ldr x0, [x9, #FS_BASE]
    ldr x1, [x9, #FS_SIZE]
    add x1, x0, x1
    bl mmu_map_normal_nc
    bl fbcon_setup
9:
    unframe

// Lay out the text grid, convert the palette, clear the whole screen and
// switch the console on.
fbcon_setup:
    frame
    stp x19, x20, [sp, #-16]!
    address x19, fbcon_state
    ldr x2, [x19, #FS_WIDTH]
    ldr x3, [x19, #FS_HEIGHT]
    lsr x4, x2, #3
    mov x5, #FB_COLS_MAX
    cmp x4, x5
    csel x4, x5, x4, hi
    lsr x6, x3, #4
    mov x5, #FB_ROWS_MAX
    cmp x6, x5
    csel x6, x5, x6, hi
    str x4, [x19, #FS_COLS]
    str x6, [x19, #FS_ROWS]
    sub x7, x2, x4, lsl #3      // spare pixels across
    lsr x7, x7, #1
    bic x7, x7, #1              // even pixel offset (stores stay 4-byte aligned)
    sub x8, x3, x6, lsl #4
    lsr x8, x8, #1
    ldr x0, [x19, #FS_BASE]
    ldr x1, [x19, #FS_STRIDE]
    madd x0, x8, x1, x0
    add x0, x0, x7, lsl #2
    str x0, [x19, #FS_ORIGIN]
    // CGA palette as 00RRGGBBh: that is BGRx in memory; swap for RGBx.
    address x5, fbcon_cga_rgb
    add x6, x19, #FS_PALETTE
    ldr x7, [x19, #FS_FORMAT]
    mov x8, #0
1:
    ldr w0, [x5, x8, lsl #2]
    cbnz x7, 2f
    rev w0, w0                  // 00RRGGBB -> BBGGRR00
    lsr w0, w0, #8              // -> 00BBGGRR
2:
    str w0, [x6, x8, lsl #2]
    add x8, x8, #1
    cmp x8, #16
    b.lo 1b
    // Black screen, every cell a blank in light grey on black.
    ldr x0, [x19, #FS_BASE]
    ldr x1, [x19, #FS_STRIDE]
    ldr x2, [x19, #FS_WIDTH]
    ldr x3, [x19, #FS_HEIGHT]
3:
    mov x4, #0
4:
    str wzr, [x0, x4, lsl #2]
    add x4, x4, #1
    cmp x4, x2
    b.lo 4b
    add x0, x0, x1
    subs x3, x3, #1
    b.ne 3b
    add x0, x19, #FS_CELLS
    mov w1, #0x0720
    mov x2, #(FB_COLS_MAX * FB_ROWS_MAX)
5:
    strh w1, [x0], #2
    subs x2, x2, #1
    b.ne 5b
    mov x0, #-1
    str x0, [x19, #FS_CURSOR]
    str xzr, [x19, #FS_COL]
    str xzr, [x19, #FS_ROW]
    str xzr, [x19, #FS_SAVE_COL]
    str xzr, [x19, #FS_SAVE_ROW]
    str xzr, [x19, #FS_ESC]
    str xzr, [x19, #FS_REVERSE]
    mov x0, #0x07
    str x0, [x19, #FS_ATTR]
    mov x0, #1
    str x0, [x19, #FS_ACTIVE]
    bl fb_show_cursor
    ldp x19, x20, [sp], #16
    unframe

// x0 = peripheral base (3F000000h Pi 3, FE000000h Pi 4). Asks the
// VideoCore firmware (mailbox 0, property channel 8) for a 640x480 32-bit
// framebuffer. Returns x0 = 0 with it recorded in fbcon_state. Not run on
// hardware yet; QEMU raspi3b emulates this interface (make fb-test).
fbcon_mailbox:
    enter
    add x19, x0, #0xb000
    add x19, x19, #0x880        // mailbox registers
    address x20, fbcon_mbox
    lsr x1, x20, #30            // the VideoCore sees only the first GiB
    cbnz x1, 9f
    address x1, fbcon_mbox_request
    mov x2, #0
1:
    ldr w3, [x1, x2]
    str w3, [x20, x2]
    add x2, x2, #4
    cmp x2, #FB_MBOX_BYTES
    b.lo 1b
    mov x0, x20                 // to memory, where the VideoCore reads it
    bl fbcon_mbox_flush
    orr w21, w20, #0xc0000000   // bus address (uncached alias) | channel 8
    orr w21, w21, #8
    mov x3, #0x100000
2:
    ldr w2, [x19, #0x38]        // write mailbox status: wait while full
    tbz w2, #31, 3f
    subs x3, x3, #1
    b.ne 2b
    b 9f
3:
    str w21, [x19, #0x20]       // write register
    mov x3, #0x1000000
4:
    ldr w2, [x19, #0x18]
    tbnz w2, #30, 5f            // empty
    ldr w2, [x19]               // read register
    and w4, w2, #0xf
    cmp w4, #8
    b.eq 6f
5:
    subs x3, x3, #1
    b.ne 4b
    b 9f
6:
    mov x0, x20
    bl fbcon_mbox_flush         // drop stale lines before reading the answer
    ldr w2, [x20, #4]
    mov w3, #0x80000000
    cmp w2, w3
    b.ne 9f
    ldr w2, [x20, #(20 * 4)]    // depth granted
    cmp w2, #32
    b.ne 9f
    ldr w0, [x20, #(28 * 4)]    // buffer bus address
    and w0, w0, #0x3fffffff
    ldr w1, [x20, #(29 * 4)]    // size
    ldr w2, [x20, #(5 * 4)]     // width
    ldr w3, [x20, #(6 * 4)]     // height
    ldr w4, [x20, #(33 * 4)]    // pitch
    cbnz w1, 7f
    mul w1, w4, w3
7:
    ldr w5, [x20, #(24 * 4)]    // pixel order: 1 RGB (byte 0 red), 0 BGR
    cmp w5, #1
    cset x5, ne
    bl fbcon_accept
    leave
9:
    mov x0, #1
    leave

// x0 = fbcon_mbox: clean and invalidate its cache lines (harmless with the
// caches off).
fbcon_mbox_flush:
    mov x1, #0
1:
    add x2, x0, x1
    dc civac, x2
    add x1, x1, #16
    cmp x1, #FB_MBOX_BYTES
    b.lo 1b
    dsb sy
    ret

// E2h (ARM DOS extension): console and screen information.
// x0 = 0: returns x0 = 1 with a screen (0 serial only), x2 columns, x3 rows,
// x4 width and x5 height in pixels (all 0 without a screen).
fbcon_dos_info:
    cbnz x0, dos_call_invalid
    address x9, fbcon_state
    ldr x0, [x9, #FS_ACTIVE]
    mov x2, #0
    mov x3, #0
    mov x4, #0
    mov x5, #0
    cbz x0, 1f
    ldr x2, [x9, #FS_COLS]
    ldr x3, [x9, #FS_ROWS]
    ldr x4, [x9, #FS_WIDTH]
    ldr x5, [x9, #FS_HEIGHT]
1:
    mov x1, #0
    ret

.section .rodata
.balign 4
fbcon_gop_guid:                 // EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID
    .long 0x9042a9de
    .short 0x23dc, 0x4a38
    .byte 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a
fbcon_cga_rgb:
    .long 0x000000, 0x0000aa, 0x00aa00, 0x00aaaa, 0xaa0000, 0xaa00aa, 0xaa5500, 0xaaaaaa
    .long 0x555555, 0x5555ff, 0x55ff55, 0x55ffff, 0xff5555, 0xff55ff, 0xffff55, 0xffffff
fbcon_ansi_cga: .byte 0, 4, 2, 6, 1, 5, 3, 7     // ANSI colour -> CGA colour
.balign 4
// Mailbox property request (word indices are read back in fbcon_mailbox).
fbcon_mbox_request:
    .long 35 * 4, 0
    .long 0x48003, 8, 0, 640, 480   // set physical size      [2..6]
    .long 0x48004, 8, 0, 640, 480   // set virtual size       [7..11]
    .long 0x48009, 8, 0, 0, 0       // set virtual offset     [12..16]
    .long 0x48005, 4, 0, 32         // set depth              [17..20]
    .long 0x48006, 4, 0, 1          // set pixel order RGB    [21..24]
    .long 0x40001, 8, 0, 4096, 0    // allocate buffer        [25..29]
    .long 0x40008, 4, 0, 0          // get pitch              [30..33]
    .long 0                         // end tag                [34]
    .long 0                         // pad to 16 bytes

.section .bss
.balign 16
fbcon_mbox: .skip FB_MBOX_BYTES
.balign 16
fbcon_state:
fbcon_active: .skip FS_BYTES

.include "src/font8x16.S"
