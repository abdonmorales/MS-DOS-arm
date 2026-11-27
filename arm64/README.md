# ARM DOS

**ARM DOS** is MS-DOS 4.0 ported natively to 64-bit ARM (AArch64), written in
ARM64 assembly. The kernel, COMMAND, `CONFIG.SYS`, the DOS function set, the
`v4.0/src/CMD` utilities and the `v4.0/src/DEV` drivers are re-implemented
with the same commands, behaviour and on-disk formats; the historical x86
sources in this repository are the reference it was ported from and stay
unchanged.

What to expect:

- **x86 programs do not run.** ARM DOS runs native AArch64 programs (PE32+
  `.EXE` files built against [ABI.md](ABI.md)) and batch files. There is no x86
  emulator, by design.
- **QEMU `virt` (and Apple Silicon Macs under QEMU/HVF) is fully supported and
  tested**, natively (the kernel leaves UEFI and drives the hardware itself) and
  in firmware mode.
- **A real Raspberry Pi 3 has not been booted yet.** Its native drivers pass
  their tests on QEMU's `raspi3b` model; only a physical board can confirm them
  (see [PORT_STATUS.md](PORT_STATUS.md), milestone 8).

UEFI is only the boot loader. At startup the kernel finds its console UART
(ACPI SPCR) and its boot disk (ACPI MCFG, PCI ECAM, virtio-blk), reserves its
memory, calls `ExitBootServices` and owns the machine from then on: its own
exception vectors, polled PL011 console, virtio-blk driver, FAT12/16/32
filesystem (`src/fat.S`), memory arena and PE32+ program loader
(`src/platform.S`, `src/process.S`). On boards it has no drivers for, it
stays in firmware mode and uses UEFI for the console, memory and sectors; the
banner's `Platform:` line says which mode is active. The Raspberry Pi 3 has
native drivers too (PL011 or mini UART console, SD card on the Arasan SDHCI,
`src/sdhci.S`), tested bare metal on QEMU's `raspi3b` model by
`make -C arm64 pi-test`; since they have not run on a physical board yet, the
Pi uses them only when the card's FAT volume has a file named `NATIVE.ON`, and
otherwise stays in firmware mode. It contains no Linux guest, x86 interpreter,
or x86 executable emulation.

## Build and run

On Debian/Ubuntu, install GNU AArch64 binutils, Python 3, Make, QEMU's ARM system
emulator and ARM64 UEFI firmware. The Pi image additionally uses mtools and
dosfstools. The equivalent package names are:

```sh
binutils-aarch64-linux-gnu qemu-system-arm qemu-efi-aarch64 mtools dosfstools
```

On Ubuntu 24.04 the packages above install with `apt-get`, and the targets
run against the system firmware:

```sh
make -C arm64 smoke FIRMWARE=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd
```

Without root access on a Debian 13 x86_64 machine, `bash arm64/tools/setup-cloud.sh`
installs the same tools into `/workspace/arm-toolchain` (its fixed location)
and `source arm64/tools/env.sh` puts them on `PATH`; then pass
`FIRMWARE=/workspace/arm-toolchain/runtime/usr/share/qemu-efi-aarch64/QEMU_EFI.fd`.
The script uses isolated APT state, signed Debian metadata and verified package
hashes, extracts tools only into that directory, and runs the image smoke test. Firmware and runtime libraries remain
separate from the repository. It does not configure Apple or Raspberry Pi
hardware, install system packages, or change credentials.

With system-installed tools, omit `source` and pass the installed firmware
path to `make` (`FIRMWARE=...`); `run.py` finds it itself. `CROSS_COMPILE` can select another GNU AArch64 prefix, such as
`aarch64-elf-`; the application uses ARMv8-A instructions and AAPCS64 throughout.

```sh
make -C arm64 image CROSS_COMPILE=aarch64-elf-
python3 arm64/tools/run.py arm64/build/msdos-arm64.img
```

