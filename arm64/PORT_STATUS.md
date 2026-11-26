# MS-DOS 4.0 AArch64 port: definition of done and status

This file is the checklist for "the port is finished". Each milestone lands
with tests that run in CI-style `make` targets (`smoke`, `validate`,
`fat-test`, and later ones listed below).

MS-DOS 4.0 is an 8086 operating system for IBM PC hardware. Porting it to
AArch64 means re-implementing its kernel, shell, drivers and utilities as
native ARM64 code with the same behaviour, on-disk formats and commands. It
does **not** mean running original x86 `.COM`/`.EXE` binaries; that would need
a CPU emulator and is tracked separately as an optional milestone.

## Milestones

| # | Milestone | Status |
|---|-----------|--------|
| 1 | Native FAT12/16/32 filesystem (`src/fat.S`) | Done |
| 2 | Standalone kernel: leave UEFI (`ExitBootServices`), own exception vectors, PL011 console, virtio-blk disk, own PE32+ program loader and memory arena; firmware mode kept only as a fallback for boards without native drivers | Done (QEMU `virt`; `make smoke`, `make smoke-firmware`) |
| 3 | Complete DOS function set (INT 21h equivalents 00h–6Ch in the native ABI, including FCB, IOCTL, sharing/locking, extended open, NLS queries) | Done (`DOSTEST.EXE` in `make smoke`; dispatch table checked by `make unit`) |
| 4 | COMMAND parity: pipes, `FOR`, `SET`, `SHIFT`, `PATH`, `PROMPT`, `VOL`, `VERIFY`, `BREAK`, `CTTY`, wildcard `COPY`/`DEL`/`REN`, `DIR` switches, environment, `AUTOEXEC.BAT` | Done (`FEATURES.BAT`, `AUTOEXEC.BAT` and COMMAND checks in `make smoke`) |
| 5 | `CONFIG.SYS`: `FILES`, `BUFFERS`, `SHELL`, `DEVICE` (native drivers), `BREAK`, `COUNTRY`, `LASTDRIVE` | Done (`CONFIG.SYS` fixture with `TESTDRV.SYS` in `make smoke`; also `INSTALL`, `FCBS`, `STACKS`) |
| 6 | Portable utilities from `v4.0/src/CMD` as native programs: ATTRIB, CHKDSK, COMP, EDLIN, FC, FIND, FORMAT, LABEL, MEM, MORE, REPLACE, SORT, SUBST, SYS, TREE, XCOPY, plus BACKUP/RESTORE, APPEND, ASSIGN, JOIN, RECOVER, DISKCOPY/DISKCOMP | Next |
| 7 | Portable drivers from `v4.0/src/DEV`: ANSI (console escape handling), RAMDRIVE/VDISK, COUNTRY data, PRINTER as a serial/null device | Planned |
| 8 | Hardware: QEMU `virt` fully native; Raspberry Pi 3 native console and SD drivers (needs a physical board to validate) | Planned |

## Not applicable to AArch64

These components exist only to drive IBM PC hardware or x86 binaries. Each is
listed with what replaces it.

| Component | Reason | Replacement |
|-----------|--------|-------------|
| DEBUG | x86 debugger and disassembler | Native exception reports; an AArch64 monitor is optional |
| EXE2BIN | Converts x86 EXE to COM | None needed (one native executable format) |
| XMA2EMS, XMAEM, SMARTDRV EMS paths | x86 expanded/extended memory | Flat 64-bit memory |
| GRAFTABL, GRAPHICS, DISPLAY, KEYB, MODE (video/keyboard parts) | CGA/EGA/VGA and PC keyboard hardware | Serial/ANSI console; MODE keeps serial settings |
| FASTOPEN, IFSFUNC, NLSFUNC, SHARE as TSRs | x86 resident programs hooking INT 21h | Built into the kernel where the behaviour is kept |
| FDISK (MBR CHS editing) | BIOS geometry | MBR/GPT partition listing, optional |
