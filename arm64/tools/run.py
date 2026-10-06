#!/usr/bin/env python3
"""Run the ARM64 image in QEMU, including HVF on Apple Silicon hosts."""
import argparse
from pathlib import Path
import platform
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('image', type=Path)
    parser.add_argument('--firmware', required=True, type=Path)
    parser.add_argument('--qemu', default='qemu-system-aarch64')
    parser.add_argument('--accel', choices=['auto', 'tcg', 'hvf'], default='auto')
    args = parser.parse_args()
    if not args.image.is_file() or not args.firmware.is_file():
        parser.error('The image and ARM64 UEFI firmware files must exist')
    accel = args.accel
    if accel == 'auto':
        accel = ('hvf' if platform.system() == 'Darwin' and
                 platform.machine() in ['arm64', 'aarch64'] else 'tcg')
    cpu = 'host' if accel == 'hvf' else 'cortex-a72'
    cmd = [args.qemu, '-machine', 'virt', '-accel', accel, '-cpu', cpu,
           '-m', '256', '-bios', str(args.firmware.resolve()),
           '-drive', f'file={args.image.resolve()},format=raw,if=none,id=dos',
           '-device', 'virtio-blk-pci,drive=dos', '-nographic', '-net', 'none',
           '-no-reboot']
    raise SystemExit(subprocess.call(cmd))


if __name__ == '__main__':
    main()