`run.py` finds ARM64 UEFI firmware where Homebrew, Debian/Ubuntu and Fedora
install it; pass `--firmware /path/to/QEMU_EFI.fd` to use another file.
`--iso` boots the live ISO from a read-only CD drive, `--disk` adds a writable
disk (created blank at `--disk-size`, default 512M, if it does not exist), and
`--print` shows the QEMU command instead of running it. Quit QEMU with
Ctrl-A, then X. The runner chooses QEMU's `hvf` accelerator and `host` CPU on
Apple Silicon macOS, `kvm` on ARM64 Linux with `/dev/kvm`, or `tcg` and
Cortex-A72 elsewhere (`--accel` and `--memory` override them). The cloud
validation used TCG on x86_64; HVF was tested on an Apple M3 Pro (macOS 27.2, QEMU 11.1 from Homebrew, its
`edk2-aarch64-code.fd`): `make smoke` passed all its checks in native and
firmware mode, with the same output as TCG, and the live ISO booted and
`INSTALL` produced a disk that booted on its own. UTM has not been tested. UTM can use an ARM64 VM with UEFI firmware
and the raw disk as a writable VirtIO drive. This image requires a writable FAT
volume for its boot self-test.

The disk image files keep their original names (`msdos-arm64.img`,
`msdos-arm64-pi3.img`).

Commands: `HELP`, `VER`, `ECHO`, `CLS`, `DIR`, `TYPE`, `DEL`/`ERASE`,
`CD`/`CHDIR`, `MD`/`MKDIR`, `RD`/`RMDIR`, `COPY`, `REN`/`RENAME`,
`DATE`, `TIME`, `VOL`, `SET`, `PATH`, `PROMPT`, `FOR`, `SHIFT`, `REM`, `CALL`,
`GOTO`, `IF`, `PAUSE`, `VERIFY`, `BREAK`, `CTTY`, `CHCP`, `TRUENAME`,
`SELFTEST`, `EXIT`. Native AArch64 `.EXE` and `.BAT` files run from the shell,
found through the current directory and then `PATH`; `NATIVE.EXE` is a
separately linked example and `DOSTEST.EXE` exercises the DOS function set
from a loaded program. `\AUTOEXEC.BAT` runs at boot; without it the shell asks
for the date and time, as COMMAND did.

