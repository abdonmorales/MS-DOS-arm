#!/usr/bin/env python3
"""Put the Pi ROM build (ARMDOS.EFI) on a Raspberry Pi 3 or 4 boot image.

The image is an MBR/FAT32 volume with the pinned pftf UEFI firmware for the
model and ARMDOS.EFI as \\EFI\\BOOT\\BOOTAA64.EFI. Nothing else of ARM DOS is
on it: drive A: is built into ARMDOS.EFI and read-only, so the card (or USB
stick) is never written by DOS and survives power cuts like a ROM. The same
ARMDOS.EFI also network-boots through the firmware's PXE/HTTP boot.

The Pi's real boot ROM is inside the SoC and cannot be replaced; on the Pi 4
the EEPROM holds only the Pi's own bootloader, so this card is as close to
a ROM OS as the Pi allows.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import urllib.request
import zipfile

MODELS = {
    '3': {
        'target': 'Raspberry Pi 3B / 3B+',
        'version': '1.53.1',
        'url': 'https://github.com/pftf/RPi3/releases/download/v1.53.1/'
               'RPi3_UEFI_Firmware_v1.53.1.zip',
        'sha256': '1d2b94c48461216808e6b6081ea7567653e9818a659f61e97e69a9b526cc0b60',
        'license': 'https://raw.githubusercontent.com/pftf/RPi3/'
                   '671c48c7a99c3c5664b347c938e4190ad6aa255f/License.txt',
    },
    '4': {
        'target': 'Raspberry Pi 4B / 400 / CM4',
        'version': '1.42',
        'url': 'https://github.com/pftf/RPi4/releases/download/v1.42/'
               'RPi4_UEFI_Firmware_v1.42.zip',
        'sha256': '3cf8d643dfe491c3ae65f697b444e1a44c4f2d05aab12cfd1dffac1175880cfc',
        # pftf's RPi4 License.txt is the same file as RPi3's (same hash).
        'license': 'https://raw.githubusercontent.com/pftf/RPi3/'
                   '671c48c7a99c3c5664b347c938e4190ad6aa255f/License.txt',
    },
}
BROADCOM_LICENSE = ('https://raw.githubusercontent.com/raspberrypi/firmware/'
                    'd91dd52c88a3918028a0ca6bbe6fe40e91bee951/boot/LICENCE.broadcom')
LICENSE_SHA256 = {
    'License.txt': 'f5c8f78f51f9ccf36e4e4cda4d9d70cb37b8161145eb0434e983ce91c3c17087',
    'LICENCE.broadcom': 'c7283ff51f863d93a275c66e3b4cb08021a5dd4d8c1e7acc47d872fbe52d3d6b',
}
TOTAL_SECTORS = 131072          # 64 MiB
START = 2048
EPOCH = 1749168000              # 2025-06-06, as image.py


def cached(url, sha256, path, what):
    """The file at url with this hash, kept at path; downloaded only once."""
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() != sha256:
        path.unlink()           # a damaged cache: fetch it again
    if not path.exists():
        try:
            with urllib.request.urlopen(url, timeout=45) as response:
                contents = response.read()
        except OSError as error:
            raise SystemExit(f'cannot download {what} ({url}): {error}; '
                             f'place it at {path} to build offline')
        if hashlib.sha256(contents).hexdigest() != sha256:
            raise SystemExit(f'{what} checksum mismatch; no image generated')
        temporary = path.with_suffix(path.suffix + '.tmp')
        temporary.write_bytes(contents)
        os.replace(temporary, path)
    return path


def firmware_zip(model, given, cache_dir):
    info = MODELS[model]
    if given:
        if hashlib.sha256(given.read_bytes()).hexdigest() != info['sha256']:
            raise SystemExit(f'Pi {model} firmware checksum mismatch; no image generated')
        return given
    return cached(info['url'], info['sha256'], cache_dir / Path(info['url']).name,
                  f'the Pi {model} UEFI firmware')


def readme(model):
    return (f'ARM DOS 4.0 ROM build for the {MODELS[model]["target"]}\r\n\r\n'
            'Drive A: is built into EFI\\BOOT\\BOOTAA64.EFI and is read-only;\r\n'
            'B: is a RAM disk. DOS never writes this card.\r\n'
            'The card, a USB stick with the same files, or a network boot\r\n'
            'server offering BOOTAA64.EFI all start the same system.\r\n'
            'This build has not been booted on a physical Raspberry Pi yet.\r\n').encode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('efi', type=Path, help='the Pi ROM build, ARMDOS.EFI')
    parser.add_argument('output', type=Path)
    parser.add_argument('--model', choices=sorted(MODELS), required=True)
    parser.add_argument('--firmware', type=Path, help='the pinned firmware zip, if downloaded')
    args = parser.parse_args()
    info = MODELS[args.model]
    for tool in ['mkfs.fat', 'mcopy']:
        if shutil.which(tool) is None:
            raise SystemExit('Required image tool missing: ' + tool)
    firmware = firmware_zip(args.model, args.firmware, args.output.parent)
    with tempfile.TemporaryDirectory(prefix='rom-pi-', dir=args.output.parent) as temporary:
        source = Path(temporary) / 'files'
        source.mkdir()
        with zipfile.ZipFile(firmware) as archive:
            for item in archive.infolist():
                path = Path(item.filename)
                if path.is_absolute() or '..' in path.parts:
                    raise SystemExit('Unsafe firmware archive path')
            archive.extractall(source)
        boot_dir = source / 'EFI/BOOT'
        boot_dir.mkdir(parents=True)
        shutil.copyfile(args.efi, boot_dir / 'BOOTAA64.EFI')
        (source / 'ARMDOS.TXT').write_bytes(readme(args.model))
        shutil.copyfile(Path(__file__).parent.parent / 'LICENSE', source / 'DOS-MIT.TXT')
        (source / 'startup.nsh').write_text('fs0:\\EFI\\BOOT\\BOOTAA64.EFI\r\n')
        # Keep third-party license notices with redistributed firmware.
        cache = args.output.parent
        shutil.copyfile(cached(info['license'], LICENSE_SHA256['License.txt'],
                               cache / 'pftf-License.txt', 'the pftf firmware license'),
                        source / 'LICENSE.TXT')
        shutil.copyfile(cached(BROADCOM_LICENSE, LICENSE_SHA256['LICENCE.broadcom'],
                               cache / 'LICENCE.broadcom', 'the Broadcom firmware licence'),
                        source / 'BROADCOM.TXT')
        mbr = bytearray(512)
        # The Pi's boot ROM wants a FAT LBA partition (type 0Ch), not 0EFh.
        struct.pack_into('<B3sB3sII', mbr, 446,
                         0, b'\xfe\xff\xff', 0x0c, b'\xfe\xff\xff',
                         START, TOTAL_SECTORS - START)
        mbr[510:512] = b'\x55\xaa'
        generated = Path(temporary) / 'disk.img'
        with generated.open('xb') as image:
            image.write(mbr)
            image.truncate(TOTAL_SECTORS * 512)
        subprocess.run(['mkfs.fat', '--invariant', '-F', '32', '-s', '1',
                        '-n', 'ARMDOS ROM', '--offset', str(START),
                        str(generated)], check=True, stdout=subprocess.DEVNULL)
        disk = f'{generated}@@{START * 512}'
        for item in source.rglob('*'):
            os.utime(item, (EPOCH, EPOCH))
        env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
        for item in sorted(source.iterdir()):
            subprocess.run(['mcopy', '-m', '-s', '-i', disk, str(item), '::/'],
                           env=env, check=True)
        os.replace(generated, args.output)
    digest = hashlib.sha256(args.output.read_bytes()).hexdigest()
    args.output.with_suffix('.img.sha256').write_text(f'{digest}  {args.output.name}\n')
    args.output.with_suffix('.json').write_text(json.dumps({
        'target': info['target'], 'architecture': 'AArch64',
        'format': f'MBR/FAT32 with Pi {args.model} UEFI firmware; ARM DOS ROM build',
        'boot_application': 'EFI/BOOT/BOOTAA64.EFI', 'sha256': digest,
        'efi_sha256': hashlib.sha256(args.efi.read_bytes()).hexdigest(),
        'firmware_version': info['version'], 'firmware_url': info['url'],
        'firmware_sha256': info['sha256'], 'native_hardware_tested': False,
    }, indent=2) + '\n')
    print(f'{args.output}: 64 MiB Raspberry Pi {args.model} ROM-build image')


if __name__ == '__main__':
    main()
