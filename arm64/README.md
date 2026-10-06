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

Commands: `HELP`, `VER`, `ECHO`, `CLS`, `DIR`, `TYPE`, `DEL`, `CD`/`CHDIR`,
`MD`/`MKDIR`, `RD`/`RMDIR`, `COPY`, `REN`/`RENAME`, `ATTRIB`, `DATE`, `TIME`,
`REM`, `CALL`, `GOTO`, `IF`, `SELFTEST`, `EXIT`. Native AArch64 `.EXE` and `.BAT`
files also run from the shell; `NATIVE.EXE` is a separately linked example.

Paths support quotes, relative components, `.`/`..`, and drive `A:`. `DIR` accepts
directories and case-insensitive `*`/`?` glob patterns, including DOS `*.*`.
This is not the full DOS 8.3 wildcard algorithm. Long ASCII filenames use the
firmware backend. Redirection supports `<`, `>`, `>>`, including nested scripts
and native programs. Pipes, `2>` and DOS device names remain unsupported.
`COPY` currently takes a single source and destination filename.

Batch files support `%0`–`%9`, `%*`, `%%`, `%ERRORLEVEL%`, `%PATH%`, `%COMSPEC%`,
`ECHO ON/OFF`, `@`, `REM`, `CALL`, `GOTO`, `IF [NOT] EXIST/ERRORLEVEL`, and
`EXIT /B`. Commands are limited to 255 bytes and nesting to 16 scripts.
`FOR`, `SHIFT`, `SET`, string-comparison `IF`, and general environment editing
remain unimplemented. `DATE`/`TIME` display the DOS clock; API setters change
only the runtime clock. `EXIT` returns to UEFI after unwinding shell state.

Each boot runs native API integration tests against actual files on disk:
FCB records, partial EOF padding, paths, search buffers, attributes, file times,
seek/truncate/duplicate handles, allocation ownership and resizing, clock leap
years and rollover, native and nested process loading, termination, and parent
handle preservation. Reserved scratch names are `ARMCHK.TMP`, `ARMFCB.TMP` and
`ARMAPI.TMP` (a directory). The test refuses to overwrite existing objects with
those names and restores the starting directory. Smoke tests boot a temporary
image copy and check 120 console requests, including 70 successive native
launches that deliberately leave resources for process cleanup, buffered input
with backspace editing, batch control flow, and redirection restoration.

## Disk images

| Image | Format | Verified scope |
| --- | --- | --- |
| `build/msdos-arm64.img` | 64 MiB MBR/FAT16, ARM64 EFI application | Boots in QEMU `virt`; API and console tests pass |
| `build/msdos-arm64-pi3.img` | 128 MiB MBR/FAT32, Pi 3 boot files and UEFI firmware | Firmware/package structure checked; same payload tested through ARM64 UEFI; physical Pi boot unverified |

Both images include `EFI/BOOT/BOOTAA64.EFI`, `NATIVE.EXE`, batch fixtures,
`ARMTEST.TXT`, a SHA-256 sidecar and a JSON manifest. The manifests explicitly record incomplete port status and
unverified physical hardware. Raw build products are ignored by Git. Compressed, validated image snapshots
and their checksums are published in [images](images/README.md) on the `arm` branch.

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
No physical disk was flashed during this task.

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
of this DOS runtime. The user requested all models; that remains an unmet
hardware-support requirement, not a claimed feature.

## Native API and remaining work

The [AArch64 ABI](ABI.md) documents all 57 dispatched function numbers, their
arguments, return values and limits. Calls use AAPCS64 and a function pointer
provided to each native process. FCB records retain their standard 37-byte data
layout; pointers and process/search structures use the native ABI. Original x86
executables cannot run.

The runtime now provides basic console/input, file and standard-handle
redirection, hierarchical paths, find-first/next state, standard FCB sequential
and random records, owned memory with in-place resizing, DOS date/time,
file timestamps, native process loading/termination, and a batch interpreter.
These adapt selected public contracts from `CPMIO.ASM`, `GETSET.ASM`,
`HANDLE.ASM`, `FILE.ASM`, `PATH.ASM`, `SEARCH.ASM`, `FCBIO.ASM`, `TIME.ASM`,
`ALLOC.ASM`, `PROC.ASM` and `COMMAND`. Their original internal algorithms have
not been fully translated. Hardware and storage still use UEFI Boot Services.

The complete MS-DOS 4.0 rewrite remains unfinished. Outstanding work includes
full FCB/block/wildcard services, sharing/locking and extended handle APIs,
DOS memory-control-block/PSP compatibility, interrupts and device-driver ABI,
FAT/cache/block drivers independent of firmware, NLS/codepages, CONFIG.SYS,
full COMMAND syntax/environment handling, historical drivers and utilities,
and physical hardware bring-up. The checked-in historical source archives
remain x86 assembly. All-model native Apple Silicon support also remains unmet
because required boot-stack/driver support and hardware validation are absent.
These image snapshots are development artifacts, with incomplete status recorded
in their manifests; they are not a completed operating-system conversion.

Reference boot documentation was inspected at Asahi docs commit
`0d1f8917fa88745d62a4c05d802c4a7298c8616b` and Pi UEFI commit
`671c48c7a99c3c5664b347c938e4190ad6aa255f`.
