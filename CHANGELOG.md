# Changelog

All notable changes to ARM DOS are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Continuous integration on every push and pull request, a nightly
  validate and fuzz run, and a tag-triggered Release workflow that builds
  the images, the live ISO, the ROM builds and `SHA256SUMS`.
- GitHub Releases as the home of the images: `tools/fetch_release.py`
  downloads and verifies them, and `tools/run.py --iso latest` boots the
  latest live ISO.
- Fuzzing of the FAT driver, the PE32+ loader, ARM BASIC and COMMAND.
- Documentation: a command reference (`docs/COMMANDS.md`), an ARM BASIC
  guide (`docs/BASIC.md`), a programmer's guide (`docs/PROGRAMMING.md`),
  this changelog and a security policy (`SECURITY.md`).

### Changed

- Disk images and the live ISO are no longer committed to `images/`; they
  are published as release assets.

## [0.1.0] - 2026-11-27

The first ARM DOS release: MS-DOS 4.0 re-implemented in AArch64 assembly.

### Added

- **Milestone 1:** a native FAT12/16/32 file system with VFAT long names,
  FAT mirroring and a write-through sector cache.
- **Milestone 2:** a standalone kernel that leaves UEFI
  (`ExitBootServices`) and owns the machine with its own exception vectors,
  PL011 console, virtio-blk driver, memory arena and PE32+ program loader;
  firmware mode remains as a fallback for boards without native drivers.
- **Milestone 3:** the complete DOS function set `00h`-`6Ch` in a native
  AAPCS64 ABI (`ABI.md`): console and device I/O, handle and FCB files,
  SHARE locking, IOCTL, EXEC, memory allocation and NLS queries.
- **Milestone 4:** COMMAND parity: pipes, redirection, `FOR`, `SET`,
  `SHIFT`, `PATH`, `PROMPT`, `VOL`, `VERIFY`, `BREAK`, `CTTY`, wildcard
  `COPY`/`DEL`/`REN`, `DIR /W /P`, batch files and `AUTOEXEC.BAT`.
- **Milestone 5:** `CONFIG.SYS` (`BREAK`, `BUFFERS`, `COUNTRY`, `DEVICE`,
  `FCBS`, `FILES`, `INSTALL`, `LASTDRIVE`, `REM`, `SHELL`, `STACKS`) and
  native installable device drivers.
- **Milestone 6:** the DOS 4.0 utilities as native programs: APPEND,
  ASSIGN, ATTRIB, BACKUP, CHKDSK, COMP, DISKCOMP, DISKCOPY, EDLIN, FC,
  FIND, FORMAT, JOIN, LABEL, MEM, MORE, RECOVER, REPLACE, RESTORE, SORT,
  SUBST, SYS, TREE and XCOPY; multiple drives and block device drivers.
- **Milestone 7:** the drivers ANSI.SYS, RAMDRIVE.SYS, VDISK.SYS and
  PRINTER.SYS, and COUNTRY.SYS built from the MS-DOS 4.0 `MKCNTRY.ASM`
  tables with `CHCP` code page switching.
- **Milestone 8 (partial):** QEMU `virt` runs fully native, including on
  Apple Silicon with HVF; native Raspberry Pi 3 UART and SD card drivers
  pass their tests on QEMU `raspi3b` but have not been booted on a board.
- A live ISO (`make iso`) and `INSTALL.EXE`, which partitions, formats and
  copies ARM DOS to a blank disk, using the new `E0h` raw disk services.
- ARM BASIC (`BASIC.EXE`), a BASIC interpreter written from scratch in
  AArch64 assembly.
- ROM builds (`make rom-generic`, `make rom-pi`): the kernel and a
  read-only drive A: in one EFI application for the Raspberry Pi 3/4 and
  generic ARM64 boards, bootable from SD, USB, the network or flash through
  U-Boot.
- `tools/run.py`, a QEMU launcher for the live ISO, INSTALL disks and
  installed disks on Linux and macOS.
- Tests: Unicorn unit tests, the QEMU console smoke test in native and
  firmware modes, FAT stress tests, the Pi driver test and ISO/INSTALL
  tests.

### Removed

- The original x86 MS-DOS sources, which were the reference for the port;
  only the MS-DOS 4.0 country tables (`data/country/`) remain. The sources
  stay available in Microsoft's upstream repository.

[Unreleased]: https://github.com/abdonmorales/MS-DOS-arm/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/abdonmorales/MS-DOS-arm/releases/tag/v0.1.0
