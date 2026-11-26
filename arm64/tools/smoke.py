#!/usr/bin/env python3
"""Boot the actual ARM64 disk and exercise native services via its console."""
import argparse
from pathlib import Path
import os
import re
import selectors
import shutil
import struct
import subprocess
import tempfile
import time


def check_filesystem(image):
    """After shutdown: fsck the partition and read native writes with mtools."""
    with image.open('rb') as disk:
        mbr = disk.read(512)
        start = struct.unpack_from('<I', mbr, 454)[0]
        partition = image.with_name('partition.img')
        disk.seek(start * 512)
        with partition.open('wb') as out:
            shutil.copyfileobj(disk, out)
    fsck = subprocess.run(['fsck.fat', '-n', str(partition)], capture_output=True, text=True)
    if fsck.returncode:
        raise RuntimeError('fsck.fat after native writes:\n' + fsck.stdout + fsck.stderr)
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
    data = subprocess.run(['mtype', '-i', str(partition),
                           '::/Native Long Directory/Mixed Case Name.txt'],
                          capture_output=True, env=env)
    if data.returncode or data.stdout != b'ARM64 FAT read\r\n':
        raise RuntimeError('mtools could not read a natively written long name')
    print('PASS: fsck.fat clean after the session; mtools reads native long names.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('image', type=Path)
    parser.add_argument('--firmware', required=True, type=Path)
    parser.add_argument('--qemu', default='qemu-system-aarch64')
    parser.add_argument('--timeout', type=float, default=45)
    parser.add_argument('--log', type=Path)
    parser.add_argument('--mode', choices=['native', 'firmware'], default='native',
                        help='firmware: boot without ACPI so the kernel must stay on UEFI')
    args = parser.parse_args()
    output = bytearray()
    with tempfile.TemporaryDirectory(prefix='arm64-smoke-') as directory:
        image = Path(directory) / 'test.img'
        shutil.copyfile(args.image, image)
        machine = 'virt' if args.mode == 'native' else 'virt,acpi=off'
        cmd = [args.qemu, '-machine', machine, '-cpu', 'cortex-a72', '-m', '256',
               '-bios', str(args.firmware), '-drive',
               f'file={image},format=raw,if=none,id=dos',
               '-device', 'virtio-blk-pci,drive=dos', '-nographic', '-monitor',
               'none', '-net', 'none', '-no-reboot',
               # EDK2 otherwise waits out a hidden boot-menu timeout (~5 s).
               '-boot', 'menu=on,splash-time=0']
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
                    drain_until = time.monotonic() + 0.3
                    while time.monotonic() < drain_until:
                        for key, _ in selector.select(timeout=0.03):
                            output.extend(os.read(key.fileobj.fileno(), 8192))
                    raise RuntimeError('Native runtime faulted: ' +
                                       output[-400:].decode(errors='replace'))
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
            if b'Storage: native FAT' not in text:
                raise RuntimeError('Native FAT driver did not mount the boot volume')
            platform = (b'Platform: native AArch64 kernel' if args.mode == 'native'
                        else b'Platform: UEFI firmware services')
            if platform not in text:
                raise RuntimeError('Unexpected platform mode for ' + args.mode)
            command('ver', b'MS-DOS API baseline 4.00')
            command('type ARMTEST.TXT', b'ARM64 FAT read')
            command('echo native-arm64-ok', b'\nnative-arm64-ok\n')
            command('selftest', b'SELFTEST PASS')
            command('native.exe nested', b'Native AArch64 program OK')
            process.stdin.write(b'native input\r')
            process.stdin.flush()
            until(b'INPUT> ')
            process.stdin.write(b'ab\bcd\r')
            process.stdin.flush()
            edited = until(b'A:\\> ')
            if b'Native AArch64 program OK' not in edited:
                raise RuntimeError('Buffered DOS console input/editing failed')
            checks += 1
            if args.mode == 'native':   # firmware mode keeps UEFI's vectors
                command('native fault', b'Program terminated by CPU exception.')
                command('echo code:%ERRORLEVEL%', b'code:1')
            command('native exit7', b'Native AArch64 program OK')
            command('echo code:%ERRORLEVEL%', b'code:7')
            batch = command('script first second', b'script-finished')
            for expected in [b'parameter:first all:first second', b'exit-code-ok',
                             b'below-eight-ok', b'existing-file-ok', b'missing-file-ok',
                             b'child-parameter:nested-argument', b'child-return:2',
                             b'parent-resumed']:
                if expected not in batch:
                    raise RuntimeError('Batch semantics failed: ' + repr(expected))
            if b'BAD-' in batch:
                raise RuntimeError('Batch branching or EXIT /B failed')
            command('echo code:%ERRORLEVEL%', b'code:3')
            command('echo first>OUTPUT.TXT')
            command('echo second>>OUTPUT.TXT')
            text = command('type OUTPUT.TXT', b'first\nsecond\n')
            command('echo >OUTPUT.TXT third')
            text = command('type OUTPUT.TXT', b'third\n')
            if b'first\n' in text:
                raise RuntimeError('Output redirection failed to truncate')
            command('native readin <ARMTEST.TXT >OUTPUT.TXT')
            command('type OUTPUT.TXT', b'Native AArch64 program OK')
            command('script first second >OUTPUT.TXT')
            command('type OUTPUT.TXT', b'script-finished')
            command('echo restored-output', b'\nrestored-output\n')
            command('echo fail <MISSING.TXT >OUTPUT.TXT', b'File/device error.')
            command('echo restored-after-error', b'\nrestored-after-error\n')
            command('del OUTPUT.TXT')
            date = command('date')
            if not re.search(rb'\n\d\d\d\d-\d\d-\d\d\n', date):
                raise RuntimeError('Invalid DATE output')
            clock = command('time')
            if not re.search(rb'\n\d\d:\d\d:\d\d\.\d\d\n', clock):
                raise RuntimeError('Invalid TIME output')
            # Each child deliberately leaves an allocation and file open.
            # More launches than arena slots prove the parent reclaims them.
            for _ in range(70):
                command('native', b'Native AArch64 program OK')
            command('selftest', b'SELFTEST PASS')
            command('dir', b'ARMTEST.TXT')
            command('del DOESNOT.TXT', b'File/device error.')
            command('type DOESNOT.TXT', b'File/device error.')
            command('invalidcommand', b'Bad command or unsupported port feature.')
            command('MISSING.BAT', b'Bad command or unsupported port feature.')
            command('md "WORK DIR"')
            command('cd "WORK DIR"', prompt=b'A:\\WORK DIR> ')
            command('selftest', b'SELFTEST PASS', prompt=b'A:\\WORK DIR> ')
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
            command('dir "WORK DIR"', b'RENAMED.TXT')
            command('rd "WORK DIR"', b'File/device error.')
            command('del "WORK DIR\\RENAMED.TXT"')
            command('rd "WORK DIR"')
            command('cd "WORK DIR"', b'File/device error.')
            command('selftest', b'SELFTEST PASS')
            # Long names written natively must survive for other FAT readers.
            command('md "Native Long Directory"')
            command('copy ARMTEST.TXT "Native Long Directory\\Mixed Case Name.txt"',
                    b'1 file(s) copied.')
            command('dir "Native Long Directory"', b'Mixed Case Name.txt')
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
        check_filesystem(image)


if __name__ == '__main__':
    main()
