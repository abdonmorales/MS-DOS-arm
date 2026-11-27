#!/usr/bin/env python3
"""Run ARM DOS in QEMU `virt`, including HVF on Apple Silicon hosts.

Boot a disk image:     run.py build/msdos-arm64.img
Fetch and boot the ISO of the latest release: run.py --iso latest
Boot the live ISO:     run.py --iso images/armdos.iso
Install to a new disk: run.py --iso images/armdos.iso --disk armdos-disk.img
Boot the installed disk afterwards: run.py armdos-disk.img
With a screen window as well:      run.py --screen build/msdos-arm64.img

The image argument and every --disk are writable VirtIO disks; the image is
the one the firmware tries first, unless --iso is given, in which case the
read-only CD comes first. A --disk that does not exist is created as a blank
sparse file of --disk-size. `--iso latest` downloads armdos.iso of the
latest GitHub release into images/ (tools/fetch_release.py, SHA-256 checked)
and boots it. Without --firmware the runner looks for ARM64
UEFI firmware where Homebrew, Debian/Ubuntu and Fedora install it.
"""
import argparse
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import sys

FIRMWARE_NAMES = ['share/qemu/edk2-aarch64-code.fd']       # under a Homebrew prefix
FIRMWARE_PATHS = [
    '/usr/share/qemu-efi-aarch64/QEMU_EFI.fd',             # Debian/Ubuntu qemu-efi-aarch64
    '/usr/share/AAVMF/AAVMF_CODE.fd',                      # Debian/Ubuntu (pflash build)
    '/usr/share/edk2/aarch64/QEMU_EFI.fd',                 # Fedora edk2-aarch64
    '/usr/share/qemu/edk2-aarch64-code.fd',                # QEMU's own install layout
]


def homebrew_prefixes(qemu):
    """Prefixes that may hold Homebrew's QEMU share directory."""
    prefixes = []
    found = shutil.which(qemu)
    if found:
        # <prefix>/bin/qemu-system-aarch64 -> <prefix>, then the Cellar path.
        # The unresolved link comes first so a printed command survives
        # `brew upgrade`.
        prefixes.append(Path(found).parent.parent)
        prefixes.append(Path(found).resolve().parent.parent)
    prefixes += [Path('/opt/homebrew'), Path('/usr/local')]
    return prefixes


def find_firmware(qemu):
    candidates = [prefix / name for prefix in homebrew_prefixes(qemu)
                  for name in FIRMWARE_NAMES]
    candidates += [Path(p) for p in FIRMWARE_PATHS]
    for path in candidates:
        if path.is_file():
            return path
    return None


def parse_size(text):
    match = re.fullmatch(r'(\d+)([KMG]?)', text.strip().upper())
    if not match:
        raise argparse.ArgumentTypeError(f'{text!r} is not a size such as 512M or 2G')
    size = int(match.group(1)) * {'': 1, 'K': 1 << 10, 'M': 1 << 20,
                                  'G': 1 << 30}[match.group(2)]
    if size < 64 << 20:
        raise argparse.ArgumentTypeError('a disk for ARM DOS needs at least 64M')
    return size


def positive_mib(text):
    value = int(text)
    if value < 64:
        raise argparse.ArgumentTypeError('give at least 64 MiB of RAM')
    return value


def qemu_file(path):
    """A path for a QEMU `file=` option, where a comma must be doubled."""
    return str(path.resolve()).replace(',', ',,')


def file_id(path):
    """Identity of an existing file: catches symlinks, hard links and case aliases."""
    info = os.stat(path)
    return (info.st_dev, info.st_ino)


def auto_accel():
    arm_host = platform.machine() in ['arm64', 'aarch64']
    if arm_host and platform.system() == 'Darwin':
        return 'hvf'
    if arm_host and platform.system() == 'Linux' and os.access('/dev/kvm', os.R_OK | os.W_OK):
        return 'kvm'
    return 'tcg'


def build_command(args, firmware):
    accel = auto_accel() if args.accel == 'auto' else args.accel
    cpu = 'cortex-a72' if accel == 'tcg' else 'host'
    cmd = [args.qemu, '-machine', 'virt', '-accel', accel, '-cpu', cpu,
           '-m', str(args.memory), '-bios', str(firmware.absolute()),
           '-net', 'none', '-no-reboot',
           # EDK2 otherwise waits out a hidden boot-menu timeout (~5 s).
           '-boot', 'menu=on,splash-time=0']
    if args.screen:
        # A ramfb screen in a QEMU window (EDK2 gives it a GOP, which the
        # native console mirrors); the serial console stays in the terminal.
        cmd += ['-device', 'ramfb', '-serial', 'mon:stdio']
    else:
        cmd += ['-nographic']
    boot = 0
    if args.iso:
        cmd += ['-device', 'virtio-scsi-pci',
                '-drive', f'file={qemu_file(args.iso)},if=none,id=cd,'
                          'media=cdrom,readonly=on',
                '-device', f'scsi-cd,drive=cd,bootindex={boot}']
        boot += 1
    disks = ([args.image] if args.image else []) + args.disk
    for number, disk in enumerate(disks):
        cmd += ['-drive', f'file={qemu_file(disk)},format=raw,if=none,id=hd{number}',
                '-device', f'virtio-blk-pci,drive=hd{number},bootindex={boot}']
        boot += 1
    return cmd


