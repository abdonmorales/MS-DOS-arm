#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""C SDK end-to-end test: copy the SDK's programs (sdk/) onto a copy of the
disk image with mtools, boot it under QEMU as tools/smoke.py does, run them
from COMMAND and check their console output, then check on the host the
files they wrote (text CR LF lines, binary bytes, WC's report)."""
import argparse
import os
from pathlib import Path
import re
import selectors
import shutil
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
MTOOLS_ENV = dict(os.environ, MTOOLS_SKIP_CHECK='1', MTOOLS_NO_VFAT='0')

# A file with known counts for WC: 4 lines, 9 words, CR LF line ends.
WCDATA = b'one two three\r\nfour\r\n\r\n  five six  seven eight nine\r\n'


def host_printf_check(cc):
    """The printf expectations, checked against the host C library."""
    if not shutil.which(cc):
        print(f'SKIP: no host {cc}: printf cases not cross-checked on the host')
        return
    with tempfile.TemporaryDirectory(prefix='sdk-printf-') as directory:
        exe = Path(directory) / 'printf_host'
        subprocess.run([cc, '-Wall', '-Wno-format', '-I', str(ROOT / 'sdk/tests'), '-o',
                        str(exe), str(ROOT / 'sdk/tools/printf_host.c')], check=True)
        result = subprocess.run([str(exe)], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError('printf cases disagree with the host C library:\n' +
                               result.stdout)
        print('PASS: ' + result.stdout.strip() + ' (host C library agrees)')


def partition_spec(image):
    start = struct.unpack_from('<I', image.read_bytes()[:512], 454)[0]
    return f'{image}@@{start * 512}'


def mcopy(spec, source, name):
    subprocess.run(['mcopy', '-o', '-i', spec, str(source), f'::/{name}'],
                   check=True, env=MTOOLS_ENV)


def mtype(spec, name):
    result = subprocess.run(['mtype', '-i', spec, f'::/{name}'], capture_output=True,
                            env=MTOOLS_ENV)
    if result.returncode:
        raise RuntimeError(f'{name} is missing from the disk after the session')
    return result.stdout


def wc_counts(data):
    """What WC.EXE reports for a file: lines, words, bytes."""
    return data.count(b'\n'), len(data.split()), len(data)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('image', type=Path)
    parser.add_argument('--sdk-build', type=Path, required=True)
    parser.add_argument('--firmware', required=True, type=Path)
    parser.add_argument('--qemu', default='qemu-system-aarch64')
    parser.add_argument('--host-cc', default='cc')
    parser.add_argument('--timeout', type=float, default=30)
    parser.add_argument('--log', type=Path)
    args = parser.parse_args()
    host_printf_check(args.host_cc)
    output = bytearray()
    with tempfile.TemporaryDirectory(prefix='arm64-sdk-') as directory:
        image = Path(directory) / 'test.img'
        shutil.copyfile(args.image, image)
        spec = partition_spec(image)
        for name in ('HELLO.EXE', 'WC.EXE', 'LIBTEST.EXE'):
            mcopy(spec, args.sdk_build / name, name)
        data = Path(directory) / 'WCDATA.TXT'
        data.write_bytes(WCDATA)
        mcopy(spec, data, 'WCDATA.TXT')
        # Every *.TXT WC will count, read back before the boot.
        listing = subprocess.run(['mdir', '-b', '-i', spec, '::/*.TXT'], capture_output=True,
                                 text=True, env=MTOOLS_ENV, check=True).stdout.split()
        texts = {Path(p).name.upper(): mtype(spec, Path(p).name) for p in listing}

        cmd = [args.qemu, '-machine', 'virt', '-cpu', 'cortex-a72', '-m', '256',
               '-bios', str(args.firmware), '-drive', f'file={image},format=raw,if=none,id=dos',
               '-device', 'virtio-blk-pci,drive=dos', '-nographic', '-monitor', 'none',
               '-net', 'none', '-no-reboot', '-boot', 'menu=on,splash-time=0']
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
                if b'Synchronous Exception' in cleaned or b'terminated by CPU exception' in cleaned:
                    raise RuntimeError('A program faulted: ' +
                                       output[-600:].decode(errors='replace'))
            raise RuntimeError('Timed out waiting for ' + repr(expected))

        checks = 0

        def command(line, *expected, absent=()):
            nonlocal checks
            process.stdin.write(line.encode() + b'\r')
            process.stdin.flush()
            text = until(b'A:\\>').replace(b'\r', b'')
            for item in expected:
                if item not in text:
                    raise RuntimeError(f'{line}: expected {item!r} in:\n' +
                                       text.decode(errors='replace'))
            for item in absent:
                if item in text:
                    raise RuntimeError(f'{line}: unexpected {item!r}')
            checks += 1
            return text

        try:
            until(b'A:\\>')
            command('echo @echo code:%ERRORLEVEL%>EL.BAT')
            command('hello one "two words"  three', b'Hello from C on ARM DOS 4.00!',
                    b'argc=4\n', b'argv[0]=[HELLO]\n', b'argv[1]=[one]\n',
                    b'argv[2]=[two words]\n', b'argv[3]=[three]\n', b'env: COMSPEC=',
                    b'PATH is ', b'Current directory: A:\\\n', b'Date: ')
            command('el', b'code:0')
            command('hello !', b'argv[1]=[!]')
            command('el', b'code:3')
            command('hello redirected >HELLO.OUT', absent=(b'argv[1]',))
            text = command('libtest "quoted arg" x\\"y', b'LIBTEST PASS')
            passed = re.search(rb'LIBTEST PASS (\d+)', text).group(1).decode()
            command('el', b'code:0')
            total = [sum(c) for c in zip(*(wc_counts(d) for d in texts.values()))]
            lines, words, size = wc_counts(WCDATA)
            command('wc /L /O:REPORT.TXT *.TXT',
                    f'{lines:7d} {words:7d} {size:8d}  WCDATA.TXT   (longest line 28)'.encode(),
                    f'{total[0]:7d} {total[1]:7d} {total[2]:8d}  total ({len(texts)} files)'.encode(),
                    b'Report written to REPORT.TXT')
            command('wc NOSUCH.*', b'WC: NOSUCH.*: No such file or directory')
            command('el', b'code:1')
            command('wc', b'usage: WC')
            command('el', b'code:2')
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

        # Files the programs wrote, read with mtools.
        expected = b''.join(f'line {i:02d}: {"odd" if i % 2 else "even"}\r\n'.encode()
                            for i in range(1, 51)) + b'appended\r\n'
        if mtype(spec, 'LIBTEST.OUT') != expected:
            raise RuntimeError('LIBTEST.OUT does not hold the expected CR LF text')
        binary = bytearray((i * 7 + i // 256) & 0xff for i in range(5000))
        binary[10:16] = b'ARMDOS'
        if mtype(spec, 'LIBTEST.BIN') != bytes(binary):
            raise RuntimeError('LIBTEST.BIN does not hold the expected bytes')
        hello = mtype(spec, 'HELLO.OUT')
        if b'argv[1]=[redirected]\r\n' not in hello or b'\n' in hello.replace(b'\r\n', b''):
            raise RuntimeError('redirected stdout lacks CR LF lines: ' + repr(hello[:200]))
        report = mtype(spec, 'REPORT.TXT').decode()
        want = f'{total[0]:7d} {total[1]:7d} {total[2]:8d}  total ({len(texts)} files)\r\n'
        if not report.endswith(want) or report.count('\r\n') != len(texts) + 2:
            raise RuntimeError('REPORT.TXT is wrong:\n' + report)
        start = struct.unpack_from('<I', image.read_bytes()[:512], 454)[0]
        partition = Path(directory) / 'partition.img'
        with image.open('rb') as disk, partition.open('wb') as out:
            disk.seek(start * 512)
            shutil.copyfileobj(disk, out)
        fsck = subprocess.run(['fsck.fat', '-n', str(partition)], capture_output=True, text=True)
        if fsck.returncode:
            raise RuntimeError('fsck.fat after the SDK programs:\n' + fsck.stdout + fsck.stderr)
    print(f'PASS: C SDK programs under ARM DOS: LIBTEST {passed} library checks, '
          f'{checks} console checks; files verified on the host, fsck.fat clean.')


if __name__ == '__main__':
    main()