The utilities from `v4.0/src/CMD` are separate native programs on the image:
`APPEND`, `ASSIGN`, `ATTRIB`, `BACKUP`, `CHKDSK`, `COMP`, `DISKCOMP`,
`DISKCOPY`, `EDLIN`, `FC`, `FIND`, `FORMAT`, `JOIN`, `LABEL`, `MEM`, `MORE`,
`RECOVER`, `REPLACE`, `RESTORE`, `SORT`, `SUBST`, `SYS`, `TREE` and `XCOPY`.
`INSTALL` puts ARM DOS on another disk (see [Live ISO and INSTALL](#live-iso-and-install)).
`BASIC` is ARM BASIC, a native BASIC interpreter (see [ARM BASIC](#arm-basic)).
The `CONFIG.SYS` fixture loads `RAMDRIVE.SYS` twice and `VDISK.SYS` once, so
drives B:, C: and D: are RAM disks for the multi-drive tools (`B:` switches
drive, as in DOS). It also loads `ANSI.SYS` (DOS escape sequences, cursor
reports and key reassignment over the serial terminal) and `PRINTER.SYS`
(PRN to the serial line). `COUNTRY.SYS`, assembled from the original
`MKCNTRY.ASM`, gives `COUNTRY=` and `CHCP` the DOS 4.0 countries and code
pages.

Paths support quotes, relative components, `.`/`..`, drive letters, and DOS device
names (`CON`, `AUX`, `PRN`, `NUL`, `CLOCK$`). `DIR` prints the DOS 4.0 layout
(volume header, `Directory of`, name/extension/size/date/time columns, file
count and bytes free) and accepts `/W` and `/P`. `COPY` takes wildcards,
directory destinations, rename templates (`COPY *.TXT *.BAK`), `+`
concatenation, and device sources such as `COPY CON FILE` (ended by ^Z); files
keep their date and time. `DEL` takes wildcards and `/P`, and asks
`Are you sure (Y/N)?` for `*.*`; `REN` takes templates (`REN *.TXT *.OLD`). Long
ASCII filenames are read and written as VFAT long-name entries and shown whole
by `DIR`. Redirection supports `<`, `>`, `>>`, and pipes (`a | b`) run through
temporary files (`\%PIPEdn.$$$`) in the root, as COMMAND did. `2>` is not a DOS 4.0 feature.

`\CONFIG.SYS` is processed at boot: `BREAK`, `BUFFERS`, `COUNTRY`, `DEVICE`,
`FCBS`, `FILES`, `INSTALL`, `LASTDRIVE`, `REM`, `SHELL` and `STACKS`. `DEVICE=`
loads native AArch64 character drivers (`.SYS` PE32+ images; see
[ABI.md](ABI.md)); `TESTDRV.SYS` is the example used by the tests.

The environment holds `COMSPEC`, `PATH`, `PROMPT` and anything set with `SET`;
it is passed to every program (descriptor +40). `PROMPT` supports `$P $G $L $B
$Q $$ $E $H $N $_ $D $T $V`. Batch files support `%0`–`%9`, `%*`, `%%`,
`%NAME%` environment expansion (in batch files only, as in COMMAND 4.0), `%ERRORLEVEL%`, `ECHO ON/OFF` (restored when the
batch ends), `ECHO.`, `@`, `REM`, `CALL`, `GOTO`, `SHIFT`,
`FOR %%v IN (set) DO command` (with wildcards in the set),
`IF [NOT] EXIST/ERRORLEVEL/string1==string2`, `PAUSE`, and `EXIT /B`. Commands
are limited to 255 bytes and `CALL` nesting to 16 scripts; a batch file started
from another without `CALL` replaces it, so restart loops run indefinitely.
Internal command names end at `= / + ; , . \ " [` as in COMMAND (`cd..`,
`dir/w`, `echo.text`). `DATE` and `TIME` show the
clock in the country's format and prompt for a new value. `EXIT` powers the
machine off in native mode (the firmware is gone) and returns to UEFI in
firmware mode.

Each boot runs native API integration tests against actual files on disk:
FCB records, partial EOF padding, paths, search buffers, attributes, file times,
seek/truncate/duplicate handles, allocation ownership and resizing, clock leap
years and rollover, native and nested process loading, termination, and parent
handle preservation. Reserved scratch names are `ARMCHK.TMP`, `ARMFCB.TMP` and
`ARMAPI.TMP` (a directory). The test refuses to overwrite existing objects with
those names and restores the starting directory. Smoke tests boot a temporary
image copy and check about 330 console requests, including 70 successive native
launches that deliberately leave resources for process cleanup, buffered input
with backspace editing, batch control flow, and redirection restoration.

`make -C arm64 unit` runs host-side unit tests in about 6 seconds, with no
firmware or boot. `tools/unit.py` loads `build/kernel.bin` into the Unicorn CPU
emulator (`python3 -m pip install unicorn`) and calls routines by their
`kernel.elf` symbol, comparing each against a Python reference: every date
from 1975 to 2111 through `validate_date`, `date_to_days` and `days_to_date`,
every date and time of day through `pack_efi_time`, about 330,000
`wildcard_match` pattern/name pairs, and every DOS function number through
`dos_call`, which must reach the handler listed in `DISPATCH` and fail
anything ABI.md does not document. Only routines that need no UEFI services
can be called this way. `make -C arm64 check` runs `unit` then `smoke`.

## ARM BASIC

`BASIC` (`BASIC.EXE`, from `programs/basic.S`) is ARM BASIC, an interpreter
in the style of the Microsoft BASICs that came with MS-DOS, written from
scratch in AArch64 assembly. Type numbered lines to build a program and
statements without a number to run them at once; `Ok` is the prompt.
`BASIC PRIMES` loads `PRIMES.BAS` (the sample on the image) and runs it.

```
A:\>basic
ARM BASIC 1.0 for ARM DOS (native AArch64)
64-bit integers and strings. SYSTEM returns to DOS.
Ok
10 FOR I = 1 TO 3: PRINT "ARM"; I: NEXT
RUN
ARM 1
ARM 2
ARM 3
Ok
SAVE "COUNT"
Ok
SYSTEM
```

- Statements: `PRINT` (`?`), `LET`, `INPUT`, `IF ... THEN ... ELSE`, `GOTO`,
  `GOSUB`, `RETURN`, `ON ... GOTO/GOSUB`, `FOR ... TO ... STEP`, `NEXT`,
  `WHILE`, `WEND`, `END`, `STOP`, `REM` (`'`), `DIM`, `DATA`, `READ`,
  `RESTORE`, `RANDOMIZE`, `CLS` and `CLEAR`.
- Commands: `RUN`, `LIST [m][-n]`, `NEW`, `LOAD "f"`, `SAVE "f"` (plain text,
  `.BAS` added) and `SYSTEM` (back to DOS).
- Functions: `ABS`, `SGN`, `INT`, `SQR`, `RND`, `LEN`, `ASC`, `VAL`, `CHR$`,
  `STR$`, `LEFT$`, `RIGHT$`, `MID$`, `INSTR` and `SPACE$`; `PRINT` also takes
  `TAB(` and `SPC(`.
- Operators, tightest first as in GW-BASIC: `^` (left to right, so `2^3^2`
  is 64), unary `-`, `*` and `/`, `\`, `MOD`, `+` and `-`, comparisons
  `= <> < > <= >=`, then `NOT`, `AND` and `OR` (bitwise, true is -1).

Numbers are 64-bit integers: there is no floating point, `/` and `\` both
divide to an integer, a typed fraction is dropped (`1.5` is 1), and a result
outside the 64-bit range is an `Overflow` error (a literal is at most
9223372036854775807, so the most negative number is written
`-9223372036854775807-1` or `&H8000000000000000`). `RND(n)` returns 1 to n,
`INSTR` takes two arguments and `VAL` reads decimal only (`&H` works in
program text). Strings hold up to 255 bytes, and so do program lines.
Variable names are significant to 14 characters. Arrays (`DIM A(100)`,
`A$(n)`) have one dimension. Ctrl-C stops a
running program (`Break in 30`); at an `INPUT` prompt it takes effect when
ENTER is pressed. Errors use the GW-BASIC messages (`Syntax error in 20`).

## Native FAT driver

`src/fat.S` mounts the boot partition through UEFI Block I/O and implements
FAT12, FAT16 and FAT32: cluster chains, FAT mirroring, fixed and cluster-based
root directories, directory growth, VFAT long names with checksummed `~N`
short aliases, Windows NT lower-case flags, and allocation, truncation, rename,
move and delete. It presents each open file as an `EFI_FILE_PROTOCOL`-shaped
object, so the DOS services above it did not change. A small write-through
sector cache (eight 4 KiB entries) keeps every update on disk before a call
returns. FAT32's FSInfo free count is marked unknown rather than maintained.

The boot banner reports which storage backend is active. If the boot volume is
read-only or not FAT, the runtime falls back to the firmware's SimpleFileSystem.
In firmware mode, `EXIT` flushes and reinstalls Block I/O so firmware drops
stale FAT state. In native mode the same driver runs over the kernel's
virtio-blk driver instead of UEFI Block I/O.

`make -C arm64 smoke-firmware` repeats the smoke test with ACPI hidden from the
firmware (`-machine virt,acpi=off`), which keeps the kernel in firmware mode.

`make -C arm64 smoke` now also requires the native backend, runs `fsck.fat` on
the disk after the session and reads a natively written long name back with
mtools. `make -C arm64 fat-test` stress-tests the driver on its own: it builds
it into a Linux AArch64 test program (`tests/fat_host.c`, with
`gcc-aarch64-linux-gnu`) run under `qemu-aarch64` (`qemu-user`) against
FAT12, FAT16 (512-byte and 4 KiB sectors) and FAT32 (512-byte and 4 KiB
clusters) images. Each image is prepared with mkfs.fat and mtools, modified
over two mounts, and must pass `fsck.fat -n` and match an mtools read-back.

## Disk images

| Image | Format | Verified scope |
| --- | --- | --- |
| `build/msdos-arm64.img` | 64 MiB MBR/FAT16, ARM64 EFI application | Boots in QEMU `virt`; API and console tests pass |
| `build/msdos-arm64-pi3.img` | 128 MiB MBR/FAT32, Pi 3 boot files and UEFI firmware | Firmware/package structure checked; same payload tested through ARM64 UEFI; physical Pi boot unverified |
| `build/armdos.iso` | Live ISO: UEFI El Torito, 30 MiB FAT16 boot image (also MBR partition 2) | Boots in QEMU `virt` as a CD and as a USB stick; `INSTALL` to a blank disk, which then boots (`make iso-test`) |

Both images include `EFI/BOOT/BOOTAA64.EFI`, `NATIVE.EXE`, `DOSTEST.EXE`, batch fixtures,
`ARMTEST.TXT`, a SHA-256 sidecar and a JSON manifest. The manifests record that physical hardware is
unverified (`complete_msdos_port` stays false until a real Pi 3 boots). Raw build products are ignored by Git. Validated snapshots (compressed disk
images and the uncompressed live ISO) and their checksums are published in [images](images/README.md) on the `arm` branch.

## Live ISO and INSTALL

`make -C arm64 iso` builds `build/armdos.iso` from the generic disk image
(it needs `xorriso` as well as mtools and dosfstools). The ISO boots on any
ARM64 UEFI machine or VM, such as QEMU `virt` or UTM, from a virtual CD or
written to a USB stick. A Raspberry Pi 3 does not boot it: use the SD-card
image there.

The ISO starts the normal ARM DOS prompt as a live system, so you can look
around and run programs before installing anything:

- Drive A: is the ISO itself and is **read-only**. Writes to it fail and
  nothing on A: changes between boots.
- `CONFIG.SYS` on the ISO loads one 1 MiB RAM disk, B:, for scratch files.
  It is empty again after a restart.
- The ISO holds the release file set: the disk image's test fixtures
  (`TESTDRV.SYS`, `DOSTEST.EXE`, the sample text and batch files, and the
  test `CONFIG.SYS`) are left out or replaced.

`INSTALL` (`INSTALL.EXE`) copies ARM DOS to a writable disk, as SELECT did
for DOS 4. It lists the disks the firmware offers, apart from the one ARM
DOS started from, and asks which one to use and for confirmation. Then it
writes an MBR with one partition of type EFh (from 1 MiB, at most 2000 MB,
the FAT16 limit of FORMAT), formats it with `FORMAT d: /SELECT /V:ARMDOS`,
and copies every file from A: with `XCOPY`, `\EFI\BOOT\BOOTAA64.EFI`
included. **Everything on the chosen disk is erased.** Disks are numbered in
the firmware's order. Before writing anything INSTALL checks that the
partition can become a drive, and ENTER at the disk question or N at the
confirmation leaves the disks untouched. `INSTALL n /Y` picks disk n without
asking, for scripts; `/Y` without a disk number is refused. INSTALL needs UEFI boot services, so it
runs from the live ISO (or any firmware-mode boot). Under the native kernel
it finds no disks.

To install in QEMU (on a Mac, `brew install qemu` provides QEMU and its
firmware), use the published snapshot `arm64/images/armdos.iso`, or
`arm64/build/armdos.iso` after `make -C arm64 iso`:

```sh
python3 arm64/tools/run.py --iso arm64/images/armdos.iso --disk armdos-disk.img
```

This creates a blank 512 MiB `armdos-disk.img` (if it does not exist yet) and boots the ISO with it
attached. At the `A:\>` prompt run `INSTALL`. When it finishes, quit QEMU
(Ctrl-A, then X) and boot the installed disk on its own; ARM DOS starts from
it with A: writable:

```sh
python3 arm64/tools/run.py armdos-disk.img
```

Without the runner, an equivalent live boot is (`--print` shows the exact
command the runner uses):

```sh
qemu-img create -f raw armdos-disk.img 512M
qemu-system-aarch64 -machine virt -cpu cortex-a72 -m 256 -nographic \
  -net none -boot menu=on,splash-time=0 \
  -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
  -device virtio-scsi-pci -drive file=arm64/images/armdos.iso,if=none,id=cd,media=cdrom,readonly=on \
  -device scsi-cd,drive=cd,bootindex=0 \
  -drive file=armdos-disk.img,if=none,id=hd,format=raw -device virtio-blk-pci,drive=hd
```

After `INSTALL`, run the same command without the `-device virtio-scsi-pci`,
CD `-drive` and `scsi-cd` lines to boot the installed disk. On Apple Silicon,
replace `-cpu cortex-a72` with `-accel hvf -cpu host` and the `-bios` path with
Homebrew's `/opt/homebrew/share/qemu/edk2-aarch64-code.fd`.

The ISO holds only an ARM64 UEFI loader (no BIOS boot code or `BOOTX64.EFI`),
so x86 PCs and x86 virtual machines, such as VirtualBox, VMware or Hyper-V on
an Intel/AMD host or an x86 guest type, cannot boot it. VirtualBox's ARM64
VMs on Apple Silicon have not been tested.

To install in UTM (untested; the same steps work in QEMU): create a new
virtual machine with **Virtualize** (on Apple Silicon) or **Emulate** with the
ARM64 architecture, choose **Other**, and pick `armdos.iso` as the boot ISO.
Keep UEFI boot on and give it a VirtIO disk of at least 64 MB. Start it, run
`INSTALL` at the prompt, shut the VM down, remove the ISO from its CD drive
and start it again.

`make -C arm64 iso-test FIRMWARE=...` checks all of this in QEMU: the live
system as a CD and as a read-only USB stick (A: refuses writes, B: takes
them); with two blank 128 MiB disks, the menu, cancelling, the `/Y` guard,
`INSTALL 2 /Y` (disk 1 must stay all zeros) and a second run in the same
session; `fsck.fat` on the result; a boot of the installed disk alone that
keeps a file written to A:; that INSTALL does not offer the writable USB
stick it booted from; and that rebuilding the ISO gives the same bytes.

Build the Pi image with:

```sh
make -C arm64 pi-image
```

The packager downloads [Pi 3 UEFI firmware v1.53.1](https://github.com/pftf/RPi3/releases/tag/v1.53.1)
over verified HTTPS and checks its pinned SHA-256 before extracting. It preserves
upstream config and filenames, includes firmware licenses, and uses the Pi's
required FAT LBA partition type instead of EFI partition type `0xef`. Rebuilds
atomically replace only an unchanged image whose manifest and checksum identify
it as this tool's output. Modified or unrecognized existing images are preserved.
This image targets Pi 3B/3B+, not Pi 4/5.

To prepare an SD card, select the Pi image and the intended removable card in
Raspberry Pi Imager's custom-image workflow. Use a card of at least 128 MiB.
The firmware console can use HDMI/USB input or a supported serial console.
The Pi image's payload has been booted in QEMU only, not yet on real hardware.
To try the native Pi drivers on a board, create an empty `NATIVE.ON` in the
card's root; the banner then reads `Raspberry Pi 3 UART console, SD card`.
In that mode the console is the serial UART only (GPIO 14/15): HDMI and USB
keyboards stop working once firmware is left, so attach a serial adapter. If
the card cannot be started after leaving firmware, the kernel prints `Boot disk
did not restart after leaving firmware` and halts; delete `NATIVE.ON` to go
back to firmware mode.

Run `make -C arm64 validate FIRMWARE=/path/to/QEMU_EFI.fd` to check both FAT
filesystems, compare their payloads to the build outputs, boot both images in
QEMU and save `build/validation.json`. `make -C arm64 snapshot` validates and
packages compressed snapshots with raw/compressed SHA-256 checksums. The Pi
firmware remains under its upstream licenses, included inside the image;
the DOS assembly is MIT licensed. See [images/README.md](images/README.md).

## Native Apple Silicon boot

A raw AArch64 image does not provide Apple's boot authorization, m1n1, device
trees or U-Boot. It cannot simply replace a Mac's internal disk or boot directly
from Apple's startup picker. This repository does not install or modify the
Mac boot chain.

For an Apple model that already has a working, supported Asahi m1n1/U-Boot
installation, the generic EFI image is a candidate external boot payload:

1. Verify the model's current [Asahi feature support](https://asahilinux.org/docs/platform/feature-support/overview/).
2. Put `msdos-arm64.img` on a spare USB drive as a raw disk image, or copy its
   EFI application and `ARMTEST.TXT` to a separate compatible FAT boot volume.
3. Use the existing U-Boot external boot flow described in the
   [Asahi U-Boot guide](https://asahilinux.org/docs/sw/u-boot/), such as
   interrupting autoboot and using `run bootcmd_usb0` for the intended USB device.
4. Require the native self-test to pass before treating the runtime as working
   on that model. A firmware console and writable EFI file protocols are needed.

Native Apple hardware has **not** been tested. All-model support cannot be
claimed: Asahi documentation still lists missing installers and drivers for
some M-series models. Its support tables describe Asahi's stack, not validation
of this DOS runtime. Support for every Apple Silicon model remains a goal,
not a claimed feature.

## Native API and status

The [AArch64 ABI](ABI.md) documents every DOS function from 00h to 6Ch, their
arguments, return values and limits. Calls use AAPCS64 and a function pointer
provided to each native process. FCB records retain their standard 37-byte data
layout; pointers and process/search structures use the native ABI. Original x86
executables cannot run.

The runtime provides the complete DOS 4.0 function set (00h-6Ch): console and
AUX/PRN I/O, the CON/AUX/PRN/NUL/CLOCK$ devices, handle and FCB file services
(including extended FCBs, FCB searches, wildcard delete/rename, random block
I/O and filename parsing), built-in SHARE semantics (sharing modes, record
locks), IOCTL, drive parameter blocks, the list of lists, media IDs, extended
errors, Ctrl-C/BREAK handling with vector 23h, terminate-and-stay-resident,
load-only and overlay exec modes, allocation strategies, country information
and code page 437 case mapping, TRUENAME, temporary files and extended
open/create. It also has a batch interpreter.
These adapt selected public contracts from `CPMIO.ASM`, `GETSET.ASM`,
`HANDLE.ASM`, `FILE.ASM`, `PATH.ASM`, `SEARCH.ASM`, `FCBIO.ASM`, `TIME.ASM`,
`ALLOC.ASM`, `PROC.ASM`, `DISPATCH.ASM`, `FCB.ASM`, `LOCK.ASM`, `SHARE.ASM`,
`IOCTL.ASM`, `DOSMES.ASM` (NLS tables) and `COMMAND`. Their original internal algorithms have
not been fully translated. In native mode no UEFI boot service is used after
startup; UEFI runtime services are used only for power-off.

[PORT_STATUS.md](PORT_STATUS.md) tracks the port: milestones 1-7 (kernel,
DOS functions, COMMAND, `CONFIG.SYS`, every utility, drivers, NLS) are done,
and QEMU `virt` runs fully native. What remains is milestone 8's physical
hardware check: booting the Pi 3 image, and its native drivers, on a real
board. Until that is verified the manifests keep `complete_msdos_port` false.
The checked-in historical source archives remain x86 assembly. Booting natively
on every Apple Silicon model is not supported (see above); running under QEMU
on a Mac is.

Reference boot documentation was inspected at Asahi docs commit
`0d1f8917fa88745d62a4c05d802c4a7298c8616b` and Pi UEFI commit
`671c48c7a99c3c5664b347c938e4190ad6aa255f`.