def main():
    parser = argparse.ArgumentParser(
        description='Run ARM DOS in QEMU. Quit with Ctrl-A, then X.')
    parser.add_argument('image', type=Path, nargs='?',
                        help='raw disk image to boot (writable)')
    parser.add_argument('--iso', type=Path,
                        help='live ISO to boot from a read-only CD drive; "latest" '
                             'downloads the latest release ISO into images/ first')
    parser.add_argument('--disk', type=Path, action='append', default=[],
                        help='extra writable raw disk, e.g. an INSTALL target; '
                             'created blank if missing (repeatable)')
    parser.add_argument('--disk-size', type=parse_size, default='512M',
                        help='size of a --disk that is created (default 512M)')
    parser.add_argument('--firmware', type=Path,
                        help='ARM64 UEFI firmware (default: search known locations)')
    parser.add_argument('--qemu', default='qemu-system-aarch64')
    parser.add_argument('--accel', choices=['auto', 'tcg', 'hvf', 'kvm'], default='auto')
    parser.add_argument('--memory', type=positive_mib, default=256, help='RAM in MiB')
    parser.add_argument('--screen', action='store_true',
                        help='also show the console on a screen in a QEMU window (ramfb)')
    parser.add_argument('--print', action='store_true', dest='print_only',
                        help='print the QEMU command instead of running it')
    args = parser.parse_args()

    if not args.image and not args.iso:
        parser.error('give a disk image, --iso, or both')
    if args.iso and str(args.iso) == 'latest' and not args.iso.exists():
        import urllib.error
        import fetch_release
        cached = Path(__file__).resolve().parent.parent / 'images' / 'armdos.iso'
        try:
            args.iso = fetch_release.fetch(['armdos.iso'])['armdos.iso']
        except (urllib.error.URLError, OSError, SystemExit) as error:
            if not cached.is_file():
                parser.error(f'--iso latest: could not download the release ISO ({error})')
            print(f'run.py: download failed ({error}); using {cached}', file=sys.stderr)
            args.iso = cached
    if args.image and not args.image.is_file():
        parser.error(f'{args.image}: not an existing disk image file')
    if args.iso and not args.iso.is_file():
        parser.error(f'{args.iso}: not an existing ISO file')
    # Check every disk before creating any, so an error leaves nothing behind.
    new_disks = []
    for disk in args.disk:
        if os.path.lexists(disk):
            if not disk.is_file():
                parser.error(f'{disk}: not a regular file')
        elif not disk.absolute().parent.is_dir():
            parser.error(f'{disk}: its folder does not exist')
        else:
            new_disks.append(disk)
    existing = ([args.image] if args.image else []) + \
        [d for d in args.disk if d not in new_disks]
    ids = [file_id(d) for d in existing]
    names = [d.resolve() for d in new_disks]
    if len(set(ids)) != len(ids) or len(set(names)) != len(names):
        parser.error('the same disk image is given more than once')
    if args.iso and file_id(args.iso) in ids:
        parser.error('the ISO cannot also be a writable disk')
    firmware = args.firmware or find_firmware(args.qemu)
    if firmware is None:
        parser.error('no ARM64 UEFI firmware found; install QEMU '
                     '(brew install qemu, or apt install qemu-efi-aarch64) '
                     'or pass --firmware')
    if not firmware.is_file():
        parser.error(f'{firmware}: no such firmware file')
    if not shutil.which(args.qemu):
        parser.error(f'{args.qemu} not found; install QEMU '
                     '(brew install qemu, or apt install qemu-system-arm)')

    cmd = build_command(args, firmware)
    if args.print_only:
        for disk in new_disks:
            print(f'# {disk} does not exist yet; create it first with: '
                  f'qemu-img create -f raw {shlex.quote(str(disk))} '
                  f'{args.disk_size >> 20}M')
        print(shlex.join(cmd))
        return
    for disk in new_disks:
        try:
            # Exclusive create: never truncates a file that appeared meanwhile.
            with open(disk, 'xb') as blank:
                blank.truncate(args.disk_size)
        except OSError as error:
            parser.error(f'cannot create {disk}: {error}')
        print(f'Created blank {args.disk_size >> 20} MiB disk {disk}')
    print('Starting QEMU. Quit with Ctrl-A, then X.', flush=True)
    try:
        os.execvp(cmd[0], cmd)
    except OSError as error:
        parser.error(f'cannot start {cmd[0]}: {error}')


if __name__ == '__main__':
    main()
