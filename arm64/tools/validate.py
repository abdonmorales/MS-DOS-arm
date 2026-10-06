#!/usr/bin/env python3
"""Validate both image formats and their actual native runtime; save evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_digest(source):
    files = sorted(p for p in source.rglob('*') if p.is_file() and
                   (p.suffix in {'.S', '.py', '.ld', '.BAT'} or p.name == 'Makefile')
                   and 'build' not in p.parts)
    sources = hashlib.sha256()
    for path in files:
        sources.update(str(path.relative_to(source)).encode() + b'\0' + path.read_bytes())
    return sources.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', type=Path, default=Path('build'))
    parser.add_argument('--firmware', required=True, type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    report = {'architecture': 'AArch64', 'complete_msdos_port': False,
              'native_apple_tested': False, 'physical_pi_tested': False, 'images': {}}
    report['source_files_sha256'] = source_digest(source)
    report['boot_application_sha256'] = digest(args.build / 'BOOTAA64.EFI')
    for name, partition_type in [('msdos-arm64', 0xef), ('msdos-arm64-pi3', 0x0c)]:
        path = args.build / (name + '.img')
        with path.open('rb') as disk:
            mbr = disk.read(512)
            if mbr[510:512] != b'\x55\xaa' or mbr[450] != partition_type:
                raise RuntimeError('Incorrect MBR partition type/signature: ' + name)
            start, count = struct.unpack_from('<II', mbr, 454)
            if start != 2048 or (start + count) * 512 != path.stat().st_size:
                raise RuntimeError('Incorrect image geometry: ' + name)
            with tempfile.TemporaryDirectory(prefix='arm64-fsck-') as temporary:
                partition = Path(temporary) / 'fat.img'
                disk.seek(start * 512)
                with partition.open('wb') as output:
                    shutil.copyfileobj(disk, output)
                fsck = subprocess.run(['fsck.fat', '-n', '-v', str(partition)],
                                      capture_output=True, text=True, check=True)
                (args.build / (name + '-fsck.log')).write_text(fsck.stdout + fsck.stderr)
        mtools_image = str(path) + '@@' + str(start * 512)
        expected = {'EFI/BOOT/BOOTAA64.EFI': (args.build / 'BOOTAA64.EFI').read_bytes(),
                    'NATIVE.EXE': (args.build / 'NATIVE.EXE').read_bytes(),
                    'ARMTEST.TXT': b'ARM64 FAT read\r\n',
                    'SCRIPT.BAT': (source / 'fixtures/SCRIPT.BAT').read_bytes(),
                    'CHILD.BAT': (source / 'fixtures/CHILD.BAT').read_bytes()}
        for filename, contents in expected.items():
            actual = subprocess.check_output(['mtype', '-i', mtools_image, '::/' + filename])
            if actual != contents:
                raise RuntimeError('Image payload mismatch: ' + name + '/' + filename)
        if partition_type == 0x0c:
            for filename in ['RPI_EFI.fd', 'bootcode.bin', 'start.elf', 'fixup.dat',
                             'config.txt', 'bcm2710-rpi-3-b.dtb', 'LICENSE.TXT',
                             'BROADCOM.TXT', 'DOS-MIT.TXT', 'firmware/LICENCE_bin+clm_blob.txt']:
                if not subprocess.check_output(['mtype', '-i', mtools_image, '::/' + filename]):
                    raise RuntimeError('Missing Pi firmware/license: ' + filename)
        log = args.build / (name + '-smoke.log')
        result = subprocess.run([sys.executable, str(source / 'tools/smoke.py'),
                                 str(path), '--firmware', str(args.firmware), '--log', str(log)],
                                text=True, capture_output=True, check=True)
        print(result.stdout.strip())
        match = re.search(r'(\d+) console checks', result.stdout)
        if match is None:
            raise RuntimeError('Smoke test did not report completion')
        image_digest = digest(path)
        manifest = json.loads(path.with_suffix('.json').read_text())
        if manifest['sha256'] != image_digest or manifest['complete_msdos_port'] is not False:
            raise RuntimeError('Incorrect image manifest: ' + name)
        report['images'][name] = {'sha256': image_digest, 'bytes': path.stat().st_size,
                                 'filesystem_check': 'pass', 'payload_check': 'pass',
                                 'aarch64_uefi_qemu_boot': 'pass',
                                 'console_checks': int(match.group(1)),
                                 'smoke_log_sha256': digest(log)}
    output = args.build / 'validation.json'
    output.write_text(json.dumps(report, indent=2) + '\n')
    print('PASS: both filesystems, image payloads and AArch64 runtime; ' + str(output))


if __name__ == '__main__':
    main()
