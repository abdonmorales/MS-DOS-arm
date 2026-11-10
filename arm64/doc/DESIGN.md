# MS-DOS for AArch64 — design

A port of MS-DOS 2.x (reference sources: `v2.0/source`) to 64-bit ARM.
The original is 8086 assembly built around segments and software
interrupts, so the port is a re-implementation in C (plus a little
AArch64 assembly) that keeps DOS's structure, system-call interface,
on-disk formats, command set and messages.

Target machine: QEMU `virt` (PL011 UART, PL031 RTC, virtio-mmio block,
generic timer, PSCI). Toolchain: clang/lld (`--target=aarch64-none-elf`).

## Layers (who owns what)

| Directory | DOS equivalent | Contents |
|-----------|----------------|----------|
| `include/dos/abi.h` | — | **Contract**: syscall ABI, PSP, executable format |
| `include/bios.h` | — | **Contract**: machine layer ⇄ kernel |
| `bios/` | IO.SYS / IBMBIO | boot, EL1 vectors, trap frames, UART, disk, clock |
| `dos/` | MSDOS.SYS | INT 21h, FAT12/16, handles, memory arena, EXEC |
| `lib/` | (C runtime) | crt0, `user.ld`, libc subset, DOS call wrappers |
| `cmd/command/` | COMMAND.COM | the shell |
| `cmd/<name>/` | external commands | CHKDSK, FORMAT, MORE, SORT, FIND, EDLIN, DEBUG… |
| `tools/` | — | host tools (`mkdisk.py` builds the FAT image) |
| `tests/` | — | host unit tests and scripted QEMU boot tests |
| `disk/` | — | files copied verbatim to the boot disk root |

## Key decisions

* `INT n` → `svc #n` from EL0; 8086 registers map onto x0–x5, CF/ZF onto
  PSTATE.C/Z (see `abi.h`). Segment:offset pairs become flat pointers.
* No MMU, flat physical memory, one kernel stack, no preemption — like DOS.
* Process switch = the kernel overwrites the trap frame (EXEC saves the
  parent's frame; EXIT restores it).
* Programs are flat position-independent images with a 32-byte header
  that relocate themselves; `.COM` and `.EXE` are the same format.
* Drives: BIOS unit 0 = A: (boot), unit 1 = B:, … Each disk is a plain FAT12
  or FAT16 volume with the BPB in sector 0 (an MBR partition table is also
  accepted: the first FAT partition is used).
* Text conventions are DOS's: CR LF line ends, ^Z ends text files, Enter
  arrives as CR, `\` path separator (`/` also accepted by the kernel),
  switch character `/`.
* Screen control uses ANSI escape sequences (the serial console is the
  "ANSI.SYS" device).

## User library contract (`lib/include`)

Programs are freestanding C. `main(int argc, char **argv)` is called by
crt0 with arguments parsed from the PSP command tail; `argv[0]` is "".
Provided headers (standard semantics unless noted):

* `dos.h` — `struct dosregs { uint64_t x0,x1,x2,x3,x4,x5; uint32_t flags; }`;
  `int int21(struct dosregs *r)` (returns nonzero if CF set; flags has
  `DOS_CF`/`DOS_ZF`), `int intdos(unsigned intno, struct dosregs *r)` for
  12h/20h/25h/26h; `extern struct dos_psp *_psp;` and typed wrappers named
  `dos_<function>`: `dos_open(path, mode)`, `dos_creat(path, attr)`,
  `dos_close(h)`, `dos_read(h, buf, n)`, `dos_write(h, buf, n)`,
  `dos_lseek(h, off, whence)`, `dos_unlink(path)`, `dos_rename(old, new)`,
  `dos_mkdir`, `dos_rmdir`, `dos_chdir`, `dos_getcwd(drive, buf)`,
  `dos_findfirst(pattern, attr, struct dos_dta *)`, `dos_findnext(dta)`,
  `dos_getattr(path)`, `dos_setattr(path, attr)`, `dos_getdrive()`,
  `dos_setdrive(d)` (0 = A:), `dos_exec(path, cmdtail, env)`, `dos_wait()`
  (AH=4Dh), `dos_alloc(paragraphs, void **)`, `dos_free(p)`,
  `dos_absread(drive, lba, count, buf)`, `dos_abswrite(...)`,
  `dos_ioctl_getinfo(h)`. Wrappers return ≥0 on success and `-errorcode`
  on failure. Anything not covered goes through `int21()` directly.
  `dos.h` includes `dos/abi.h`.
* `stdio.h` — `printf fprintf sprintf snprintf vsnprintf puts fputs putchar
  fputc getchar fgetc fgets fopen fclose fread fwrite fseek ftell fflush
  feof stdin stdout stderr`. Streams are binary; nothing translates
  `\n`, so programs write `"\r\n"` themselves (`puts` appends CR LF).
* `stdlib.h` — `malloc calloc realloc free exit abort atoi atol strtol
  strtoul qsort getenv abs`.
* `string.h` — the usual `mem*`/`str*` set incl. `strchr strrchr strstr
  strncmp strcasecmp strncasecmp strdup strtok`.
* `ctype.h`, `setjmp.h`, `stdarg.h`, `stdint.h`, `stddef.h`, `stdbool.h`,
  `limits.h`, `errno.h`.
