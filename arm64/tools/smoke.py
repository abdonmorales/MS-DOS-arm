#!/usr/bin/env python3
"""Boot the actual ARM64 disk and exercise native services via its console."""
import argparse
from pathlib import Path
import os
import re
import selectors
import shutil
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('image', type=Path)
    parser.add_argument('--firmware', required=True, type=Path)
    parser.add_argument('--qemu', default='qemu-system-aarch64')
    parser.add_argument('--timeout', type=float, default=45)
    parser.add_argument('--log', type=Path)
    args = parser.parse_args()
    output = bytearray()
    with tempfile.TemporaryDirectory(prefix='arm64-smoke-') as directory:
        image = Path(directory) / 'test.img'
        shutil.copyfile(args.image, image)
        cmd = [args.qemu, '-machine', 'virt', '-cpu', 'cortex-a72', '-m', '256',
               '-bios', str(args.firmware), '-drive',
               f'file={image},format=raw,if=none,id=dos',
               '-device', 'virtio-blk-pci,drive=dos', '-nographic', '-monitor',
               'none', '-net', 'none', '-no-reboot']
        process = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)

        def until(expected):
            deadline = time.monotonic() + args.timeout
            mark = len(output)
            while time.monotonic() < deadline:
                for key, _ in selector.select(timeout=0.1):
                    chunk = os.read(key.fileobj.fileno(), 8192)
                    if not chunk:
                        raise RuntimeError('QEMU exited before expected console output')
                    output.extend(chunk)
                cleaned = re.sub(rb'\x1b\[[0-9;=?]*[A-Za-z]', b'', output[mark:])
                if expected in cleaned:
                    return cleaned
                if b'Synchronous Exception' in cleaned or b'SELFTEST FAIL' in cleaned:
                    raise RuntimeError('Native runtime faulted')
            raise RuntimeError('Timed out waiting for ' + repr(expected))

        checks = 0

        def command(line, expected=b'', prompt=b'A:\\> '):
            nonlocal checks
            process.stdin.write(line.encode() + b'\r')
            process.stdin.flush()
            text = until(prompt).replace(b'\r', b'')
            if expected not in text:
                raise RuntimeError('Incorrect output for ' + line)
            checks += 1
            return text

        try:
            text = until(b'A:\\> ')
            if b'SELFTEST PASS' not in text:
                raise RuntimeError('Boot self-test did not complete')
            command('ver', b'MS-DOS API baseline 4.00')
            command('type ARMTEST.TXT', b'ARM64 FAT read')
            command('echo native-arm64-ok', b'\nnative-arm64-ok\n')
            command('selftest', b'SELFTEST PASS')
            command('dir', b'ARMTEST.TXT')
            command('del DOESNOT.TXT', b'File/device error.')
            command('type DOESNOT.TXT', b'File/device error.')
            command('invalidcommand', b'Bad command or unsupported port feature.')
            command('md "WORK DIR"')
            command('cd "WORK DIR"', prompt=b'A:\\WORK DIR> ')
            command('copy ..\\ARMTEST.TXT "COPY FILE.TXT"', b'1 file(s) copied.',
                    prompt=b'A:\\WORK DIR> ')
            command('type "COPY FILE.TXT"', b'ARM64 FAT read', prompt=b'A:\\WORK DIR> ')
            command('copy "COPY FILE.TXT" ".\\copy file.txt"', b'File/device error.',
                    prompt=b'A:\\WORK DIR> ')
            command('type "COPY FILE.TXT"', b'ARM64 FAT read', prompt=b'A:\\WORK DIR> ')
            command('ren "COPY FILE.TXT" RENAMED.TXT', prompt=b'A:\\WORK DIR> ')
            command('dir re?amed.*', b'RENAMED.TXT', prompt=b'A:\\WORK DIR> ')
            command('attrib +r RENAMED.TXT', prompt=b'A:\\WORK DIR> ')
            command('del RENAMED.TXT', b'File/device error.', prompt=b'A:\\WORK DIR> ')
            command('attrib -r RENAMED.TXT', prompt=b'A:\\WORK DIR> ')
            command('cd ..')
            command('rd "WORK DIR"', b'File/device error.')
            command('del "WORK DIR\\RENAMED.TXT"')
            command('rd "WORK DIR"')
            command('cd "WORK DIR"', b'File/device error.')
            command('selftest', b'SELFTEST PASS')
            print(f'PASS: ARM64 UEFI disk boot, native API self-tests, {checks} console checks.')
        finally:
            selector.close()
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            if args.log:
                args.log.write_bytes(output)


if __name__ == '__main__':
    main()
