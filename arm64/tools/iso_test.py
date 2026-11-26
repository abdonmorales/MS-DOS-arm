#!/usr/bin/env python3
"""Boot the ARM DOS live ISO in QEMU `virt` and check it, then INSTALL.

0. With --image: rebuilding the ISO gives the same bytes.
1. As a CD (virtio-scsi) with two blank disks: the live prompt comes up, A:
   refuses writes, the RAM disk B: takes them. INSTALL /Y without a disk
   number refuses; the menu cancels with ENTER and at the confirmation
   with nothing written; INSTALL 2 /Y installs on disk 2 (disk 1 stays
   zero), and a second run reuses the same drive.
2. The installed disk alone boots ARM DOS (native FAT driver, self-test)
   and keeps a file written to A:. fsck.fat finds its partition clean.
3. As a read-only USB stick: the same live system.
4. As a writable USB stick (the ISO written to one): INSTALL must not
   offer the disk ARM DOS booted from.
"""
import argparse
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import struct
import sys
import subprocess
import tempfile
import time
from validate import digest, source_digest


class Session:
    def __init__(self, args, attach):
        cmd = [args.qemu, '-machine', 'virt', '-cpu', 'cortex-a72', '-m', '256',
               '-bios', str(args.firmware), '-nographic', '-monitor', 'none',
               '-net', 'none', '-no-reboot', '-boot', 'menu=on,splash-time=0', *attach]
        self.timeout = args.timeout
        self.process = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.output = bytearray()

    def until(self, expected, timeout=None):
        deadline = time.monotonic() + (timeout or self.timeout)
        mark = len(self.output)
        while time.monotonic() < deadline:
            for key, _ in self.selector.select(timeout=0.1):
                chunk = os.read(key.fileobj.fileno(), 8192)
                if not chunk:
                    raise RuntimeError('QEMU exited: ' +
                                       self.output[-600:].decode(errors='replace'))
                self.output.extend(chunk)
            text = re.sub(rb'\x1b\[[0-9;=?]*[A-Za-z]', b'',
                          self.output[mark:]).replace(b'\r', b'')
            if expected in text:
                return text
        raise RuntimeError(f'timed out waiting for {expected!r}:\n' +
                           self.output[-1500:].decode(errors='replace'))

    def command(self, line, expected=b'', timeout=None):
        self.process.stdin.write(line.encode() + b'\r')
        self.process.stdin.flush()
        text = self.until(b'A:\\>', timeout)
        if expected not in text:
            raise RuntimeError(f'{line!r}: expected {expected!r} in {text!r}')
        return text

    def send(self, text, expected, timeout=None, enter=True):
        self.process.stdin.write(text.encode() + (b'\r' if enter else b''))
        self.process.stdin.flush()
        return self.until(expected, timeout)

    def close(self):
        # Let the guest's last writes reach the disk image before QEMU stops.
        self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def live_checks(s):
    s.until(b'Live system: drive A: is read-only')
    s.until(b'A:\\>')
    s.command('ver', b'ARM DOS Version 4.00')
    if b'Invalid drive' in s.command('dir', b'EFI          <DIR>'):
        raise RuntimeError('DIR printed an error on the live A:')
    s.command('dir A:\\EFI\\BOOT', b'BOOTAA64 EFI')
    s.command('echo test>A:\\T.TXT')
    if b'T        TXT' in s.command('dir A:\\T.TXT'):
        raise RuntimeError('a file was written to the read-only A:')
    s.command('echo live-ok>B:\\L.TXT')
    s.command('type B:\\L.TXT', b'live-ok')
    s.command('dir A:\\INSTALL.EXE', b'INSTALL  EXE')


