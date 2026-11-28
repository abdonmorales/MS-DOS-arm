# ARM DOS

**ARM DOS** is MS-DOS 4.0 ported natively to 64-bit ARM (AArch64), written
entirely in ARM64 assembly. The kernel, COMMAND, `CONFIG.SYS`, the DOS
function set, the DOS 4.0 utilities and drivers are re-implemented with the
same commands, behaviour and on-disk formats. It boots from UEFI, then leaves
the firmware and drives the hardware itself.

```
ARM DOS 4.0 for AArch64 (MS-DOS 4.0 compatible)
Native ARM64 assembly. x86 programs do not run.
Platform: native AArch64 kernel (firmware exited; PL011 console, virtio-blk disk)
...
A:\>ver
ARM DOS Version 4.00 (AArch64), MS-DOS 4.00 API
A:\>basic primes
ARM BASIC 1.0 for ARM DOS (native AArch64)
64-bit integers and strings. SYSTEM returns to DOS.
Primes below 100:
 2  3  5  7  11  13  17  19  23  29  31  37  41  43  47  53  59  61  67  71  73  79  83  89  97
```

What to expect:

- **Native ARM64 only.** ARM DOS runs native AArch64 programs (PE32+ `.EXE`
  files built against [ABI.md](ABI.md)) and batch files. Original x86
  `.COM`/`.EXE` programs do not run, and there is no x86 emulator, by design.
- **QEMU `virt` is fully supported and tested**, including Apple Silicon Macs
  under QEMU with the HVF accelerator, both natively (the kernel calls
  `ExitBootServices` and owns the machine) and in firmware mode.
- **A live ISO and an installer.** Boot `armdos.iso`, try it, then run
  `INSTALL` to put ARM DOS on a disk.
