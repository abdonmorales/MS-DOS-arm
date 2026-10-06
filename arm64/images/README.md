# Validated AArch64 development disk snapshots

These snapshots are an **incomplete MS-DOS 4.0 AArch64 port**, using UEFI Boot
Services. They contain native ARM64 assembly, a separately linked native test
program and batch fixtures. They do not run historical x86 executables.

| Download | Expanded size | Intended platform |
| --- | --- | --- |
| [msdos-arm64.img.xz](msdos-arm64.img.xz) | 64 MiB | AArch64 UEFI VM; candidate external payload on supported, preconfigured Apple m1n1/U-Boot |
| [msdos-arm64-pi3.img.xz](msdos-arm64-pi3.img.xz) | 128 MiB | Pi 3B/3B+ with bundled Pi UEFI firmware |

Each image passed FAT consistency checks, build-payload comparisons, native API
integration checks and 120 console checks under QEMU AArch64 `virt`/UEFI.
For the Pi image, this validates FAT32 and the DOS payload through generic UEFI;
it does not validate Pi ROM/VideoCore boot or physical hardware drivers.
[validation.json](validation.json) records hashes and the tested scope.
**Physical Pi and native Apple hardware have not been tested. Native boot on
all Apple Silicon models remains unsupported.** The generic image does not
install Apple's boot authorization, m1n1 or U-Boot.

Verify the `.img.xz.sha256` sidecar, then decompress with `xz -dk image.img.xz`
and verify the `.img.sha256` sidecar. Use the raw generic image as a writable
UEFI VM disk. Use Pi Imager's custom-image workflow with the Pi 3 image and the
intended removable card. No device is flashed by the build scripts.
See [platform instructions and limits](../README.md).

The DOS sources and binaries are MIT licensed (`LICENSE.TXT` on the generic
disk; `DOS-MIT.TXT` on Pi). The Pi image includes upstream
[RPi3 UEFI firmware v1.53.1](https://github.com/pftf/RPi3/releases/tag/v1.53.1),
with its licenses/notices in `LICENSE.TXT`, `BROADCOM.TXT` and `firmware/`.
Firmware source/build references are provided by the upstream project's release
and [repository](https://github.com/pftf/RPi3). Those firmware licenses apply
to the bundled third-party files; they are not relicensed by this repository.

To regenerate, activate/install the cross tools and run:

```sh
make -C arm64 snapshot FIRMWARE=/path/to/QEMU_EFI.fd
```

The snapshot tool refuses stale validation when source or image bytes change.
Raw build products stay under ignored `arm64/build`; these compressed snapshots
are committed on the `arm` branch for download.