def blk(path, name, readonly=False):
    ro = ',readonly=on' if readonly else ''
    return ['-drive', f'file={path},if=none,id={name},format=raw{ro}',
            '-device', f'virtio-blk-pci,drive={name}']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('iso', type=Path)
    parser.add_argument('--firmware', required=True, type=Path)
    parser.add_argument('--qemu', default='qemu-system-aarch64')
    parser.add_argument('--timeout', type=float, default=60)
    parser.add_argument('--image', type=Path,
                        help='the disk image the ISO came from: rebuild and compare')
    args = parser.parse_args()
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
    drive = f'file={args.iso},if=none,id=live,format=raw,readonly=on'
    with tempfile.TemporaryDirectory(prefix='arm64-iso-test-') as name:
        work = Path(name)
        if args.image:
            # Reproducible: a rebuild a few seconds later is byte-identical.
            time.sleep(2)
            again = work / 'again.iso'
            subprocess.run([sys.executable, str(Path(__file__).with_name('iso.py')),
                            str(args.image), str(again)], check=True,
                           stdout=subprocess.DEVNULL)
            if digest(again) != digest(args.iso):
                raise RuntimeError('the ISO is not reproducible: a rebuild differs')
        first, target = work / 'first.img', work / 'target.img'
        for disk in (first, target):
            with disk.open('wb') as f:
                f.truncate(128 << 20)

        s = Session(args, ['-device', 'virtio-scsi-pci', '-drive', drive + ',media=cdrom',
                           '-device', 'scsi-cd,drive=live',
                           *blk(first, 'first'), *blk(target, 'target')])
        try:
            live_checks(s)
            s.command('INSTALL /Y', b'needs the disk number')
            s.send('INSTALL', b'ENTER to cancel)? ')
            s.command('', b'nothing was written')
            s.send('INSTALL', b'ENTER to cancel)? ')
            s.send('2', b'(Y/N)?')
            s.send('n', b'nothing was written', enter=False)
            s.until(b'A:\\>')
            text = s.command('INSTALL 2 /Y', b'ARM DOS is installed on disk 2', timeout=300)
            letter = re.search(rb'\(drive ([C-Z]):', text).group(1)
            s.command(f'dir {letter.decode()}:\\EFI\\BOOT', b'BOOTAA64 EFI')
            # Again in the same session: the same partition, the same drive.
            text = s.command('INSTALL 2 /Y', b'ARM DOS is installed on disk 2', timeout=300)
            if re.search(rb'\(drive ([C-Z]):', text).group(1) != letter:
                raise RuntimeError('a second INSTALL attached the partition twice')
        finally:
            s.close()
        with first.open('rb') as f:
            while chunk := f.read(1 << 20):
                if any(chunk):
                    raise RuntimeError('INSTALL wrote to disk 1')

        mbr = target.read_bytes()[:512]
        kind, start, count = mbr[446 + 4], *struct.unpack_from('<II', mbr, 446 + 8)
        if mbr[510:] != b'\x55\xaa' or kind != 0xef or start != 2048:
            raise RuntimeError(f'bad MBR: type {kind:#x}, start {start}')
        part = work / 'part.img'
        with target.open('rb') as src, part.open('wb') as dst:
            src.seek(start * 512)
            dst.write(src.read(count * 512))
        subprocess.run(['fsck.fat', '-n', str(part)], check=True, stdout=subprocess.DEVNULL)

        s = Session(args, blk(target, 'target'))
        try:
            s.until(b'SELFTEST PASS')
            s.until(b'A:\\>')
            s.command('ver', b'ARM DOS Version 4.00')
            s.command('dir A:\\INSTALL.EXE', b'INSTALL  EXE')
            s.command('echo kept>A:\\KEPT.TXT')
        finally:
            s.close()
        listing = subprocess.run(['mtype', '-i', str(target) +
                                  f'@@{start * 512}', '::KEPT.TXT'], env=env, check=True,
                                 capture_output=True).stdout
        if b'kept' not in listing:
            raise RuntimeError('a file written on the installed disk was not kept')

        s = Session(args, ['-device', 'qemu-xhci', '-drive', drive,
                           '-device', 'usb-storage,drive=live,removable=on'])
        try:
            live_checks(s)
        finally:
            s.close()

        stick = work / 'stick.img'
        shutil.copyfile(args.iso, stick)
        s = Session(args, ['-device', 'qemu-xhci', '-drive',
                           f'file={stick},if=none,id=stick,format=raw',
                           '-device', 'usb-storage,drive=stick,removable=on'])
        try:
            s.until(b'Platform: UEFI firmware services')
            s.until(b'A:\\>')
            s.command('INSTALL 1 /Y', b'No disk to install on')
        finally:
            s.close()
    # The evidence snapshot.py requires before it packages this ISO.
    record = {'iso': args.iso.name, 'sha256': digest(args.iso), 'iso_test': 'pass',
              'source_files_sha256': source_digest(Path(__file__).resolve().parent.parent)}
    args.iso.with_suffix('.test.json').write_text(json.dumps(record, indent=2) + '\n')
    print('PASS: live ISO boots as a CD and as a USB stick (A: read-only, B: writable); '
          'INSTALL puts a bootable ARM DOS on the chosen disk only and skips the boot disk; '
          'the ISO rebuilds byte for byte.')


if __name__ == '__main__':
    main()
