# MS-DOS 4.0 AArch64 development port

The `arm` branch adds a **partial native AArch64 port**, written in ARM64
assembly. It is not a completed conversion of MS-DOS 4.0. The historical source
archives stay intact as the reference for further migration.

The current runtime is a UEFI application with DOS-style services and a command
console. UEFI supplies the hardware and FAT filesystem backend. It remains in
the firmware environment; it is not yet an independent kernel that calls
`ExitBootServices`, owns exception vectors, or implements its own device drivers.
It contains no Linux guest, x86 interpreter, or x86 executable emulation.

## Build and run

On Debian/Ubuntu, install GNU AArch64 binutils, Python 3, Make, QEMU's ARM system
emulator and ARM64 UEFI firmware. The Pi image additionally uses mtools and
dosfstools. The equivalent package names are:

```sh
binutils-aarch64-linux-gnu qemu-system-arm qemu-efi-aarch64 mtools dosfstools
```

In the prepared cloud environment:

```sh
cd /workspace/MS-DOS-arm
source arm64/tools/env.sh
make -C arm64 image
make -C arm64 smoke FIRMWARE=/workspace/arm-toolchain/runtime/usr/share/qemu-efi-aarch64/QEMU_EFI.fd
```

To reproduce the tool installation on the same Debian 13 x86_64 cloud base,
run `bash arm64/tools/setup-cloud.sh`. It uses isolated APT state, signed Debian
metadata and verified package hashes, extracts tools only into `/workspace`,
and runs the actual image smoke test. Firmware and runtime libraries remain
separate from the repository. It does not configure Apple or Raspberry Pi
hardware, install system packages, or change credentials.

With system-installed tools, omit `source` and supply the installed firmware
path. `CROSS_COMPILE` can select another GNU AArch64 prefix, such as
`aarch64-elf-`; the application uses ARMv8-A instructions and AAPCS64 throughout.

```sh
make -C arm64 image CROSS_COMPILE=aarch64-elf-
python3 arm64/tools/run.py arm64/build/msdos-arm64.img --firmware /path/to/QEMU_EFI.fd
```

The runner chooses QEMU's `hvf` accelerator and `host` CPU on Apple Silicon
macOS, or `tcg` and Cortex-A72 elsewhere. The cloud validation used TCG on x86_64;
HVF and UTM have not been tested here. UTM can use an ARM64 VM with UEFI firmware
and the raw disk as a writable VirtIO drive. This image requires a writable FAT
volume for its boot self-test.

Commands: `HELP`, `VER`, `ECHO`, `CLS`, `DIR`, `TYPE`, `DEL`, `SELFTEST`, `EXIT`.
`TYPE` currently displays ASCII text. Directory enumeration is the root directory;
long filenames are provided by the firmware. Command parsing supports simple
space-separated arguments, without DOS quoting, wildcards or redirection.

Each boot runs real native API tests: version and invalid-function results,
allocation/free, reading a known disk file, creating/writing/reopening/deleting
a scratch file, and checking the deleted file cannot reopen. `ARMCHK.TMP` is a
reserved scratch name. The self-test refuses to overwrite it if it already
exists. Smoke tests boot a temporary image copy and check eight console requests.

## Disk images

| Image | Format | Verified scope |
| --- | --- | --- |
| `build/msdos-arm64.img` | 64 MiB MBR/FAT16, ARM64 EFI application | Boots in QEMU `virt`; API and console tests pass |
| `build/msdos-arm64-pi3.img` | 128 MiB MBR/FAT32, Pi 3 boot files and UEFI firmware | Firmware/package structure checked; same payload tested through ARM64 UEFI; physical Pi boot unverified |

Both images include `EFI/BOOT/BOOTAA64.EFI`, `ARMTEST.TXT`, a SHA-256 sidecar and
a JSON manifest. The manifests explicitly record incomplete port status and
unverified physical hardware. Build products are ignored by Git.

Build the Pi image with:

```sh
make -C arm64 pi-image
```

The packager downloads [Pi 3 UEFI firmware v1.53.1](https://github.com/pftf/RPi3/releases/tag/v1.53.1)
over verified HTTPS and checks its pinned SHA-256 before extracting. It preserves
upstream config and filenames, includes firmware licenses, and uses the Pi's
required FAT LBA partition type instead of EFI partition type `0xef`. It refuses
to overwrite an existing image; remove only the previously generated Pi build
image when deliberately rebuilding. This image targets Pi 3B/3B+, not Pi 4/5.

To prepare an SD card, select the Pi image and the intended removable card in
Raspberry Pi Imager's custom-image workflow. Use a card of at least 128 MiB.
The firmware console can use HDMI/USB input or a supported serial console.
No physical disk was flashed during this task.

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
of this DOS runtime. The user requested all models; that remains an unmet
hardware-support requirement, not a claimed feature.

## Ported API and remaining work

`dos_call` uses `w8` for the DOS function number and `x0`–`x3` for native
arguments/results. It is an AAPCS64 function call, not an installed `SVC` handler.
`x1=0` indicates success; `x1=1` indicates error with a DOS error in `x0`.
Pointers are flat 64-bit addresses. Original DOS binaries and segmented FCB/PSP
layouts are incompatible with this ABI.

| DOS function | Native implementation | Current limit |
| --- | --- | --- |
| `02h` | Console character output | Firmware console |
| `09h` | `$`-terminated console string | Also stops at NUL |
| `30h` | Version 4.00 and identity | No fake-version/compatibility state |
| `3Ch` | Create/truncate, return native file handle | Only attributes zero |
| `3Dh` | Open with read/write modes | Basic modes 0, 1, 2; no sharing flags |
| `3Eh` | Close file | Native handles 5–31 |
| `3Fh` | Read file | Console input handles pending |
| `40h` | Write/flush file or console | Zero-length file truncate pending |
| `41h` | Delete file | No wildcards |
| `48h` | Allocate firmware pool | Native byte size rather than DOS paragraphs |
| `49h` | Free firmware pool | No DOS arena/owner semantics |

All other calls return invalid-function errors. The version and character
services adapt behavior from `v4.0/src/DOS/GETSET.ASM` and `CPMIO.ASM`. File and
memory APIs follow selected external contracts from `HANDLE.ASM`, `FILE.ASM`
and `ALLOC.ASM`, replacing their implementation with a UEFI backend; their
original internal algorithms have not been translated.

The complete MS-DOS 4.0 rewrite remains unfinished. Major remaining pieces are
FCB and full handle services, hierarchical filesystem/paths and FAT drivers,
PSP/process loading and termination, memory arenas, interrupt/device APIs,
dates/time/NLS, CONFIG.SYS and batch handling, command-shell compatibility,
drivers and utilities. DOS `.COM`/`.EXE` software needs a separately designed
compatibility layer or recompilation. Keeping these limitations explicit is
necessary: the working boot images demonstrate a port foundation, not completion
of the requested operating-system rewrite.

Reference boot documentation was inspected at Asahi docs commit
`0d1f8917fa88745d62a4c05d802c4a7298c8616b` and Pi UEFI commit
`671c48c7a99c3c5664b347c938e4190ad6aa255f`.
