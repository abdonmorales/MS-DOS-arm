# ARM DOS disk image snapshots

These snapshots are ARM DOS, MS-DOS 4.0 ported to AArch64, with every software
milestone done; physical hardware (milestone 8) is not yet verified, so their
manifests still record the port as incomplete. They contain native ARM64 assembly, a separately linked native test
program and batch fixtures. They do not run historical x86 executables.

| Download | Expanded size | Intended platform |
| --- | --- | --- |
| [msdos-arm64.img.xz](msdos-arm64.img.xz) | 64 MiB | AArch64 UEFI VM; candidate external payload on supported, preconfigured Apple m1n1/U-Boot |
| [msdos-arm64-pi3.img.xz](msdos-arm64-pi3.img.xz) | 128 MiB | Pi 3B/3B+ with bundled Pi UEFI firmware |
| [armdos.iso](armdos.iso) | 30 MiB (not compressed) | Live ISO for any ARM64 UEFI machine or VM (QEMU, UTM): read-only A:, `INSTALL` to a disk. Not for the Pi |

Each image passed FAT consistency checks, build-payload comparisons, native API
integration checks and the console checks counted in
[validation.json](validation.json) under QEMU AArch64 `virt`/UEFI,
with the native kernel (firmware exited) serving the disk and `fsck.fat` clean
afterwards.
For the Pi image, this validates FAT32 and the DOS payload through generic UEFI;
it does not validate Pi ROM/VideoCore boot or physical hardware drivers.
[validation.json](validation.json) records hashes and the tested scope.
**Physical Pi and native Apple hardware have not been tested. Native boot on
all Apple Silicon models remains unsupported.** The generic image does not
install Apple's boot authorization, m1n1 or U-Boot.

The ISO is packaged only after `make iso-test` passed on its exact bytes
(live boot as a CD and USB stick, `INSTALL` to a blank disk and a boot of
that disk); see [Live ISO and INSTALL](../README.md#live-iso-and-install).

The ISO is published uncompressed: download `armdos.iso`, check it against
`armdos.iso.sha256` (`sha256sum -c armdos.iso.sha256`) and boot it directly.
The disk images stay compressed (the Pi image alone is 128 MiB, over GitHub's
file size limit). Verify the `.img.xz.sha256` sidecar, then decompress with
`xz -dk image.img.xz` and verify the `.img.sha256` sidecar. Use the raw generic
image as a writable UEFI VM disk. Use Pi Imager's custom-image workflow with the Pi 3 image and the
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
make snapshot FIRMWARE=/path/to/QEMU_EFI.fd
```

The snapshot tool refuses stale validation when source or image bytes change.
Raw build products stay under the ignored `build/` directory; these
snapshots are committed to the repository for download.