- **ARM BASIC**, a BASIC interpreter written from scratch in AArch64 assembly.
- **ROM builds for embedded boards and the Raspberry Pi.** One EFI file,
  `ARMDOS.EFI`, carries a read-only drive A: and boots from an SD card, a USB
  stick, the network or SPI/NOR flash through U-Boot, with no disk at all
  (see [ROM builds](#rom-builds-raspberry-pi-and-embedded-boards)).
- **A real Raspberry Pi 3 has not been booted yet.** Its native drivers pass
  their tests on QEMU's `raspi3b` model; only a physical board can confirm
  them (see [PORT_STATUS.md](PORT_STATUS.md), milestone 8).

## Quick start on a Mac

You need an Apple Silicon Mac (or any ARM64 or x86_64 host; see
[Building](#building)) and QEMU:

```sh
brew install qemu
git clone https://github.com/abdonmorales/MS-DOS-arm.git
cd MS-DOS-arm
python3 tools/fetch_release.py armdos.iso
python3 tools/run.py --iso images/armdos.iso --disk armdos-disk.img
```

`fetch_release.py` downloads the live ISO of the
[latest release](https://github.com/abdonmorales/MS-DOS-arm/releases/latest)
into `images/` and checks it against the release's `SHA256SUMS` (see
[images/README.md](images/README.md); `run.py --iso latest` does both steps
at once). `run.py` then boots it with
a blank 512 MiB disk `armdos-disk.img` attached (created if it does not exist).
At the `A:\>` prompt, look around (`DIR`, `MEM`, `BASIC`), then type
`INSTALL` to install ARM DOS onto that disk. Quit QEMU with **Ctrl-A, then
X**, and boot the installed disk on its own:

```sh
python3 tools/run.py armdos-disk.img
```

`run.py` finds Homebrew's ARM64 UEFI firmware (`edk2-aarch64-code.fd`) and
uses the `hvf` accelerator with the `host` CPU, so ARM DOS runs at native
speed. This was tested on an Apple M3 Pro (macOS 27.2, Homebrew QEMU 11.1).

## Running in QEMU

`tools/run.py` is the launcher for every host:

| Option | Meaning |
| --- | --- |
| `image` | Raw disk image to boot (writable VirtIO disk) |
| `--iso FILE` | Live ISO on a read-only CD drive; it boots first even with other disks attached. `--iso latest` downloads and verifies the latest release ISO into `images/` first |
| `--disk FILE` | Extra writable disk, such as an `INSTALL` target; created blank and sparse if missing (repeatable) |
| `--disk-size N` | Size of a created `--disk` (default `512M`, minimum `64M`) |
| `--firmware FILE` | ARM64 UEFI firmware; by default it is looked up where Homebrew, Debian/Ubuntu and Fedora install it |
| `--accel auto\|tcg\|hvf\|kvm` | `auto` (the default) picks `hvf` with the host CPU on Apple Silicon macOS, `kvm` on ARM64 Linux with `/dev/kvm`, else `tcg` with a Cortex-A72 |
| `--memory MiB` | Guest RAM (default 256) |
| `--qemu PATH` | The `qemu-system-aarch64` to run |
| `--screen` | Also show the console on a screen in a QEMU window (`ramfb`); the serial console stays in the terminal |
| `--print` | Print the QEMU command instead of running it |

Some examples:

```sh
python3 tools/run.py build/msdos-arm64.img                  # the test disk image you built
python3 tools/run.py --iso build/armdos.iso --disk d.img    # your own ISO build
python3 tools/run.py --iso latest --disk d.img              # fetch the latest release ISO and boot it
python3 tools/run.py --print --iso images/armdos.iso        # show the raw QEMU command
```

Without the runner, an equivalent live boot on Linux is:

```sh
qemu-img create -f raw armdos-disk.img 512M
qemu-system-aarch64 -machine virt -cpu cortex-a72 -m 256 -nographic \
  -net none -boot menu=on,splash-time=0 \
  -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
  -device virtio-scsi-pci -drive file=images/armdos.iso,if=none,id=cd,media=cdrom,readonly=on \
  -device scsi-cd,drive=cd,bootindex=0 \
  -drive file=armdos-disk.img,if=none,id=hd,format=raw -device virtio-blk-pci,drive=hd
```

On Apple Silicon, replace `-cpu cortex-a72` with `-accel hvf -cpu host` and
the `-bios` path with `/opt/homebrew/share/qemu/edk2-aarch64-code.fd`. To
boot the installed disk, drop the `virtio-scsi-pci`, CD `-drive` and
`scsi-cd` lines.

The ISO holds only an ARM64 UEFI loader, so x86 PCs and x86 virtual machines
(VirtualBox, VMware or Hyper-V on Intel/AMD) cannot boot it. UTM should work
with an ARM64 UEFI VM (**Virtualize** on Apple Silicon, or **Emulate** with
ARM64, type **Other**, the ISO as boot image and a VirtIO disk of at least
64 MB) but has not been tested.

## Building

The build needs GNU AArch64 binutils, Python 3 and Make. The disk images
need mtools and dosfstools, the ISO needs xorriso, and running or testing
needs QEMU's ARM system emulator and ARM64 UEFI firmware. On Debian or
Ubuntu:

```sh
sudo apt-get install binutils-aarch64-linux-gnu python3 make mtools dosfstools \
  xorriso qemu-system-arm qemu-efi-aarch64
```

The ROM builds also need `u-boot-tools` (for `mkimage`; `brew install
u-boot-tools` on a Mac), and `make rom-test` needs `u-boot-qemu`; `make unit`
uses `device-tree-compiler` (`dtc`) when present. The Makefile needs GNU Make
4.3 or later (`brew install make`, then `gmake` on a Mac).

On a Mac, `brew install aarch64-elf-binutils mtools dosfstools xorriso qemu`
provides the same tools. Pass `CROSS_COMPILE=aarch64-elf-` to `make`, and
for the targets that boot QEMU (`smoke`, `iso-test`, `validate`, `snapshot`)
also `FIRMWARE=$(brew --prefix)/share/qemu/edk2-aarch64-code.fd`:

```sh
make iso CROSS_COMPILE=aarch64-elf-
make smoke CROSS_COMPILE=aarch64-elf- FIRMWARE=$(brew --prefix)/share/qemu/edk2-aarch64-code.fd
```

| Command | Builds |
| --- | --- |
| `make` | `build/BOOTAA64.EFI` (the kernel and COMMAND) and every program and driver |
| `make image` | `build/msdos-arm64.img`, a 64 MiB FAT16 test disk with the test fixtures |
| `make iso` | `build/armdos.iso`, the live ISO with the release file set |
| `make pi-image` | `build/msdos-arm64-pi3.img`, a 128 MiB Raspberry Pi 3 SD-card image (downloads the pinned [Pi 3 UEFI firmware](https://github.com/pftf/RPi3/releases/tag/v1.53.1)) |
| `make rom-generic` | `build/rom-generic/`: `ARMDOS.EFI` (kernel with a built-in read-only A:), `armdos-rom.itb` (FIT image for U-Boot) and `armdos-rom-flash.bin` (64 MiB NOR flash image); needs `mkimage` from u-boot-tools |
| `make rom-pi` | `build/rom-pi/`: `armdos-rom-pi3.img` and `armdos-rom-pi4.img`, 64 MiB Pi 3 and Pi 4 boot images with the ROM build (downloads the pinned Pi 3 and [Pi 4 UEFI firmware](https://github.com/pftf/RPi4/releases/tag/v1.42)) |
| `make clean` | Removes `build/` |

`CROSS_COMPILE` selects the binutils prefix (default `aarch64-linux-gnu-`).
`FIRMWARE=/path/to/QEMU_EFI.fd` points the test targets at the UEFI firmware
(default `/usr/share/qemu-efi-aarch64/QEMU_EFI.fd`).

Without root on a Debian 13 x86_64 machine, `bash tools/setup-cloud.sh`
installs binutils, QEMU, the UEFI firmware, mtools, dosfstools and xorriso into `/workspace/arm-toolchain`, with isolated APT
state and verified package hashes, and `source tools/env.sh` puts them on
`PATH`; then pass
`FIRMWARE=/workspace/arm-toolchain/runtime/usr/share/qemu-efi-aarch64/QEMU_EFI.fd`.

### Repository layout

| Path | Contents |
| --- | --- |
| `src/` | The kernel: boot, platform drivers (PL011, virtio-blk, virtio-net, SDHCI), FAT12/16/32, DOS functions, COMMAND, `CONFIG.SYS` |
| `programs/` | The utilities and ARM BASIC, one `NAME.S` per `NAME.EXE` |
| `drivers/` | Installable drivers (`ANSI.SYS`, `RAMDRIVE.SYS`, `VDISK.SYS`, `PRINTER.SYS`, `TESTDRV.SYS`) |
| `data/country/` | The MS-DOS 4.0 country tables (`MKCNTRY.ASM` data segment) that `COUNTRY.SYS` is built from |
| `fixtures/` | Files copied onto the test disk image (batch files, `CONFIG.SYS`, `PRIMES.BAS`, ...) |
| `tools/` | Image, ISO and PE32+ packagers, the QEMU launcher and the test drivers |
| `tests/` | Host-side FAT tests and the bare-metal Pi 3 driver test |
| `images/` | Where `tools/fetch_release.py` puts release downloads (not committed; images are on the [Releases page](https://github.com/abdonmorales/MS-DOS-arm/releases/latest)) |
| `.github/workflows/` | CI on every push and pull request, a nightly fuzz/validate run, and the tag-triggered Release build |
| [ABI.md](ABI.md) | The native program ABI: every DOS function from 00h to 6Ch |
| [PORT_STATUS.md](PORT_STATUS.md) | Definition of done and milestone status |

## Testing

| Command | Checks |
| --- | --- |
| `make unit` | Host-side unit tests in about 6 seconds: kernel routines run in the Unicorn emulator (`pip install unicorn`) against Python references, and the device tree parser against trees built by `dtc` (device-tree-compiler; skipped without it) |
| `make smoke` | Boots the test image in QEMU and checks about 330 console commands in native mode, then `fsck.fat` on the disk; then a second boot with five more virtio-blk disks (MBR with an extended partition, GPT, corrupt tables, a blank disk) checks `DIR`, `COPY` across drives, `CHKDSK` and a native `INSTALL`, and runs `fsck.fat` on every volume |
| `make smoke-firmware` | The same checks with ACPI hidden, so the kernel stays in firmware mode |
| `make fat-test` | Stress-tests `src/fat.S` on FAT12/16/32 images under `qemu-aarch64` (needs `gcc-aarch64-linux-gnu`, `libc6-dev-arm64-cross`, `qemu-user`) |
| `make pi-test` | The Pi 3 SD-card and UART drivers, bare metal on QEMU `raspi3b` |
| `make net-test` | virtio-net, the E1h packet driver and `TFTP.EXE` on QEMU user networking: GET from slirp's TFTP server (100 KiB, checked by hash), PUT, netascii and lost/duplicate packets against a small server in the test |
| `make fb-test` | The framebuffer console: QEMU `virt` with `ramfb` and the Pi mailbox framebuffer on `raspi3b`, screens read back with `screendump` and decoded against the font |
| `make iso-test` | Live boot as CD and USB stick, `INSTALL` to blank disks, a boot of the installed disk, and a reproducible ISO |
| `make validate` | Both disk images: FAT checks, payload comparison and a QEMU boot; writes `build/validation.json` |
| `make rom-test` | Boots the ROM builds in QEMU `virt`: network boot under EDK2 (ACPI and device tree), U-Boot from NOR flash, the Pi build in firmware mode; checks that A: refuses every write, and the Pi images' contents (needs `u-boot-qemu`, `u-boot-tools`) |
| `make check` | `unit`, `pi-test`, then `smoke` |
| `make snapshot` | `validate` and `iso-test`, then packages the validated images, ISO and `SHA256SUMS` into `build/release/` (`SNAPSHOT_DIR=`), the asset set of a GitHub Release |

Each boot also runs a self-test of the DOS API against real files on disk;
a `SELFTEST PASS` line at boot means it passed.

## Live ISO and INSTALL

The live ISO starts the normal ARM DOS prompt without installing anything:

- Drive A: is the ISO itself and is **read-only**.
- `CONFIG.SYS` on the ISO loads one 1 MiB RAM disk, B:, for scratch files.
  It is empty again after a restart.
- The ISO carries the release file set; the test fixtures of the disk image
  are left out.

`INSTALL` (`INSTALL.EXE`) copies ARM DOS to a writable disk, as SELECT did
for DOS 4. It lists the disks the firmware offers, apart from the one ARM DOS
started from, and asks which one to use and for confirmation. Then it writes
an MBR with one partition of type EFh (from 1 MiB, at most 2000 MB), formats
it with `FORMAT d: /SELECT /V:ARMDOS` and copies every file from A: with
`XCOPY`, the boot loader `\EFI\BOOT\BOOTAA64.EFI` included.

- **Everything on the chosen disk is erased.** ENTER at the disk question,
  or N at the confirmation, leaves the disks untouched.
- `INSTALL n /Y` picks disk n without asking, for scripts; `/Y` without a
  disk number is refused.
- From the live ISO (firmware mode) it offers the disks the firmware
  offers. Under the native kernel it offers the other virtio-blk disks from
  the kernel's disk table; a disk whose volumes are already drive letters is
  refused.

## Fixed disks and drive letters

In native mode the kernel mounts every FAT volume it finds on the boot disk
(besides A:) and on every other virtio-blk disk: MBR partitions of type 01h,
04h, 06h, 0Bh, 0Ch, 0Eh and EFh, logical drives in an extended partition,
GPT EFI System and Basic Data partitions, and unpartitioned FAT disks. They
take C:, D:, ... at boot, before `CONFIG.SYS`; B: stays free for the first
RAM disk, and `RAMDRIVE`/`VDISK` drives take the letters after the disks.
The boot banner lists them (`Drive C: is disk 1, partition 1`). The disk
table also takes other block backends; see [ABI.md](ABI.md), "Native disk
table".

The ISO boots on any ARM64 UEFI machine or VM, from a virtual CD or written
to a USB stick. A Raspberry Pi does not boot it; use the SD-card image or a ROM build
there.

## ARM BASIC

`BASIC` (`BASIC.EXE`, from `programs/basic.S`) is ARM BASIC, an interpreter
in the style of the Microsoft BASICs that came with MS-DOS, written from
scratch in AArch64 assembly. Type numbered lines to build a program and
statements without a number to run them at once; `Ok` is the prompt.
`BASIC PRIMES` loads `PRIMES.BAS` and runs it.

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
program text). Strings and program lines hold up to 255 bytes. Variable
names are significant to 14 characters, and arrays (`DIM A(100)`, `A$(n)`)
have one dimension. Ctrl-C stops a running program (`Break in 30`); at an
`INPUT` prompt it takes effect when ENTER is pressed. Errors use the
GW-BASIC messages (`Syntax error in 20`).

## Using ARM DOS

**COMMAND internal commands:** `HELP`, `VER`, `ECHO`, `CLS`, `DIR`, `TYPE`,
`DEL`/`ERASE`, `CD`/`CHDIR`, `MD`/`MKDIR`, `RD`/`RMDIR`, `COPY`,
`REN`/`RENAME`, `DATE`, `TIME`, `VOL`, `SET`, `PATH`, `PROMPT`, `FOR`,
`SHIFT`, `REM`, `CALL`, `GOTO`, `IF`, `PAUSE`, `VERIFY`, `BREAK`, `CTTY`,
`CHCP`, `TRUENAME`, `SELFTEST` and `EXIT`. `EXIT` powers the machine off in
native mode and returns to UEFI in firmware mode.

**Utilities** (each a native `NAME.EXE`): `APPEND`, `ASSIGN`, `ATTRIB`,
`BACKUP`, `CHKDSK`, `COMP`, `DISKCOMP`, `DISKCOPY`, `EDLIN`, `FC`, `FIND`,
`FORMAT`, `JOIN`, `LABEL`, `MEM`, `MORE`, `RECOVER`, `REPLACE`, `RESTORE`,
`SORT`, `SUBST`, `SYS`, `TREE` and `XCOPY`, plus `INSTALL` and `BASIC`.

**Drivers and `CONFIG.SYS`:** `BREAK`, `BUFFERS`, `COUNTRY`, `DEVICE`,
`FCBS`, `FILES`, `INSTALL`, `LASTDRIVE`, `REM`, `SHELL` and `STACKS`.
`DEVICE=` loads native drivers: `ANSI.SYS` (escape sequences and key
reassignment over the serial terminal), `RAMDRIVE.SYS` and `VDISK.SYS` (RAM
disks) and `PRINTER.SYS` (PRN to the serial line). `COUNTRY.SYS` gives
`COUNTRY=` and `CHCP` the DOS 4.0 countries and code pages.

**Shell features:** quoted paths, drive letters and DOS device names (`CON`,
`AUX`, `PRN`, `NUL`, `CLOCK$`); `DIR` in the DOS 4.0 layout with `/W` and
`/P`; wildcard `COPY`, `DEL` and `REN` with rename templates; VFAT long
names; `<`, `>`, `>>` and pipes; and batch files with `%0`-`%9`, `%NAME%`,
`FOR`, `IF`, `GOTO`, `CALL`, `SHIFT` and `ECHO`. `\AUTOEXEC.BAT` runs at
boot; without it the shell asks for the date and time, as COMMAND did.
Commands are limited to 255 bytes and `CALL` nesting to 16 scripts; a batch
file started from another without `CALL` replaces it. The [ABI](ABI.md) has
the full detail.

## ROM builds (Raspberry Pi and embedded boards)

A ROM build turns ARM DOS into a 1980s-style ROM machine: the kernel and a
read-only drive A: (every program, driver, ARM BASIC and `PRIMES.BAS`) are
one EFI application, `ARMDOS.EFI`, about 600 KiB. The kernel serves A:
straight from its own memory, so it needs no disk and never writes one, and
B: is a 4 MiB RAM disk for scratch files that is empty again after a
restart. Every write to A: is refused (`File/device error.`) and leaves it
unchanged.

```
Platform: native AArch64 kernel (firmware exited; console UART at 0000000009000000, A: in ROM)
Storage: native FAT12 driver over the built-in ROM disk (read-only)
ROM system: drive A: is built in and read-only; B: is a RAM disk whose
files last until power-off.
```

Because it is a single file, the same `ARMDOS.EFI` boots every way the
firmware can load an EFI application:

- **From an SD card or USB stick:** as `\EFI\BOOT\BOOTAA64.EFI` on any FAT
  volume.
- **Over the network:** offered as the boot file by a PXE or HTTP boot server
  (`make rom-test` boots it this way through QEMU's TFTP server).
- **From SPI/NOR flash through U-Boot:** `armdos-rom.itb` is a FIT image with
  `ARMDOS.EFI` as an `efi` kernel. Write it to the board's flash, then:

  ```
  sf probe; sf read ${kernel_addr_r} <flash offset> 0x100000; bootm ${kernel_addr_r}
  ```

  (on memory-mapped NOR, `cp.b <flash address> ${kernel_addr_r} 0x100000`
  instead of `sf read`; 0x100000 bytes covers the FIT image, which is about
  610 KiB). Set that line as `bootcmd` to boot ARM DOS at power
  on. `bootefi` can also start `ARMDOS.EFI` directly. In QEMU:

  ```sh
  qemu-system-aarch64 -machine virt -cpu cortex-a72 -m 256 -nographic \
    -bios /usr/lib/u-boot/qemu_arm64/u-boot.bin \
    -drive if=pflash,unit=1,format=raw,readonly=on,file=build/rom-generic/armdos-rom-flash.bin
  # at the U-Boot prompt:
  => cp.b 0x04000000 ${kernel_addr_r} 0x100000; bootm ${kernel_addr_r}
  ```

**Native mode on any board.** With A: in memory, leaving the firmware needs
only a console UART, so a ROM build can run natively on boards ARM DOS has
no disk driver for. It finds the UART through ACPI SPCR or, on device-tree
firmware such as U-Boot, through `/chosen` `stdout-path` (PL011, SBSA UART,
16550/8250 including DesignWare, and the BCM2835 mini UART; bus `ranges` are
followed). Native mode is opt-in: it is used only when the ROM disk holds
`\NATIVE.ON`, and then the console is the serial UART only (HDMI and USB
keyboards stop once the firmware is left). Without it, or with a UART the
kernel does not know, the build stays in UEFI firmware mode and uses the
firmware's screen and keyboard. `make rom-generic` puts `NATIVE.ON` on its
ROM disk by default and `make rom-pi` does not:

| Target | Boards | `NATIVE.ON` by default |
| --- | --- | --- |
| `make rom-generic` | Any ARM64 board with UEFI firmware: EDK2, or U-Boot with its UEFI support (on by default for ARM64 boards) | Yes (`GENERIC_NATIVE=0` to turn off): embedded boards usually have a serial console |
| `make rom-pi` | Raspberry Pi 3B/3B+ and Pi 4B/400/CM4, with the pinned [pftf](https://github.com/pftf) UEFI firmware | No (`PI_NATIVE=1` to turn on): the Pi is usually used with HDMI and a USB keyboard |

Write `armdos-rom-pi3.img` or `armdos-rom-pi4.img` to an SD card or USB stick
(at least 64 MiB) with Raspberry Pi Imager's custom-image option. (A Pi 3B,
unlike the 3B+ and the Pi 4, boots from USB only after its USB boot bit has
been set once from Raspberry Pi OS.) The Pi's
real boot ROM is inside the chip and cannot be replaced, and on the Pi 4 the
EEPROM holds only the Pi's own bootloader, so a card that DOS never writes
is the closest the Pi comes to a ROM OS. The Pi 5 has no supported UEFI
firmware yet. Microcontrollers (Cortex-M) cannot run ARM DOS, which needs a
64-bit Cortex-A core.

The ROM disk's files are the release file set of the live ISO
(`tools/release.py`), with a `CONFIG.SYS` that makes B: 4 MiB and an
`AUTOEXEC.BAT` that runs `VER`; `tools/romdisk.py` builds it. To ship your
own programs, add them to the disk image (or edit `tools/romdisk.py`) and
rebuild. Pipes (`a | b`) keep their temporary files in the current drive's
root, as COMMAND did, so they need a writable drive: switch to B: first
(`B:`), as on the live ISO. **The ROM builds have been tested in QEMU (EDK2 and U-Boot) only,
not yet on a physical board.**

## How it works

UEFI is only the boot loader. At startup the kernel finds its console UART
(ACPI SPCR) and its boot disk (ACPI MCFG, PCI ECAM, virtio-blk), reserves its
memory, calls `ExitBootServices` and owns the machine from then on: its own
exception vectors, polled PL011 console, virtio-blk driver, FAT12/16/32
filesystem (`src/fat.S`), memory arena and PE32+ program loader
(`src/platform.S`, `src/process.S`). On boards it has no drivers for, it
stays in firmware mode and uses UEFI for the console, memory and sectors; the
banner's `Platform:` line says which mode is active. In native mode no UEFI
boot service is used after startup; UEFI runtime services are used only for
power-off. DATE and TIME settings persist in the real-time clock (the PL031
on QEMU `virt`, UEFI `SetTime` in firmware mode). Native mode on other
boards does not persist the clock yet, and the Pi 3 has no battery-backed
clock.

Programs call DOS through a function pointer handed to each process, using
AAPCS64; the [ABI](ABI.md) documents every function from 00h to 6Ch
(console and device I/O, handle and FCB files, SHARE locking, IOCTL, exec,
memory allocation, country information and more). FCB records keep their
standard 37-byte layout. These adapt the public contracts of the MS-DOS 4.0
kernel sources (`CPMIO.ASM`, `HANDLE.ASM`, `FILE.ASM`, `PATH.ASM`,
`FCBIO.ASM`, `ALLOC.ASM`, `PROC.ASM`, `LOCK.ASM`, `IOCTL.ASM`, `DOSMES.ASM`
and others) and COMMAND; their internal algorithms were not translated line
for line.

`src/fat.S` implements FAT12, FAT16 and FAT32: cluster chains, FAT
mirroring, directory growth, VFAT long names with `~N` short aliases, and a
small write-through sector cache, so every update is on disk before a call
returns. It runs over the kernel's virtio-blk or SDHCI driver in native mode
and over UEFI Block I/O in firmware mode. If the boot volume is read-only or
not FAT, the firmware's file system is used instead.

Networking: in native mode on QEMU `virt` (or any machine with a virtio-net
PCI device) the kernel drives the NIC itself (`src/vnet.S`, polled) and
offers whole Ethernet frames to programs through the packet driver call E1h
([ABI](ABI.md)). `TFTP.EXE` brings its own ARP, IPv4 and UDP:
`TFTP [-i] host[:port] GET|PUT source [destination]`, configured by the
environment variables `IP`, `NETMASK` and `GATEWAY` (defaults suit QEMU's
`-netdev user`: 10.0.2.15/24 via 10.0.2.2; no DHCP). Add
`-netdev user,id=n0,tftp=DIR -device virtio-net-pci,netdev=n0` to QEMU and
`TFTP -i 10.0.2.2 GET FILE` fetches `DIR/FILE`; QEMU's built-in server is
read-only and binary only. Firmware mode has no network.

## Raspberry Pi 3

`make pi-image` builds a 128 MiB SD-card image for the Pi 3B/3B+ (not
Pi 4/5) with the pinned, hash-checked [Pi 3 UEFI
firmware](https://github.com/pftf/RPi3). Write it with Raspberry Pi
Imager's custom-image option to a card of at least 128 MiB. By default the
Pi stays in firmware mode. To try the native drivers (PL011 or mini UART
console, SD card on the Arasan SDHCI), create an empty `NATIVE.ON` in the
card's root; the banner then reads `Raspberry Pi 3 UART console, SD card`.
In that mode the console is the serial UART on GPIO 14/15 only: HDMI and
USB keyboards stop working once the firmware is left, so attach a serial
adapter. If the card cannot be restarted after leaving the firmware, the
kernel prints `Boot disk did not restart after leaving firmware` and halts;
delete `NATIVE.ON` to go back to firmware mode. **This has not been tested
on a physical board.**
First-boot checklist, serial wiring and debug checkpoints: [docs/PI3-BRINGUP.md](docs/PI3-BRINGUP.md).

## Native Apple Silicon boot

Running under QEMU on a Mac is supported. Booting ARM DOS directly on Mac
hardware is not: a raw image lacks Apple's boot authorization, m1n1, device
trees and U-Boot, and this repository does not touch the Mac boot chain. On
a model that already has a working Asahi m1n1/U-Boot installation, the
generic EFI image is a candidate external boot payload through U-Boot's USB
boot flow (see the [Asahi U-Boot guide](https://asahilinux.org/docs/sw/u-boot/));
this is untested.

## Status

Milestones 1-7 of [PORT_STATUS.md](PORT_STATUS.md) (kernel, DOS functions,
COMMAND, `CONFIG.SYS`, every utility, drivers, NLS) are done, and QEMU
`virt` runs fully native. What remains is milestone 8: booting the Pi 3
image and its native drivers on a real board. Until then the image manifests
keep `complete_msdos_port` false.

## Documentation

- [docs/COMMANDS.md](docs/COMMANDS.md): every COMMAND internal command and
  utility, batch files, `CONFIG.SYS` and the drivers
- [docs/BASIC.md](docs/BASIC.md): the ARM BASIC language
- [docs/PROGRAMMING.md](docs/PROGRAMMING.md): writing native ARM64 programs
  and drivers
- [ABI.md](ABI.md): the DOS function reference for programs
- [SECURITY.md](SECURITY.md): the security model and how to report a
  vulnerability
- [CHANGELOG.md](CHANGELOG.md): release history

## Origin and license

ARM DOS is a fork of Microsoft's [MS-DOS source
release](https://github.com/microsoft/MS-DOS), which published the MS-DOS
1.25, 2.0 and 4.0 sources. The original x86 sources were the reference for
this port and are no longer kept in this repository; read them in the
upstream repository. The only files carried over are the MS-DOS 4.0 country
tables in `data/country/`, which `COUNTRY.SYS` is built from.

All files are released under the MIT License; see [LICENSE](LICENSE)
(Copyright (c) Microsoft Corporation); the ARM DOS code is released under
the same license (the assembly sources carry `SPDX-License-Identifier: MIT`). The ISO
and disk images carry it as `LICENSE.TXT` (`DOS-MIT.TXT` on the Pi image). The Pi image also bundles the
upstream Raspberry Pi UEFI firmware under its own licenses, included in the
image; see [images/README.md](images/README.md).

### Trademarks

This project may contain trademarks or logos for projects, products, or
services. Authorized use of Microsoft trademarks or logos is subject to and
must follow [Microsoft's Trademark & Brand
Guidelines](https://www.microsoft.com/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project
must not cause confusion or imply Microsoft sponsorship. Any use of
third-party trademarks or logos are subject to those third-party's policies.
ARM DOS is not affiliated with or endorsed by Microsoft or Arm.
