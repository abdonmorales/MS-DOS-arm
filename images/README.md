# ARM DOS images

Prebuilt images are published on the
**[Releases page](https://github.com/abdonmorales/MS-DOS-arm/releases/latest)**,
not committed to the repository. This folder is where
`tools/fetch_release.py` puts them; everything here except this README is
ignored by Git.

| Release asset | Expanded size | Intended platform |
| --- | --- | --- |
| `armdos.iso` | ~30 MiB (not compressed) | Live ISO for any ARM64 UEFI machine or VM (QEMU, UTM): read-only A:, `INSTALL` to a disk. Not for the Pi |
| `msdos-arm64.img.xz` | 64 MiB | AArch64 UEFI VM disk; candidate external payload on supported, preconfigured Apple m1n1/U-Boot |
| `msdos-arm64-pi3.img.xz` | 128 MiB | Raspberry Pi 3B/3B+ SD card with bundled Pi UEFI firmware |
| `msdos-arm64.json`, `msdos-arm64-pi3.json` | | Image manifests (raw and compressed SHA-256, sizes, firmware pin) |
| `msdos-arm64.img.sha256`, `msdos-arm64-pi3.img.sha256` | | SHA-256 of the decompressed `.img` |
| `validation.json` | | What was tested on these exact bytes |
| `SHA256SUMS` | | SHA-256 of every other asset of the release |

## Download and verify

The easy way, from a clone of the repository (Python 3, no other tools):

```sh
python3 tools/fetch_release.py armdos.iso      # just the live ISO
python3 tools/fetch_release.py                 # every asset
python3 tools/fetch_release.py --tag v1.0.0    # a specific release
python3 tools/run.py --iso images/armdos.iso --disk armdos-disk.img
```

`fetch_release.py` downloads into `images/`, checks every file against the
release's `SHA256SUMS` and discards anything that does not match.
`python3 tools/run.py --iso latest` does the same for the ISO and boots it.

By hand, download the assets and `SHA256SUMS` from the Releases page into one
folder, then:

```sh
sha256sum -c --ignore-missing SHA256SUMS       # macOS: shasum -a 256 -c --ignore-missing SHA256SUMS
xz -dk msdos-arm64.img.xz                       # disk images only; the ISO is not compressed
sha256sum -c msdos-arm64.img.sha256             # checks the decompressed image
```

Use the raw generic image as a writable UEFI VM disk. Use Raspberry Pi
Imager's custom-image workflow with the Pi 3 image and the intended removable
card. No device is flashed by the build scripts. See
[platform instructions and limits](../README.md).

## What was tested

A release is built by [the Release workflow](../.github/workflows/release.yml)
when a `v*` tag is pushed. It publishes nothing unless the unit, FAT,
smoke (native and firmware mode), Pi 3 driver and live ISO tests pass, and
`make snapshot` then packages only bytes whose validation is recorded in
`validation.json`: FAT consistency checks, build-payload comparisons, native
API integration checks and the console checks under QEMU AArch64
`virt`/UEFI, with the native kernel serving the disk and `fsck.fat` clean
afterwards. The ISO is packaged only after `make iso-test` passed on its exact
bytes (live boot as a CD and USB stick, `INSTALL` to a blank disk and a boot
of that disk); see [Live ISO and INSTALL](../README.md#live-iso-and-install).

For the Pi image, this validates FAT32 and the DOS payload through generic
UEFI; it does not validate Pi ROM/VideoCore boot or physical hardware drivers.
**Physical Pi and native Apple hardware have not been tested. Native boot on
all Apple Silicon models remains unsupported.** The generic image does not
install Apple's boot authorization, m1n1 or U-Boot.

## Licenses

The DOS sources and binaries are MIT licensed (`LICENSE.TXT` on the generic
disk; `DOS-MIT.TXT` on Pi). The Pi image includes upstream
[RPi3 UEFI firmware v1.53.1](https://github.com/pftf/RPi3/releases/tag/v1.53.1),
with its licenses/notices in `LICENSE.TXT`, `BROADCOM.TXT` and `firmware/`.
Firmware source/build references are provided by the upstream project's release
and [repository](https://github.com/pftf/RPi3). Those firmware licenses apply
to the bundled third-party files; they are not relicensed by this repository.

## Building the same assets yourself

```sh
make snapshot FIRMWARE=/path/to/QEMU_EFI.fd     # into build/release/
make snapshot SNAPSHOT_DIR=out                  # or another folder
```

`make snapshot` runs `validate` and `iso-test`, refuses stale validation when
source or image bytes changed, and writes the release asset set with its
`SHA256SUMS`.
