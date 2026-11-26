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

        def command(line, expected=b'', prompt=b'A:\\>'):
            nonlocal checks
            process.stdin.write(line.encode() + b'\r')
            process.stdin.flush()
            text = until(prompt).replace(b'\r', b'')
            if expected not in text:
                raise RuntimeError('Incorrect output for ' + line)
            checks += 1
            return text

        try:
            text = until(b'A:\\>')
            if b'SELFTEST PASS' not in text:
                raise RuntimeError('Boot self-test did not complete')
            if b'Error in CONFIG.SYS line 11' not in text:
                raise RuntimeError('CONFIG.SYS errors are not reported')
            if b'AUTOEXEC.BAT ran' not in text:
                raise RuntimeError('AUTOEXEC.BAT did not run at boot')
            if b'Storage: native FAT' not in text:
                raise RuntimeError('Native FAT driver did not mount the boot volume')
            platform = (b'Platform: native AArch64 kernel' if args.mode == 'native'
                        else b'Platform: UEFI firmware services')
            if platform not in text:
                raise RuntimeError('Unexpected platform mode for ' + args.mode)
            command('ver', b'MS-DOS API baseline 4.00')
            # % expansion is for batch files: EL.BAT reports ERRORLEVEL.
            command('echo @echo code:%ERRORLEVEL%>EL.BAT')
            command('type ARMTEST.TXT', b'ARM64 FAT read')
            command('echo native-arm64-ok', b'\nnative-arm64-ok\n')
            command('selftest', b'SELFTEST PASS')
            command('native.exe nested', b'Native AArch64 program OK')
            process.stdin.write(b'native input\r')
            process.stdin.flush()
            until(b'INPUT>')
            process.stdin.write(b'ab\bcd\r')
            process.stdin.flush()
            edited = until(b'A:\\>')
            if b'Native AArch64 program OK' not in edited:
                raise RuntimeError('Buffered DOS console input/editing failed')
            checks += 1
            if args.mode == 'native':   # firmware mode keeps UEFI's vectors
                command('native fault', b'Program terminated by CPU exception.')
                command('el', b'code:1')
            command('dostest', b'DOSTEST PASS')
            process.stdin.write(b'dostest ctrlc\r')
            process.stdin.flush()
            until(b'WAIT>')
            process.stdin.write(b'\x03')
            process.stdin.flush()
            text = until(b'A:\\>')
            if b'^C' not in text or b'CTRL-C OK' not in text:
                raise RuntimeError('Ctrl-C did not end the program with type 1')
            checks += 1
            command('native exit7', b'Native AArch64 program OK')
            command('el', b'code:7')
            batch = command('script first second', b'script-finished')
            for expected in [b'parameter:first all:first second', b'exit-code-ok',
                             b'below-eight-ok', b'existing-file-ok', b'missing-file-ok',
                             b'child-parameter:nested-argument', b'child-return:2',
                             b'parent-resumed']:
                if expected not in batch:
                    raise RuntimeError('Batch semantics failed: ' + repr(expected))
            if b'BAD-' in batch:
                raise RuntimeError('Batch branching or EXIT /B failed')
            command('el', b'code:3')
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
            # COPY A+B A appends B to A (it must not truncate A first).
            command('echo AAA>CAT1.TXT')
            command('echo BBB>CAT2.TXT')
            command('copy CAT1.TXT+CAT2.TXT CAT1.TXT')
            command('type CAT1.TXT', b'AAA\nBBB')
            command('del CAT1.TXT')
            command('del CAT2.TXT')
            # 0Dh/68h with read-only handles; DOS error codes 2 vs 3.
            command('native disk', b'Native AArch64 program OK')
            command('echo 50% done', b'\n50% done\n')
            command('cd NOSUCH', b'File/device error.')
            command('el', b'code:3')
            process.stdin.write(b'date\r')
            process.stdin.flush()
            date = until(b'Enter new date (mm-dd-yy): ').replace(b'\r', b'')
            if not re.search(rb'Current date is \w\w\w \d\d-\d\d-\d\d\d\d\n', date):
                raise RuntimeError('Invalid DATE output')
            command('', b'')
            process.stdin.write(b'time\r')
            process.stdin.flush()
            clock = until(b'Enter new time: ').replace(b'\r', b'')
            if not re.search(rb'Current time is +\d?\d:\d\d:\d\d\.\d\d', clock):
                raise RuntimeError('Invalid TIME output')
            command('', b'')
            command('date 12-31-2026')
            command('date', b'12-31-2026', prompt=b'(mm-dd-yy): ')
            command('', b'')
            command('date 13-01-2026', b'Invalid date', prompt=b'(mm-dd-yy): ')
            command('', b'')
            command('time 12:00:00', b'')
            # Each child deliberately leaves an allocation and file open.
            # More launches than arena slots prove the parent reclaims them.
            for _ in range(70):
                command('native', b'Native AArch64 program OK')
            command('selftest', b'SELFTEST PASS')
            command('dir', b'ARMTEST  TXT')
            command('del DOESNOT.TXT', b'File not found')
            command('type DOESNOT.TXT', b'File/device error.')
            command('invalidcommand', b'Bad command or file name')
            command('MISSING.BAT', b'Bad command or file name')
            command('md "WORK DIR"')
            command('cd "WORK DIR"', prompt=b'A:\\WORK DIR>')
            command('selftest', b'SELFTEST PASS', prompt=b'A:\\WORK DIR>')
            command('copy ..\\ARMTEST.TXT "COPY FILE.TXT"', b'1 File(s) copied',
                    prompt=b'A:\\WORK DIR>')
            command('type "COPY FILE.TXT"', b'ARM64 FAT read', prompt=b'A:\\WORK DIR>')
            command('copy "COPY FILE.TXT" ".\\copy file.txt"', b'File cannot be copied onto itself',
                    prompt=b'A:\\WORK DIR>')
            command('type "COPY FILE.TXT"', b'ARM64 FAT read', prompt=b'A:\\WORK DIR>')
            command('ren "COPY FILE.TXT" RENAMED.TXT', prompt=b'A:\\WORK DIR>')
            command('dir re?amed.*', b'RENAMED  TXT', prompt=b'A:\\WORK DIR>')
            command('attrib +r RENAMED.TXT', prompt=b'A:\\WORK DIR>')
            command('del RENAMED.TXT', b'Access denied', prompt=b'A:\\WORK DIR>')
            command('attrib -r RENAMED.TXT', prompt=b'A:\\WORK DIR>')
            command('cd ..')
            command('dir "WORK DIR"', b'RENAMED  TXT')
            command('rd "WORK DIR"', b'File/device error.')
            command('del "WORK DIR\\RENAMED.TXT"')
            command('rd "WORK DIR"')
            command('cd "WORK DIR"', b'File/device error.')
            # RD must refuse the current directory however it is spelled.
            command('md CASEDIR')
            command('cd \\casedir', prompt=b'A:\\casedir>')
            command('rd \\CASEDIR', b'File/device error.', prompt=b'A:\\casedir>')
            command('cd \\')
            command('rd casedir')
            command('selftest', b'SELFTEST PASS')
            # Long names written natively must survive for other FAT readers.
            command('md "Native Long Directory"')
            command('copy ARMTEST.TXT "Native Long Directory\\Mixed Case Name.txt"',
                    b'1 File(s) copied')
            command('dir "Native Long Directory"', b'Mixed Case Name.txt')
            # Milestone 4: COMMAND parity.
            text = command('features alpha beta', b'end-features')
            for expected in [b'item:one', b'item:three', b'txt:ARMTEST.TXT', b'arg:alpha',
                             b'arg:beta', b'env-ok', b'compare-ok']:
                if expected not in text:
                    raise RuntimeError('FOR/SHIFT/IF failed: ' + repr(expected))
            command('set', b'ARMDOS=1')
            command('set GREETING=hello')
            command('echo %GREETING%', b'\n%GREETING%\n')
            command('echo @echo %GREETING%>GR.BAT')
            command('gr', b'\nhello\n')
            command('del GR.BAT')
            # A batch file run from another without CALL replaces it.
            command('echo @c2>C1.BAT')
            command('echo @echo after-chain>>C1.BAT')
            command('echo @echo in-c2>C2.BAT')
            if b'after-chain' in command('c1', b'in-c2'):
                raise RuntimeError('batch chaining returned to the caller')
            command('echo @call c2>C1.BAT')
            command('echo @echo after-call>>C1.BAT')
            command('c1', b'after-call')
            command('del C?.BAT')
            # CTTY lasts past its own command line (AUX is the same UART).
            command('ctty aux')
            command('echo via-aux', b'\nvia-aux\n')
            command('ctty con')
            command('del EL.BAT')
            # The command word ends at = / . \\ as in COMMAND; & is text.
            command('echo.hello World', b'\nhello World\n')
            command('cd\\')
            command('dir/w *.bat', b'AUTOEXEC BAT')
            command('echo R&D', b'\nR&D\n')
            command('for %f in (a b) do echo X%f', b'Xb')
            command('set GREETING=')
            if b'GREETING' in command('set', b'PATH=A:\\'):
                raise RuntimeError('SET did not remove a variable')
            command('path', b'PATH=A:\\')
            command('prompt $N$G', prompt=b'\nA>')
            command('prompt', prompt=b'A:\\>')
            command('echo.', b'echo.\n\n')
            command('type ARMTEST.TXT | native readin', b'Native AArch64 program OK')
            command('dir %PIPE*.*', b'File not found')
            text = command('dir', b'bytes free')
            if not re.search(rb'ARMTEST  TXT +16 ', text) or b'Directory of  A:\\' not in text:
                raise RuntimeError('DIR format')
            command('md WILD')
            command('copy *.BAT WILD', b'4 File(s) copied')
            command('dir WILD /w', b'FEATURES BAT')
            command('ren WILD\\*.BAT *.CMD')
            command('dir WILD\\*.CMD', b'4 File(s)')
            command('copy WILD\\CHILD.CMD+ARMTEST.TXT WILD\\JOINED.TXT', b'1 File(s) copied')
            command('type WILD\\JOINED.TXT', b'ARM64 FAT read')
            command('del WILD\\*.CMD')
            command('dir WILD\\*.CMD', b'File not found')
            process.stdin.write(b'del WILD\r')
            process.stdin.flush()
            until(b'Are you sure (Y/N)?')
            process.stdin.write(b'y')
            process.stdin.flush()
            until(b'A:\\>')
            checks += 1
            command('rd WILD')
            command('vol', b'Volume in drive A is ARMDOS')
            command('verify on')
            command('verify', b'VERIFY is on')
            command('verify off')
            command('break on')
            command('break', b'BREAK is on')
            command('break off')
            command('truename armtest.txt', b'A:\\ARMTEST.TXT')
            command('chcp', b'Active code page: 437')
            process.stdin.write(b'pause\r')
            process.stdin.flush()
            until(b'Press any key to continue')
            process.stdin.write(b'x')
            process.stdin.flush()
            until(b'A:\\>')
            checks += 1
            command('ctty BOGUS', b'Invalid device')
            process.stdin.write(b'copy con TYPED.TXT\r')
            process.stdin.flush()
            time.sleep(0.5)
            process.stdin.write(b'typed at the console\r\x1a')
            process.stdin.flush()
            until(b'A:\\>')
            checks += 1
            command('type TYPED.TXT', b'typed at the console\n')
            command('del TYPED.TXT')
            # Milestone 5: CONFIG.SYS (DEVICE= driver, FILES=, SHELL= COMSPEC).
            command('echo hello driver>UPPER$')
            command('type UPPER$', b'HELLO DRIVER')
            command('set', b'COMSPEC=\\EFI\\BOOT\\BOOTAA64.EFI')
            # Milestone 6: utilities from v4.0/src/CMD.
            def keys(data, wait):
                process.stdin.write(data)
                process.stdin.flush()
                return until(wait).replace(b'\r', b'')
            command('find /c "a" FC1.TXT', b'---------- FC1.TXT: 5')
            command('sort /r < SORTIN.TXT', b'pear\ncherry\nBanana\napple')
            command('mem', b'largest executable program size')
            command('tree', b'Directory PATH listing for Volume ARMDOS')
            command('comp FC1.TXT FC2.TXT', b'Files are different sizes', prompt=b'(Y/N) ?')
            keys(b'n', b'A:\\>')
            command('fc FC1.TXT FC2.TXT', b'***** FC2.TXT\nbeta\nGAMMA changed\ndelta\n*****')
            command('fc FC1.TXT FC1.TXT', b'FC: no differences encountered')
            command('chkdsk', b'bytes total disk space')
            command('md XC')
            command('md XC\\SUB')
            command('copy FC1.TXT XC\\SUB', b'1 File(s) copied')
            command('xcopy XC XD\\ /s', b'XC\\SUB\\FC1.TXT\n        1 File(s) copied')
            command('type XD\\SUB\\FC1.TXT', b'alpha')
            command('attrib +r XD\\SUB\\FC1.TXT')
            command('attrib XD\\FC1.TXT /s', b'A    R     A:\\XD\\SUB\\FC1.TXT')
            command('replace XC\\SUB\\FC1.TXT XD /s', b'Access denied - A:\\XD\\SUB\\FC1.TXT')
            command('replace XC\\SUB\\FC1.TXT XD /s /r', b'1 file(s) replaced')
            command('replace FC2.TXT XD /a', b'Adding A:\\XD\\FC2.TXT')
            command('echo appended data>XD\\SUB\\APP.TXT')
            command('append A:\\XD\\SUB')
            command('append', b'APPEND=A:\\XD\\SUB')
            command('type APP.TXT', b'appended data')
            command('find "data" APP.TXT', b'appended data')
            command('append ;')
            command('append', b'No Append')
            keys(b'edlin ED.TXT\r', b'*')
            keys(b'i\r', b':*')
            keys(b'first line\r', b':*')
            keys(b'second line\r', b':*')
            keys(b'\x1a\r', b'*')
            keys(b'1d\r', b'*')
            text = keys(b'l\r', b'second line\r\n*')
            if b'1:*second line' not in text:
                raise RuntimeError('EDLIN delete/list failed')
            checks += 1
            keys(b'e\r', b'A:\\>')
            command('type ED.TXT', b'second line\n')
            # Drives B:-D: come from RAMDRIVE/VDISK in the CONFIG.SYS fixture.
            command('b:', prompt=b'B:\\>')
            command('echo on b>B.TXT', prompt=b'B:\\>')
            command('dir', b'Volume in drive B is MS-RAMDRIVE', prompt=b'B:\\>')
            command('a:')
            command('format c: /v:WORK', b'DRIVE C: WILL BE LOST!', prompt=b'(Y/N)?')
            text = keys(b'y', b'A:\\>')
            if b'Format complete.' not in text:
                raise RuntimeError('FORMAT failed')
            checks += 1
            command('sys c:', b'System transferred')
            command('diskcopy b: c:', b'Insert TARGET diskette in drive C:', prompt=b'continue . . .')
            if b'Copying' not in keys(b' ', b'(Y/N)? '):
                raise RuntimeError('DISKCOPY failed')
            keys(b'n', b'A:\\>')
            checks += 1
            command('diskcomp b: c:', b'Insert SECOND diskette in drive C:', prompt=b'continue . . .')
            if b'Compare OK' not in keys(b' ', b'(Y/N) ? '):
                raise RuntimeError('DISKCOMP failed')
            keys(b'n', b'A:\\>')
            checks += 1
            command('md SB')
            command('subst e: a:\\sb')
            command('subst', b'E: => A:\\SB')
            command('copy FC1.TXT e:', b'1 File(s) copied')
            command('type SB\\FC1.TXT', b'alpha')
            command('subst e: /d')
            command('assign d=b')
            command('type d:\\B.TXT', b'on b')
            command('assign')
            command('join c: a:\\cj')
            command('join', b'C: => A:\\CJ')
            command('dir a:\\cj', b'B        TXT')
            command('join c: /d')
            command('backup a:\\xc\\*.* b: /s', b'B:\\ root directory will be erased',
                    prompt=b'continue . . .')
            if b'\\XC\\SUB\\FC1.TXT' not in keys(b' ', b'A:\\>'):
                raise RuntimeError('BACKUP failed')
            checks += 1
            command('del XC\\SUB\\FC1.TXT')
            command('restore b: a:\\xc\\*.* /s', b'Insert backup diskette 01 in drive B:',
                    prompt=b'continue . . .')
            text = keys(b' ', b'A:\\>')
            if b'*** Restoring files from drive B: ***' not in text or b'\\XC\\SUB\\FC1.TXT' not in text:
                raise RuntimeError('RESTORE failed')
            checks += 1
            command('type XC\\SUB\\FC1.TXT', b'alpha')
            # Milestone 7: PRINTER.SYS sends PRN to the serial line; ANSI.SYS
            # reassigns keys (x types "ver" and Enter) and reports the cursor.
            command('echo printed>PRN', b'PRN\nprinted\n')
            command('prompt $e[120;"ver";13p$p$g')
            command('prompt $p$g')
            if b'MS-DOS API baseline' not in keys(b'x', b'A:\\>'):
                raise RuntimeError('ANSI.SYS key reassignment failed')
            checks += 1
            command('prompt $e[120p$p$g')
            command('prompt $p$g')
            command('echo x', b'echo x\nx\n')
            command('cls')
            # The report is typed into the next command line; erase it.
            if b'[2;1R' not in keys(b'prompt $e[6n$p$g\r', b'1R'):
                raise RuntimeError('ANSI.SYS cursor report failed')
            keys(b'\b' * 8 + b'prompt $p$g\r', b'A:\\>')
            checks += 1
            command('echo done', b'echo done\ndone')
            # COUNTRY.SYS (assembled from MKCNTRY.ASM) supplies other code pages.
            command('chcp', b'Active code page: 437')
            command('chcp 850')
            command('chcp', b'Active code page: 850')
            command('chcp 865', b'Invalid code page')
            command('chcp 437')
            # The UEFI console shows ESC as '?': ANSI sequences must become
            # ConOut calls in firmware mode, never reach it as text.
            if b'?[' in output:
                raise RuntimeError('an ANSI sequence reached the UEFI console')
            checks += 1
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
