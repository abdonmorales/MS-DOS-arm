#!/usr/bin/env python3
"""Build the ROM disk: the read-only A: linked into a ROM build of the kernel.

A ROM build (make rom-pi, make rom-generic) is one EFI application,
ARMDOS.EFI, that carries its own drive A:. This script makes that volume: a
small FAT12 image holding the release file set (tools/release.py) plus the
ROM's own CONFIG.SYS, AUTOEXEC.BAT and README.TXT. The kernel serves it
straight from memory, so no disk is needed at all: the same file boots from
an SD card, a USB stick, the network (PXE/HTTP boot) or SPI/NOR flash through
U-Boot. B: is a RAM disk for scratch files.

--native puts \\NATIVE.ON on the volume: the kernel then leaves the firmware
at boot when it finds a console UART it drives (ACPI SPCR, or the device
tree's /chosen stdout-path), and stays in UEFI firmware mode otherwise.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from release import CONFIG_SYS, fix_times, mtools_env, release_tree

SECTOR = 512
# A scratch RAM disk a little larger than the live ISO's: embedded systems
# keep their work there.
ROM_CONFIG = CONFIG_SYS.replace(b'RAMDRIVE.SYS 1024 512 112', b'RAMDRIVE.SYS 4096 512 224')
assert ROM_CONFIG != CONFIG_SYS, 'release.py CONFIG_SYS no longer has the RAMDRIVE line'
ROM_AUTOEXEC = b'@ECHO OFF\r\nPATH A:\\\r\nVER\r\n'
TARGETS = {
    'generic': b'Boards: any ARM64 board with UEFI firmware (EDK2, or U-Boot\r\n'
               b'with bootefi/bootm), from SD, USB, network or SPI/NOR flash.\r\n',
    'check': b'Test build for make rom-test (extra test programs).\r\n',
    'pi': b'Boards: Raspberry Pi 3 and 4 with the pftf UEFI firmware on the\r\n'
          b'SD card or USB stick.\r\n',
}


def readme(target, native):
    mode = (b'Native mode is on: with a console UART it knows, the kernel\r\n'
            b'leaves the firmware and drives the UART itself.\r\n' if native else
            b'The kernel stays in UEFI firmware mode (screen and keyboard\r\n'
            b'through the firmware).\r\n')
    return (b'ARM DOS 4.0 ROM build\r\n\r\n'
            b'Drive A: is built into ARMDOS.EFI and is read-only, like a ROM.\r\n'
            b'B: is a RAM disk: its files last until power-off.\r\n'
            + TARGETS[target] + mode)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('image', type=Path, help='build/msdos-arm64.img')
    parser.add_argument('output', type=Path)
    parser.add_argument('--target', choices=sorted(TARGETS), required=True)
    parser.add_argument('--native', action='store_true')
    parser.add_argument('--extra', type=Path, nargs='*', default=[],
                        help='more files for the ROM disk (test programs)')
    args = parser.parse_args()
    env = mtools_env()
    epoch = int(env['SOURCE_DATE_EPOCH'])
    with tempfile.TemporaryDirectory(prefix='arm64-rom-') as name:
        tree = Path(name) / 'tree'
        tree.mkdir()
        release_tree(args.image, tree, env, ROM_CONFIG, ROM_AUTOEXEC)
        # The disk image's boot loader copy is not needed: the ROM kernel is
        # the file that carries this volume.
        shutil.rmtree(tree / 'EFI', ignore_errors=True)
        (tree / 'README.TXT').write_bytes(readme(args.target, args.native))
        if args.native:
            (tree / 'NATIVE.ON').write_bytes(b'')
        for extra in args.extra:
            target = tree / extra.name.upper()
            shutil.copyfile(extra, target)
            os.utime(target, (epoch, epoch))
        for path in [tree / 'README.TXT', tree / 'NATIVE.ON']:
            if path.exists():
                os.utime(path, (epoch, epoch))
        fix_times(tree, env)
        files = sorted(p for p in tree.rglob('*') if p.is_file())
        if any(p.parent != tree for p in files):
            raise SystemExit('the ROM disk holds root files only')
        # FAT12 with one sector per cluster and one FAT: room for the files and
        # metadata, rounded up to 64 KiB. Nothing is ever added.
        data = sum((p.stat().st_size + SECTOR - 1) // SECTOR for p in files)
        # FAT12 entries are 1.5 bytes per sector; 1 boot sector, 7 root
        # directory sectors (112 entries), and a 16 KiB margin.
        sectors = data + 1 + 7 + 32
        sectors += (sectors * 3 // 2 + SECTOR - 1) // SECTOR
        kib = (sectors * SECTOR + 65535) // 65536 * 64
        output = args.output.with_suffix('.tmp')
        output.unlink(missing_ok=True)
        subprocess.run(['mkfs.fat', '-C', '-F', '12', '-s', '1', '-S', str(SECTOR),
                        '-r', '112', '-f', '1', '-n', 'ARMDOS ROM', '-i', '524f4d41',
                        '--invariant', str(output), str(kib)],
                       env=env, check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['mcopy', '-m', '-i', str(output), *map(str, files), '::'],
                       env=env, check=True)
        os.replace(output, args.output)
    print(f'{args.output}: {kib} KiB FAT12 ROM disk ({args.target}'
          f'{", native" if args.native else ""})')


if __name__ == '__main__':
    main()
