#!/usr/bin/env python3
"""Build the ARM DOS live ISO from the generic disk image.

The ISO is UEFI-bootable through El Torito: its EFI boot image is a FAT16
volume holding the same files as build/msdos-arm64.img (the kernel as
\\EFI\\BOOT\\BOOTAA64.EFI, the programs, drivers and fixtures). The same FAT
image is appended as MBR/GPT partition 2, so the ISO also boots when written
to a USB stick. El Torito describes the boot image's size in a 16-bit count
of 512-byte units, and EDK2 trusts that count, so the FAT volume stays under
32 MiB (the files take well under 1 MiB).

Booted from read-only media the kernel runs as a live system: A: is the
read-only volume and the CONFIG.SYS RAM disk B: is writable. INSTALL
copies ARM DOS to a writable disk.

The ISO is the release file set: the disk image's smoke-test fixtures
(TESTDRV.SYS, DOSTEST.EXE, the sample text and batch files, and the
CONFIG.SYS with its deliberate error) are replaced or left out.
"""
import argparse
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

FAT_KIB = 30720                 # 30 MiB: under El Torito's 32 MiB limit
# Test fixtures of the disk image that a release does not carry. ARMTEST.TXT
# and NATIVE.EXE stay: the boot self-test reads and runs them.
TEST_ONLY = {'TESTDRV.SYS', 'DOSTEST.EXE', 'FC1.TXT', 'FC2.TXT',
             'LINES.TXT', 'SORTIN.TXT', 'CHILD.BAT', 'SCRIPT.BAT', 'FEATURES.BAT'}
CONFIG_SYS = (b'REM CONFIG.SYS for ARM DOS\r\n'
              b'FILES=40\r\n'
              b'BUFFERS=20\r\n'
              b'COUNTRY=001\r\n'
              b'LASTDRIVE=Z\r\n'
              b'DEVICE=\\RAMDRIVE.SYS 1024 512 112\r\n'
              b'DEVICE=\\ANSI.SYS\r\n')
AUTOEXEC_BAT = b'@ECHO OFF\r\nPATH A:\\\r\n'
README = (b'ARM DOS 4.0 live ISO\r\n\r\n'
          b'Boot this ISO on an ARM64 UEFI machine or VM (QEMU virt, UTM). It\r\n'
          b'starts the normal ARM DOS prompt with A: read-only; B: is a RAM\r\n'
          b'disk. Run INSTALL to copy ARM DOS onto a writable disk.\r\n'
          b'x86 programs do not run. A Raspberry Pi 3 needs the SD-card image.\r\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('image', type=Path, help='build/msdos-arm64.img')
    parser.add_argument('output', type=Path)
    parser.add_argument('--xorriso', default='xorriso')
    args = parser.parse_args()
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
    env.setdefault('SOURCE_DATE_EPOCH', '1749168000')   # 2025-06-06, as image.py
    with args.image.open('rb') as disk:
        mbr = disk.read(512)
    if mbr[510:512] != b'\x55\xaa':
        raise SystemExit('image has no MBR')
    start = struct.unpack_from('<I', mbr, 454)[0]
    with tempfile.TemporaryDirectory(prefix='arm64-iso-') as name:
        work = Path(name)
        tree, root = work / 'tree', work / 'root'
        tree.mkdir()
        root.mkdir()
        source = f'{args.image}@@{start * 512}'
        subprocess.run(['mcopy', '-s', '-m', '-i', source, '::*', str(tree)],
                       env=env, check=True)
        for name in TEST_ONLY:
            (tree / name).unlink(missing_ok=True)
        (tree / 'CONFIG.SYS').write_bytes(CONFIG_SYS)
        (tree / 'AUTOEXEC.BAT').write_bytes(AUTOEXEC_BAT)
        efi = work / 'efiboot.img'
        subprocess.run(['mkfs.fat', '-C', '-F', '16', '-n', 'ARMDOS', '-i', '41524d44',
                        '--invariant', str(efi), str(FAT_KIB)],
                       env=env, check=True, stdout=subprocess.DEVNULL)
        files = sorted(tree.iterdir())
        subprocess.run(['mcopy', '-s', '-m', '-i', str(efi), *map(str, files), '::'],
                       env=env, check=True)
        (root / 'README.TXT').write_bytes(README)
        output = args.output.with_suffix('.tmp')
        if output.exists():
            output.unlink()
        subprocess.run([args.xorriso, '-as', 'mkisofs', '-quiet', '-o', str(output),
                        '-V', 'ARMDOS', '-J', '-r',
                        '-append_partition', '2', '0xef', str(efi),
                        '-e', '--interval:appended_partition_2:all::', '-no-emul-boot',
                        str(root)], env=env, check=True)
        shutil.move(output, args.output)
    print(f'{args.output}: ARM DOS live ISO (UEFI El Torito, {FAT_KIB // 1024} MiB FAT16 boot image)')


if __name__ == '__main__':
    main()
