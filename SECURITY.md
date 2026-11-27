# Security policy

## Security model

ARM DOS keeps the security model of MS-DOS, which is to say it has very
little of one. Read this before running it anywhere that matters.

- **No memory isolation.** Programs and drivers run at the same privilege
  level as the kernel (EL1 or EL2, whichever the firmware started it at), in
  one flat, identity-mapped address space. The kernel never changes the
  page tables. Any program can read or overwrite the kernel, other
  programs and their data, exactly as a real-mode DOS program could.
  Resource ownership (memory blocks, files, locks) exists for cleanup when a
  program ends, not for protection.
- **No users, permissions or authentication.** Anyone at the console, or on
  the serial line, has full control. File attributes such as read-only are
  advisory and any program can change them.
- **Every program is trusted.** Running a program, loading a driver with
  `DEVICE=` or a batch file from `AUTOEXEC.BAT` gives it the whole machine.
  Only run programs you trust.
- **The firmware is trusted.** ARM DOS is started by UEFI firmware and
  relies on it to load the kernel image intact. In firmware mode it keeps
  using UEFI boot services for the console, memory and disks; in native mode
  it uses only UEFI runtime services, and only to power off. ARM DOS images
  are not signed for UEFI Secure Boot.
- **Disks are trusted for integrity, not for safety.** There is no
  encryption or integrity checking of files. A crafted disk, however,
  should not be able to crash the kernel just by being mounted or read (see
  below).
- **INSTALL erases a whole disk** after asking. `E0h`, the raw disk
  interface behind it, never offers the disk ARM DOS booted from, but any
  program can call it.

In short: ARM DOS is a hobby and teaching operating system. Do not connect
it to untrusted networks (it has no network stack today), and do not treat
it as a sandbox.

## What has been hardened

Although programs are trusted, data from disks and executable files is
checked, because a corrupt floppy or a bad download should produce an
error, not a crash:

- **FAT driver** (`src/fat.S`): every cluster number read from disk is
  range-checked against the volume before it is used, chain walks are
  bounded by the volume's cluster count (so a FAT loop cannot hang the
  kernel), boot record fields are validated before mounting, and a block
  device's boot record cannot claim more sectors than the device has.
- **Paths:** canonical paths are bounded to 255 characters, and command
  lines and batch-file expansion to 255 bytes; overlong input is an error,
  not an overflow.
- **PE32+ loader** (`src/process.S`): headers, section data, the image
  size (at most 16 MiB), and relocation blocks and every relocation target
  are bounds-checked against the file and the image before they are
  patched; only `DIR64` relocations are accepted, and x86 images are
  refused with "invalid format".
- **IOCTL, FCB and drive-table calls** check their buffer sizes, drive
  numbers and handles.
- **Fuzzing:** the FAT driver is stress-tested on FAT12/16/32 images
  (`make fat-test`), and the nightly CI workflow runs the repository's fuzz
  targets (corrupt FAT images, malformed `.EXE` files, ARM BASIC programs
  and COMMAND lines) when the Makefile provides them, keeping any crashing
  input as an artifact.

## Supported versions

| Version | Supported |
| --- | --- |
| Latest release (0.1.x) | Yes |
| `arm` branch (development) | Yes, fixes land here first |
| Older releases | No |

## Reporting a vulnerability

Please report security problems privately through GitHub: on the
repository page open **Security**, then **Report a vulnerability**
(private vulnerability reporting / security advisories). Do not open a
public issue for a problem that could hurt users before it is fixed.

Useful details: the ARM DOS version or commit, how it was booted (QEMU
`virt`, live ISO, ROM build, Raspberry Pi), and the smallest input that
shows the problem (a disk image, `.EXE` file, batch file or command line).

Given the model above, "a program can overwrite the kernel" is expected
behaviour and not a vulnerability. A crash, hang or memory corruption
caused by **data** (a disk image, a file system, an executable's headers,
a command line, a BASIC program) is in scope.
