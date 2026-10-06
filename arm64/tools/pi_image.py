#!/usr/bin/env python3
"""Package the native EFI application with pinned Pi 3 UEFI firmware."""
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

FIRMWARE_VERSION = '1.53.1'
FIRMWARE_SHA256 = '1d2b94c48461216808e6b6081ea7567653e9818a659f61e97e69a9b526cc0b60'
FIRMWARE_URL = ('https://github.com/pftf/RPi3/releases/download/v1.53.1/'
                'RPi3_UEFI_Firmware_v1.53.1.zip')
TOTAL_SECTORS = 262144
START = 2048


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('efi', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--firmware', type=Path)
    args = parser.parse_args()
    firmware = args.firmware or args.output.parent / f'RPi3_UEFI_Firmware_v{FIRMWARE_VERSION}.zip'
    if not firmware.exists():
        with urllib.request.urlopen(FIRMWARE_URL, timeout=45) as response:
            contents = response.read(16 * 1024 * 1024)
        if hashlib.sha256(contents).hexdigest() != FIRMWARE_SHA256:
            raise SystemExit('Pi firmware checksum mismatch; no image generated')
        firmware.write_bytes(contents)
    if hashlib.sha256(firmware.read_bytes()).hexdigest() != FIRMWARE_SHA256:
        raise SystemExit('Pi firmware checksum mismatch; no image generated')
    for tool in ['mkfs.fat', 'mcopy']:
        if shutil.which(tool) is None:
            raise SystemExit('Required image tool missing: ' + tool)
    if args.output.exists():
        raise SystemExit('Refusing to overwrite existing Pi image: ' + str(args.output))
    with tempfile.TemporaryDirectory(prefix='pi3-', dir=args.output.parent) as temporary:
        source = Path(temporary)
        with zipfile.ZipFile(firmware) as archive:
            for item in archive.infolist():
                path = Path(item.filename)
                if path.is_absolute() or '..' in path.parts:
                    raise SystemExit('Unsafe firmware archive path')
            archive.extractall(source)
        boot_dir = source / 'EFI/BOOT'
        boot_dir.mkdir(parents=True)
        shutil.copyfile(args.efi, boot_dir / 'BOOTAA64.EFI')
        (source / 'ARMTEST.TXT').write_bytes(b'ARM64 FAT read\r\n')
        (source / 'ARMDOS.TXT').write_bytes(
            b'Native AArch64 MS-DOS 4.0 port development runtime.\r\n'
            b'Partial port; this image has not been tested on physical Pi hardware.\r\n')
        (source / 'startup.nsh').write_text('fs0:\\EFI\\BOOT\\BOOTAA64.EFI\r\n')
        # Keep third-party license notices with redistributed firmware.
        license_url = ('https://raw.githubusercontent.com/pftf/RPi3/'
                       '671c48c7a99c3c5664b347c938e4190ad6aa255f/License.txt')
        with urllib.request.urlopen(license_url, timeout=30) as response:
            (source / 'LICENSE.TXT').write_bytes(response.read())
        binary_license = ('https://raw.githubusercontent.com/raspberrypi/firmware/'
                          'd91dd52c88a3918028a0ca6bbe6fe40e91bee951/boot/LICENCE.broadcom')
        with urllib.request.urlopen(binary_license, timeout=30) as response:
            (source / 'BROADCOM.TXT').write_bytes(response.read())
        mbr = bytearray(512)
        # The Pi's ROM requires a FAT LBA partition, not MBR type 0xef.
        struct.pack_into('<B3sB3sII', mbr, 446,
                         0, b'\xfe\xff\xff', 0x0c, b'\xfe\xff\xff',
                         START, TOTAL_SECTORS - START)
        mbr[510:512] = b'\x55\xaa'
        with args.output.open('xb') as image:
            image.write(mbr)
            image.truncate(TOTAL_SECTORS * 512)
        try:
            subprocess.run(['mkfs.fat', '--invariant', '-F', '32', '-s', '1',
                            '-n', 'ARMDOS', '--offset', str(START),
                            str(args.output)], check=True)
            disk = str(args.output) + '@@' + str(START * 512)
            # Avoid mtools' host-time metadata by preserving fixed source times.
            for item in source.rglob('*'):
                os.utime(item, (1749168000, 1749168000))
            for item in sorted(source.iterdir()):
                subprocess.run(['mcopy', '-m', '-s', '-i', disk, str(item), '::/'],
                               check=True)
        except BaseException:
            args.output.unlink(missing_ok=True)
            raise
    digest = hashlib.sha256(args.output.read_bytes()).hexdigest()
    args.output.with_suffix('.img.sha256').write_text(f'{digest}  {args.output.name}\n')
    args.output.with_suffix('.json').write_text(json.dumps({
        'target': 'Raspberry Pi 3B / 3B+', 'architecture': 'AArch64',
        'format': 'MBR/FAT32 with Pi 3 UEFI firmware',
        'sha256': digest, 'firmware_version': FIRMWARE_VERSION,
        'firmware_url': FIRMWARE_URL, 'firmware_sha256': FIRMWARE_SHA256,
        'complete_msdos_port': False, 'native_hardware_tested': False,
    }, indent=2) + '\n')
    print(f'{args.output}: 128 MiB Raspberry Pi 3 UEFI development image')


if __name__ == '__main__':
    main()
