# Programming ARM DOS

This guide is for writing native programs and drivers for ARM DOS. ARM DOS
programs are AArch64 machine code in PE32+ files; they call DOS through a
function pointer instead of `INT 21h`. Every DOS function, its registers
and its limits are listed in [ABI.md](../ABI.md); this guide explains how
the pieces fit together and does not repeat that table.

Everything in the repository is written in assembly, and the build uses
only GNU binutils and Python. There is no C runtime or C toolchain support
for ARM DOS programs; nothing stops you from producing a compatible image
with another toolchain, but none is provided or tested.

## Toolchain

You need GNU AArch64 binutils (`as`, `ld`, `objcopy`, `nm`), Python 3 and
Make. On Debian or Ubuntu:

```sh
sudo apt-get install binutils-aarch64-linux-gnu python3 make mtools dosfstools qemu-system-arm qemu-efi-aarch64
```

On a Mac, `brew install aarch64-elf-binutils` and pass
`CROSS_COMPILE=aarch64-elf-` to `make`. The README's
[Building](../README.md#building) section has the details.

A program is built in four steps, exactly as the Makefile does for
`programs/NAME.S`:

```sh
aarch64-linux-gnu-as -march=armv8-a -g -I programs -o build/hello.o hello.S
aarch64-linux-gnu-ld -T link.ld --no-undefined -o build/hello.elf build/hello.o
aarch64-linux-gnu-objcopy -O binary build/hello.elf build/hello.bin
python3 tools/pe.py --nm aarch64-linux-gnu-nm build/hello.elf build/hello.bin build/HELLO.EXE
```

- `link.ld` links the code at RVA `0x1000`: `.text` and `.rodata` in one
  read/execute segment, then `.data` and `.bss` from the next 4 KiB page.
  The entry symbol is `efi_main`.
- `tools/pe.py` wraps the flat binary in a PE32+ header (machine `0xaa64`,
  three sections `.text`, `.data`, `.reloc`). It needs the symbols
  `efi_main`, `__data_start`, `__file_end` and `__image_end`, which
  `link.ld` defines.

## What the loader accepts

The kernel's own loader (`pe_load` in `src/process.S`) accepts a file
that:

- is at least 512 bytes and starts with `MZ`, with `e_lfanew` inside the
  file pointing at `PE\0\0`;
- has machine `0xAA64` and optional-header magic `0x20B` (PE32+);
- has a `SizeOfImage` of at least 4 KiB and at most 16 MiB;
- has `SizeOfHeaders` and every section's raw data inside the file, and
  every section inside `SizeOfImage`;
- has, if it has a base relocation directory, blocks that lie inside the
  image and contain only `IMAGE_REL_BASED_ABSOLUTE` (padding) and
  `IMAGE_REL_BASED_DIR64` entries whose targets lie inside the image;
- has an entry point inside the image.

Anything else fails with DOS error 11 (invalid format), so an x86 `.EXE`
is refused cleanly; an image too large for free memory fails with DOS
error 8 (insufficient memory). The loader copies the headers and sections into a
fresh 64 KiB-aligned block, zero-fills the rest, applies the DIR64
relocations for the new base, synchronises the instruction cache and calls
the entry point.

Because the block is 64 KiB aligned, page offsets are preserved and
`adrp`/`add` pairs work. Code built with `link.ld` is position independent
and needs no relocations; `pe.py` writes an empty relocation block. Never
store absolute addresses in `.data` at assembly time (`.quad label`),
because they would not be relocated; compute addresses at run time with
`adrp`/`add` (the `address` macro in `lib.inc`).

## Entry, exit and the process descriptor

The entry point is called with `x0` pointing to a 64-byte process
descriptor (signature `ARMDOS64`, version, the DOS service pointer at +24,
the command tail at +32, the environment at +40, the current directory at
+48 and the process id at +56; layout in [ABI.md](../ABI.md#program-entry-and-api-discovery)).
The descriptor is valid only during the call to the entry point.

- **Calling DOS:** put the function number in `w8`, arguments in `x0`
  onwards, and `blr` to the pointer at descriptor +24. On return `x1` is
  0 for success or 1 for an error, with the DOS error code in `x0`
  (functions that return status differently say so in ABI.md). A call may
  clobber `x0`-`x18`, the flags and the caller-saved vector registers.
- **Registers:** standard AAPCS64. Preserve `x19`-`x28`, `x29`, `x30`
  where required and `sp`, and keep `sp` 16-byte aligned.
- **Exit:** call `4Ch` with the exit code in `x0` (it does not return), or
  return from the entry point, which ends the program with exit code 0.
  The low byte of the exit code becomes ERRORLEVEL. `31h` ends the program
  and keeps it resident.
- **Faults:** a CPU exception in a program ends it with termination type 2
  (`4Dh` reports it); the shell continues.

## Memory model

ARM DOS keeps the DOS model, translated to 64 bits:

- **One flat address space, no protection.** Programs run at the same
  privilege level as the kernel (the exception level the firmware started
  it at, EL1 or EL2), in the firmware's identity-mapped address space; the
  kernel never changes the page tables, and there is no per-process
  address space. A program can read or overwrite the kernel and other programs,
  exactly as a real-mode DOS program could. See [SECURITY.md](../SECURITY.md).
- **Image:** loaded into its own block from the kernel's memory arena. The
  image base is the process id (descriptor +56) and the owner of
  everything the program allocates or opens.
- **Heap:** `48h` allocates, `49h` frees and `4Ah` resizes. Requests are
  rounded up to 64 KiB granules, the largest request is 16 MiB, and a
  resize happens in place within the block's reserved capacity (blocks
  never move). `58h` selects first, best or last fit.
- **Stack:** a program runs on the stack of its caller. Keep large buffers
  in `.bss` (zero-filled at load) or in allocated memory, not on the stack.
- **Cleanup:** when a program ends, the kernel frees its memory blocks,
  closes its files, searches and locks, and restores the parent's DTA and
  vectors. A resident program (`31h`) keeps its image and blocks.
- In native mode the arena is a fixed block reserved at boot (`MEM` shows
  its size: 32 MiB under QEMU); in firmware mode UEFI places the pages.

## Files, handles and FCBs

ARM DOS has both DOS file interfaces:

- **Handles** (`3Ch`-`46h`, `5Ah`-`5Ch`, `67h`-`6Ch`): handles 0-4 start as
  standard input, output, error, AUX and PRN; up to 32 handles per process
  (`67h`); open modes include the sharing modes, and SHARE-style locking
  (`5Ch`) is built in. Paths are ASCIIZ, up to 255 characters, with long
  names allowed.
- **FCBs** (`0Fh`-`17h`, `21h`-`24h`, `27h`-`29h`): the standard 37-byte FCB
  and the extended FCB, with 8.3 names only.
- **Searches:** `4Eh`/`4Fh` fill a DTA of at least 280 bytes with a 64-bit
  layout (attributes, size, time, date, 256-byte name), not DOS's 43-byte
  layout. Set the DTA with `1Ah` (pointer and capacity).
- **Devices:** `CON`, `AUX`, `PRN`, `NUL`, `CLOCK$` and installed device
  names open like files.

Every write goes through to the disk before the call returns. The layouts
of the DTA, FCB, DPB, list of lists (`52h`) and drive table are in ABI.md.

### Differences from DOS for programmers

- No `INT 21h`, no segment registers, no PSP: the descriptor replaces the
  PSP, and `26h`/`55h`/`62h` work with descriptors.
- `0Ah` buffered input, `09h` (`$`- or NUL-terminated) and the console
  calls keep their DOS behaviour.
- Vectors set with `25h` are plain function pointers. Only 22h, 23h
  (called on Ctrl-C) and 24h have a meaning; there are no hardware
  interrupts to hook.
- Network, IFS and CP/M functions return the "no network" results listed in
  ABI.md.

## ARM DOS extension functions

ARM DOS adds one function above the DOS range:

- **`E0h`, raw disk services.** It stands in for `INT 13h` so that
  `INSTALL.EXE` can partition and format a whole disk. Subfunctions 0-6
  enumerate the firmware's disks (never the boot disk), report geometry,
  read and write blocks, attach a partition as a drive letter, flush, and
  probe. It works only while UEFI boot services are available (firmware
  mode, such as the live ISO); under the native kernel subfunction 0 finds
  no disks. See [ABI.md](../ABI.md#disk-services-e0h-arm-dos-extension).

IOCTL `440Dh` also has ARM DOS minor codes (`0860h` geometry, `0840h`
re-read the boot record, `0861h`/`0841h` read and write sectors) that
replace `INT 25h`/`26h` for CHKDSK, FORMAT, SYS, LABEL and RECOVER. Any
other number above `6Ch` returns error 1.

## The utility runtime, programs/lib.inc

`programs/lib.inc` is the small runtime every utility includes. It
provides:

- the entry point `efi_main`, which saves the descriptor and the DOS
  pointer, calls your **`main` with `x0` = the command tail**, and ends the
  program with `4Ch` using `main`'s return value as the exit code;
- macros: `address reg, symbol` (load an address), `dos fn` (call DOS
  function `fn`), `enter`/`leave` (a frame saving `x19`-`x28`),
  `frame`/`unframe` (a frame saving only `x29`, `x30`), and
  `say "text"` (print a literal);
- strings: `strlen`, `strcpy`, `strcat`, `strcmp`, `strcmpi`, `strupr`,
  `toupper`, `skip_blanks`, `rtrim`, `strstr`, `basename`, `has_wild`;
- arguments and numbers: `next_arg` (splits the tail, with quotes and
  `/` switches), `parse_dec`, `utoa`;
- output: `puts`, `eputs` (to standard error), `putc`, `write_out`, `crlf`,
  `spaces`, `put_dec`, `put_dec0`, `put_dec_commas`, `put_hex`,
  `print_error` (DOS error message);
- files: `fopen`, `fcreate`, `fclose`, `fread`, `fwrite`, `fseek`, and a
  buffered line reader (`lr_init`, `lr_getline`, `lr_binary`);
- environment and paths: `get_environment`, `getenv`, `is_directory`,
  `join_path`, `path_drive_letter`, `apply_template` (DOS rename
  templates);
- console: `read_console_line`, `ask_yn`, `press_any_key`.

Library routines follow AAPCS64 but clobber only `x0`-`x17`. The comment
above each routine in `lib.inc` gives its arguments and results. Include
`lib.inc` first, before any code of your own.

`lib.inc` does not check the descriptor's signature; a program that does
not use it should check `ARMDOS64` and version 1 before using the pointers,
as [programs/native.S](../programs/native.S) does.

## A complete example: HELLO.EXE

```asm
// SPDX-License-Identifier: MIT
// HELLO [name]: greets the name given on the command line, or the world.
.include "lib.inc"

main:                           // x0 = command tail (NUL-terminated)
    enter
    bl skip_blanks
    mov x19, x0
    say "Hello, "
    ldrb w1, [x19]
    cbnz w1, 1f
    address x19, world
1:
    mov x0, x19
    bl puts
    say "!\r\n"
    // A raw DOS call: 2Ah returns the date (x0 year, x2 month, x3 day).
    dos 0x2a
    mov x19, x0
    say "The year is "
    mov x0, x19
    mov x1, #0
    bl put_dec
    bl crlf
    mov x0, #0                  // exit code (ERRORLEVEL)
    leave

.section .rodata
world: .asciz "world"
```

Build it by hand with the four commands under [Toolchain](#toolchain), then
copy it onto a disk image and boot it. The test image's FAT partition
starts 1 MiB into the file:

```sh
make image
MTOOLS_SKIP_CHECK=1 mcopy -i build/msdos-arm64.img@@1M build/HELLO.EXE ::/HELLO.EXE
python3 tools/run.py build/msdos-arm64.img
```

```
A:\>hello
Hello, world!
The year is 2026
A:\>hello ARM DOS
Hello, ARM DOS!
The year is 2026
A:\>hello > H.TXT
A:\>type H.TXT
Hello, world!
The year is 2026
```

(This transcript is from the smoke-test console harness, booting the test
image under QEMU.)

## Adding a program to the build

The build finds programs by name, so adding one takes no Makefile edits:

1. Save the source as `programs/hello.S` (lower case).
2. Run `make`. The pattern rules build `build/HELLO.EXE`, and
   `tools/payloads.py` adds it to the payload list, so `make image` and
   `make iso` put it in the root of A:.
3. If it includes a new `.inc` file, add that file to the prerequisites of
   the `$(BUILD)/%.o: programs/%.S` rule in the Makefile, so changes to it
   cause a rebuild.
4. Add checks for it to `tools/smoke.py` (a `command('hello', b'Hello,')`
   line is the simplest), and run `make smoke`.

A program that is only for testing should also be listed in `TEST_ONLY` in
`tools/release.py`, which keeps it off the live ISO and the ROM builds.

## Writing an installable driver

A driver is built exactly like a program, from `drivers/name.S` (lower case) to
`build/NAME.SYS`, and loaded with `DEVICE=\NAME.SYS args` in `CONFIG.SYS`.
It stays resident. Its entry point is called once with `x0` pointing to a
96-byte init request (the full table is in
[ABI.md](../ABI.md#configsys-and-installable-device-drivers)):

- in: `dos_call` at +0, the argument string at +8, the drive the unit will
  get at +64 (block devices), and `putc`/`poll` for the console UART at +72
  and +80;
- out: the device name at +16 (up to 7 characters), `read` at +24, `write`
  at +32, the device information word at +40, and for a block device the
  total sectors at +48 and the sector size at +56.

Return `x1 = 0` to install or `x1 = 1` to refuse.

- A **character device** sets `read(x0 buffer, x1 count)` and
  `write(x0 buffer, x1 count)`, each returning the bytes moved in `x0`
  (read returns 0 at end of file). Either may be left 0. Its name then opens
  like a file from any directory. A driver named `CON`, `AUX`, `PRN`, `NUL`
  or `CLOCK$` takes over that device: `ANSI.SYS` takes over `CON`,
  `PRINTER.SYS` takes over `PRN`.
- A **block device** sets a nonzero sector count at +48 and puts
  `rw(x0 sector, x1 buffer, x2 count, x3 0 read / 1 write)` at +24,
  returning `x0 = 0` on success. It gets the next free drive letter up to
  `LASTDRIVE`, and the kernel mounts the FAT volume on it (or leaves it for
  FORMAT).
- A driver that replaces `CON` must not call DOS from `read` or `write`:
  it writes to the terminal with `putc` (+72) and reads keys with the
  non-blocking `poll` (+80). Its `read` is asked for one key at a time and
  returns 0 when none is waiting.

Up to 11 drivers can be loaded. The smallest example is
[drivers/testdrv.S](../drivers/testdrv.S), a 100-line character device
that stores what is written to `UPPER$` and reads it back in upper case.
`drivers/ramdisk.inc` (shared by `RAMDRIVE.SYS` and `VDISK.SYS`) is a
complete block device, and `drivers/ansi.S` a full `CON` replacement.
Drivers do not include `programs/lib.inc`: it defines the program entry
point `efi_main`, and a driver needs its own. Each driver defines the few
macros it needs (`address` and so on) itself, as the drivers in
`drivers/` do. A new `drivers/NAME.S` is picked up by the build and the
images like a new program; if it includes a new `.inc` file, add that to
the `$(BUILD)/%.o: drivers/%.S` rule's prerequisites.

## Testing

- `make unit` runs kernel routines in the Unicorn emulator and checks that
  the dispatch table matches ABI.md.
- `make smoke` boots the test image in QEMU and types about 330 commands
  at the console, checking each answer; `tools/smoke.py` is also the model
  for driving the console from a script.
- `DOSTEST.EXE` (`programs/dostest.S`) exercises the whole DOS function
  set from a separately loaded program and is a large source of examples
  for individual calls.
