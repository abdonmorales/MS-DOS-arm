# ARM DOS C SDK

Write native ARM DOS programs in C. The operating system itself stays
assembly; this directory gives application developers a header for the
[native ABI](../ABI.md), a C runtime start-up file and a small freestanding
C library, all MIT licensed (no GPL code; the only outside headers used are
GCC's own `stddef.h`, `stdint.h`, `stdarg.h` and `stdbool.h`).

| Path | Contents |
| --- | --- |
| `include/armdos.h` | The 64-byte descriptor, the service-call primitive and typed wrappers |
| `include/*.h` | `string.h`, `ctype.h`, `stdlib.h`, `stdio.h`, `errno.h`, `limits.h` |
| `crt/crt0.S`, `crt/start.c` | Program entry: descriptor check, `.bss`, stack, `argc`/`argv`, `environ`, `exit` |
| `lib/` | The library (`libarmdos.a`) |
| `link.ld`, `tools/elf2pe.py` | Linker script and the ELF to PE32+ converter that emits relocations |
| `examples/hello.c` | `HELLO.EXE`: arguments, environment, current directory, date |
| `examples/wc.c` | `WC.EXE`: line/word/byte counts with wildcards and a report file |
| `tests/libtest.c` | `LIBTEST.EXE`: ~330 library checks run inside ARM DOS by `make sdk-test` |

## Toolchain

Any AArch64 GCC works; the build uses only the compiler, `ar`, and Python 3.
On Debian or Ubuntu:

    sudo apt install gcc-aarch64-linux-gnu make python3 mtools qemu-system-arm qemu-efi-aarch64

(`mtools` and QEMU are only needed for `make sdk-test`.) A bare-metal
`aarch64-none-elf-gcc` also works: `make sdk CROSS_COMPILE=aarch64-none-elf-`.
The host C library is never used: the build passes `-nostdinc -nostdlib`.

## Building

From the repository root:

    make sdk         # build/sdk/libarmdos.a, crt0.o, HELLO.EXE, WC.EXE, LIBTEST.EXE
    make sdk-test    # also boots the test image in QEMU and runs them

or `make -C sdk BUILD=/some/dir`. Copy an `.EXE` onto an ARM DOS disk (for
example `mcopy -i build/msdos-arm64.img@@1M build/sdk/HELLO.EXE ::/`) and
run it from the prompt.

### Building your own program

Put a `.c` file in `examples/` and `make sdk` builds `NAME.EXE` from it. Or
by hand, with `SDK` pointing at this directory and `B` at the build output:

    CFLAGS="-O2 -std=gnu11 -ffreestanding -fno-builtin -nostdinc \
      -isystem $(aarch64-linux-gnu-gcc -print-file-name=include) -I$SDK/include \
      -fno-pic -fno-pie -mcmodel=small -mgeneral-regs-only -mno-outline-atomics \
      -fno-stack-protector -fno-asynchronous-unwind-tables"
    aarch64-linux-gnu-gcc $CFLAGS -c prog.c -o prog.o
    aarch64-linux-gnu-gcc -nostdlib -static -no-pie -Wl,-T,$SDK/link.ld \
      -Wl,--emit-relocs -o prog.elf $B/crt0.o prog.o $B/libarmdos.a
    python3 $SDK/tools/elf2pe.py prog.elf PROG.EXE

The flags matter:

- **`-fno-pic -mcmodel=small` and `--emit-relocs`.** The kernel loads an
  image at a 4 KiB-aligned address (observed: not always 64 KiB aligned),
  keeps page offsets, and applies PE `IMAGE_REL_BASED_DIR64` relocations.
  Code addresses everything with `ADRP`/`ADD`, which is position
  independent; only pointers stored in data (string tables, function
  pointer arrays, `FILE *stdout = &...`) need fixing. The program is linked
  for address 0 and `--emit-relocs` keeps the linker's `R_AARCH64_ABS64`
  records, which `elf2pe.py` turns into DIR64 fixups (plus GOT slots, which
  weak references use). Anything the loader cannot fix (`-mcmodel=large`
  literal addresses, `ABS32`, `MOVW_UABS`) is rejected with the symbol
  named. Do not use `tools/pe.py` for C: it writes no fixups.
- **`-mgeneral-regs-only`.** The library is built without floating point,
  so `printf` has no `%f`. Your own code may use floating point: the
  kernel never touches the SIMD/FP registers, UEFI leaves them enabled,
  and `armdos_call()` declares the caller-saved vector registers clobbered
  when FP is on. Pass doubles to your own code only, not to `printf`.
- **`-mno-outline-atomics`**, **`-fno-stack-protector`**: there is no libgcc
  and no TLS canary.
- **`-fno-tree-loop-distribute-patterns`** is used for the library itself,
  so GCC cannot turn `memset`'s loop into a call to `memset`.

## The ABI in C

The kernel calls the entry point (`_start`, in `crt0.S`) with `x0` = the
descriptor (`armdos_descriptor` in `armdos.h`). The start-up code:

1. checks the `ARMDOS64` signature, version 1 and size before using it
   (an invalid descriptor returns 1: the parent sees termination type 2);
2. zeroes `.bss` and saves the service pointer in `__armdos_service`;
3. allocates a 256 KiB private stack with `48h` (a program otherwise runs
   on the kernel's stack, whose size depends on the firmware). Define
   `const unsigned long __armdos_stack_size = N;` to change it, 0 to keep
   the inherited stack;
4. sets up `stdin`/`stdout`/`stderr`, copies the environment into `environ`
   (also `main`'s third argument) and splits the command tail into `argv`;
5. calls `main` and passes its result to `exit`, which runs `atexit`
   handlers, flushes streams and ends the program with `4Ch`. Never return
   a nonzero value from the entry point itself: the kernel reports that as
   termination type 2.

Every service goes through one inline-assembly primitive:

```c
armdos_regs r = { .x0 = handle, .x1 = (uintptr_t)buf, .x2 = n };
armdos_call(0x3f, &r);          /* w8 = 3Fh, blr __armdos_service */
if (r.x1 == 1) /* error: DOS code in r.x0 */;
```

`armdos_call` lists `x0`–`x18`, `x30`, the flags and memory as clobbered,
so the compiler keeps live values in `x19`–`x28` across calls, as the ABI
requires. The typed wrappers return a non-negative result or the negated
DOS error code: `dos_open("X.TXT", DOS_O_RDONLY)` gives a handle or `-2`.

| Area | Wrappers |
| --- | --- |
| Console | `dos_getche` (01h), `dos_getch` (07h), `dos_putch` (02h), `dos_direct_out`/`dos_direct_in` (06h), `dos_print` (09h), `dos_read_line` (0Ah), `dos_kbhit` (0Bh) |
| Files | `dos_create` 3Ch, `dos_open` 3Dh, `dos_close` 3Eh, `dos_read` 3Fh, `dos_write` 40h, `dos_delete` 41h, `dos_seek` 42h, `dos_get_attributes`/`dos_set_attributes` 43h, `dos_rename` 56h, `dos_get_file_time` 57h |
| Directories | `dos_mkdir` 39h, `dos_rmdir` 3Ah, `dos_chdir` 3Bh, `dos_getcwd` 47h, `dos_find_first`/`dos_find_next` 4Eh/4Fh with `dos_dta`, `dos_set_dta` 1Ah |
| Memory | `dos_alloc` 48h, `dos_free` 49h, `dos_resize` 4Ah |
| Processes | `dos_exec` 4Bh, `dos_exit` 4Ch, `dos_child_status` 4Dh |
| System | `dos_get_date`/`dos_set_date`/`dos_get_time`/`dos_set_time` 2Ah–2Dh, `dos_version` 30h, `dos_set_drive` 0Eh, `dos_get_drive` 19h, `dos_disk_free` 36h, IOCTL 44h (`dos_ioctl_get_info`, `dos_ioctl_set_info`, `dos_ioctl_ready`, `dos_ioctl`), `dos_get_ext_error` 59h, `dos_truename` 60h |

Anything else is one `armdos_call4(fn, x0, x1, x2, x3)` away.

## The C library

- `string.h`: `mem*`, `str*` (also `strcasecmp`, `strtok_r`, `strdup`,
  `strupr`), `strerror`. `ctype.h`: ASCII classes.
- `stdlib.h`: `malloc`/`calloc`/`realloc`/`free`, `strtol` family, `atoi`,
  `abs`, `div`, `qsort` (shell sort), `bsearch`, `rand`, `getenv`, `exit`,
  `atexit`, `abort`, and `spawn(path, tail)` (4Bh, returns the 4Dh status).
  The heap takes blocks from `48h`: 256 KiB first, doubling to 16 MiB,
  because the kernel has only 64 allocation slots for the whole system. One
  allocation is at most 16 MiB (minus 16 bytes). Memory goes back to DOS
  when the program ends.
- `stdio.h`: `printf`, `fprintf`, `sprintf`, `snprintf`, `v*` forms with
  `%d %i %u %o %x %X %c %s %p %n %%`, flags `-+ #0`, width and precision
  (also `*`), lengths `hh h l ll z j t`; `fopen` (`r w a` with `+`, `b`,
  `t`), `fdopen`, `freopen`, `fclose`, `fread`, `fwrite`, `fgetc`, `fgets`,
  `fputc`, `fputs`, `puts`, `getchar`, `putchar`, `ungetc` (one character),
  `fseek`, `ftell`, `rewind`, `fflush`, `setvbuf`, `remove`, `rename`,
  `perror`. Up to 20 streams.
- Text mode is the default, as with DOS C compilers: `"\n"` is written as
  CR LF, CR is dropped on input, Ctrl-Z ends a text file. `"b"` gives raw
  bytes. `ftell`/`fseek` work on raw file offsets in both modes. `stdout`
  is line buffered on the console and fully buffered when redirected;
  `stderr` is unbuffered. Reading the console flushes `stdout` first.
- `errno.h`: DOS errors map to errno (2 and 3 to `ENOENT`, 5/32/33 to
  `EACCES`, 6 to `EBADF`, 8 to `ENOMEM`, 80 to `EEXIST`, ...);
  `_doserrno` keeps the DOS code.

## Example walkthrough: WC.EXE

`examples/wc.c` counts lines, words and bytes:

    A:\>wc /L /O:REPORT.TXT *.TXT

1. `main` reads switches from `argv` (`/L`, `/O:file`) and passes each
   pattern to `expand`.
2. `expand` keeps the pattern's directory part and walks matches with
   `dos_find_first`/`dos_find_next` into a `dos_dta` on its stack; a
   failure becomes errno with `__armdos_seterrno` and is printed with
   `strerror`.
3. Each match is opened with `fopen(name, "rb")` and read with `fread` in
   2 KiB pieces; results live in an array grown with `realloc`, and the
   byte count is checked against the size the directory search reported.
4. The array is sorted with `qsort` and printed with `printf` field widths
   (`%7lu`, `%-12s`, `%zu`); with `/O:` the same report goes through
   `fprintf` to a text-mode file, so its lines end in CR LF.
5. `main` returns 0, 1 (a pattern matched nothing) or 2 (usage), which
   COMMAND sees as `ERRORLEVEL`.

`make sdk-test` runs it on the test disk and compares the report with
counts computed on the host.

## Limitations

- No floating point in the library (`%f` prints `?`), no `time.h`,
  `setjmp.h`, signals, locales or wide characters.
- `argv[0]` is empty unless the program defines
  `const char *__armdos_progname = "NAME";` (the descriptor carries no
  program name).
- Programs share one flat address space with the kernel at EL1, as DOS
  programs shared real mode: a stray pointer can corrupt the system. A CPU
  exception ends the program (termination type 2).
- The descriptor's pointers are borrowed from the kernel; the runtime
  copies the command tail and environment at start-up.
- Programs need a kernel that applies PE relocations (this tree; older
  kernels read the relocation directory count from the wrong offset and
  skip every fixup, so pointers in a C program's data stay unrelocated).
- Tested under QEMU `virt` in native and firmware modes; not on hardware.
  The SDK programs are not added to the release image.
