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


# ---------------------------------------------------------------------------
# Multi-disk checks (native block layer, src/blk.S): a second session boots
# with three more virtio-blk disks: an MBR disk with two FAT partitions, a
# GPT disk with one Basic Data FAT partition, and a blank disk for INSTALL.
MIB = 1 << 20


def fat_partition(path, sectors, label, files, fat=None):
    """A FAT file system image of `sectors` 512-byte sectors holding files."""
    path.unlink(missing_ok=True)
    cmd = ['mkfs.fat', '-C', '-n', label, '-i', '12345678']
    if fat:
        cmd += ['-F', str(fat)]
    subprocess.run(cmd + [str(path), str(sectors // 2)], check=True, capture_output=True)
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
    for name, data in files.items():
        source = path.with_name('src-' + name)
        source.write_bytes(data)
        subprocess.run(['mcopy', '-i', str(path), str(source), '::/' + name],
                       check=True, env=env)
    return path.read_bytes()


def mbr_entry(kind, start, sectors):
    return struct.pack('<B3sB3sII', 0, b'\xfe\xff\xff', kind, b'\xfe\xff\xff', start, sectors)


def make_mbr_disk(path, size, partitions):
    """partitions: (type, start sector, file system image bytes)."""
    disk = bytearray(size)
    table = b''.join(mbr_entry(kind, start, len(data) // 512) for kind, start, data in partitions)
    disk[446:446 + len(table)] = table
    disk[510:512] = b'\x55\xaa'
    for _, start, data in partitions:
        disk[start * 512:start * 512 + len(data)] = data
    path.write_bytes(disk)


def make_gpt_disk(path, size, start, data):
    import uuid
    import zlib
    sectors = size // 512
    disk = bytearray(size)
    disk[446:462] = mbr_entry(0xee, 1, min(sectors - 1, 0xffffffff))
    disk[510:512] = b'\x55\xaa'
    entry = bytearray(128)
    entry[0:16] = uuid.UUID('ebd0a0a2-b9e5-4433-87c0-68b6b72699c7').bytes_le
    entry[16:32] = uuid.UUID('6e1c5b2a-0d6f-4c1e-9a3b-2f1d4c5b6a7e').bytes_le
    struct.pack_into('<QQ', entry, 32, start, start + len(data) // 512 - 1)
    entry[56:56 + 8] = 'ARMDOS'.encode('utf-16-le')[:8]
    entries = bytes(entry) + bytes(127 * 128)
    disk[1024:1024 + len(entries)] = entries
    header = bytearray(92)
    struct.pack_into('<8sIIIIQQQQ16sQIII', header, 0, b'EFI PART', 0x10000, 92, 0, 0,
                     1, sectors - 1, 34, sectors - 34,
                     uuid.UUID('11111111-2222-3333-4444-555555555555').bytes_le,
                     2, 128, 128, zlib.crc32(entries))
    struct.pack_into('<I', header, 16, zlib.crc32(header))
    disk[512:512 + 92] = header
    disk[start * 512:start * 512 + len(data)] = data
    path.write_bytes(disk)


def check_partition(image, start, sectors, label, files=()):
    """fsck.fat a partition of a disk image and read files back with mtools."""
    part = image.with_name(image.stem + f'-{start}.part')
    with image.open('rb') as disk:
        disk.seek(start * 512)
        part.write_bytes(disk.read(sectors * 512))
    fsck = subprocess.run(['fsck.fat', '-n', str(part)], capture_output=True, text=True)
    if fsck.returncode:
        raise RuntimeError(f'fsck.fat {label}:\n' + fsck.stdout + fsck.stderr)
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
    for name, data in files:
        got = subprocess.run(['mtype', '-i', str(part), '::/' + name],
                             capture_output=True, env=env)
        if got.returncode or got.stdout != data:
            raise RuntimeError(f'{label}: {name} has the wrong contents')


def make_ebr_chain(disk, base, logicals):
    """Logical drives (type, start relative to base, image) in an extended
    partition at sector `base`; each EBR sits one MiB before its drive."""
    for index, (kind, start, data) in enumerate(logicals):
        ebr = start - 2048
        entries = mbr_entry(kind, 2048, len(data) // 512)
        if index + 1 < len(logicals):
            nxt = logicals[index + 1][1] - 2048
            entries += mbr_entry(0x05, nxt, len(logicals[index + 1][2]) // 512 + 2048)
        offset = (base + ebr) * 512
        disk[offset + 446:offset + 446 + len(entries)] = entries
        disk[offset + 510:offset + 512] = b'\x55\xaa'
        disk[(base + start) * 512:(base + start) * 512 + len(data)] = data


def multidisk_session(args, directory, image):
    directory = Path(directory)
    hello = b'hello from disk one\r\n'
    second = b'second partition\r\n'
    # The boot disk grows by 16 MiB holding a second partition (type 0Eh).
    boot = bytearray(image.read_bytes())
    extra = fat_partition(directory / 'b2.fs', 32768 - 2048, 'BOOTP2', {'BOOT2.TXT': b'boot two\r\n'}, 16)
    boot_start = len(boot) // 512 + 2048
    boot += bytes(16 * MIB)
    boot[462:478] = mbr_entry(0x0e, boot_start, len(extra) // 512)
    boot[boot_start * 512:boot_start * 512 + len(extra)] = extra
    image = directory / 'boot2.img'
    image.write_bytes(boot)
    disk1 = directory / 'disk1.img'
    make_mbr_disk(disk1, 64 * MIB, [
        (0x06, 2048, fat_partition(directory / 'p1.fs', 32768, 'DISK1P1', {'HELLO.TXT': hello}, 16)),
        (0x01, 2048 + 32768, fat_partition(directory / 'p2.fs', 8192, 'DISK1P2', {'P2.TXT': second}, 12)),
    ])
    ext_base = 2048 + 32768 + 8192
    logical = fat_partition(directory / 'l5.fs', 8192, 'LOGICAL5', {'L5.TXT': b'logical\r\n'}, 12)
    disk = bytearray(disk1.read_bytes())
    disk[478:494] = mbr_entry(0x0f, ext_base, 64 * MIB // 512 - ext_base)
    make_ebr_chain(disk, ext_base, [(0x0e, 2048, logical)])
    disk1.write_bytes(disk)
    disk2 = directory / 'disk2.img'
    make_gpt_disk(disk2, 24 * MIB, 2048,
                  fat_partition(directory / 'g1.fs', 20480, 'GPTDISK', {'GPT.TXT': b'gpt ok\r\n'}, 12))
    blank = directory / 'blank.img'
    with blank.open('wb') as f:
        f.truncate(64 * MIB)
    # A corrupt table must mount nothing and not hang: entries off the disk,
    # an overflowing length, an EBR chain that links to itself.
    corrupt = directory / 'corrupt.img'
    bad = bytearray(8 * MIB)
    bad[446:510] = (mbr_entry(0x06, 0xfffffff0, 0x100) + mbr_entry(0x0c, 2048, 0xffffffff) +
                    mbr_entry(0x05, 4096, 8192) + mbr_entry(0x0b, 8192, 0))
    bad[510:512] = b'\x55\xaa'
    ebr = 4096 * 512
    bad[ebr + 446:ebr + 478] = mbr_entry(0x06, 0xffffff00, 0x1000) + mbr_entry(0x05, 0, 8192)
    bad[ebr + 510:ebr + 512] = b'\x55\xaa'
    corrupt.write_bytes(bad)
    # A GPT whose entry array lies past the end of the disk, with an entry
    # count far over the 128 read.
    badgpt = directory / 'badgpt.img'
    bad = bytearray(8 * MIB)
    bad[446:462] = mbr_entry(0xee, 1, 8 * MIB // 512 - 1)
    bad[510:512] = b'\x55\xaa'
    struct.pack_into('<8sIIIIQQQQ16sQIII', bad, 512, b'EFI PART', 0x10000, 92, 0, 0,
                     1, 16383, 34, 16000, bytes(16), 16380, 0xffffffff, 128, 0)
    badgpt.write_bytes(bad)
    drives = []
    for index, path in enumerate([image, disk1, disk2, blank, corrupt, badgpt]):
        drives += ['-drive', f'file={path},format=raw,if=none,id=d{index}',
                   '-device', f'virtio-blk-pci,drive=d{index}']
    cmd = [args.qemu, '-machine', 'virt', '-cpu', 'cortex-a72', '-m', '256',
           '-bios', str(args.firmware), *drives, '-nographic', '-monitor', 'none',
           '-net', 'none', '-no-reboot', '-boot', 'menu=on,splash-time=0']
    process = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT)
    output = bytearray()
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)

    def until(expected):
        deadline = time.monotonic() + args.timeout
        mark = len(output)
        while time.monotonic() < deadline:
            for key, _ in selector.select(timeout=0.1):
                chunk = os.read(key.fileobj.fileno(), 8192)
                if not chunk:
                    raise RuntimeError('QEMU exited (multi-disk session)')
                output.extend(chunk)
            cleaned = re.sub(rb'\x1b\[[0-9;=?]*[A-Za-z]', b'', output[mark:])
            if expected in cleaned:
                return cleaned.replace(b'\r', b'')
            if b'CPU exception' in cleaned or b'Synchronous Exception' in cleaned:
                raise RuntimeError('Fault in the multi-disk session: ' +
                                   output[-400:].decode(errors='replace'))
        raise RuntimeError('Timed out waiting for ' + repr(expected) + ' (multi-disk session)')

    checks = 0

    def command(line, expected=b'', prompt=b'A:\\>'):
        nonlocal checks
        process.stdin.write(line.encode() + b'\r')
        process.stdin.flush()
        text = until(prompt)
        if expected not in text:
            raise RuntimeError('Incorrect output for ' + line + ' (multi-disk session)')
        checks += 1
        return text

    try:
        text = until(b'A:\\>')
        for expected in [b'Drive C: is disk 0, partition 2', b'Drive D: is disk 1, partition 1',
                         b'Drive E: is disk 1, partition 2', b'Drive F: is disk 1, partition 5',
                         b'Drive G: is disk 2, partition 1']:
            if expected not in text:
                raise RuntimeError('Not mounted at boot: ' + expected.decode())
        if b'is disk 4' in text or b'is disk 5' in text:
            raise RuntimeError('A corrupt partition table was mounted')
        checks += 1
        command('type c:\\BOOT2.TXT', b'boot two')
        command('dir d:', b'HELLO    TXT')
        command('vol e:', b'Volume in drive E is DISK1P2')
        command('type e:\\P2.TXT', second.replace(b'\r', b''))
        command('type f:\\L5.TXT', b'logical')
        command('dir g:', b'GPT      TXT')
        command('copy d:\\HELLO.TXT g:\\', b'1 File(s) copied')
        command('type g:\\HELLO.TXT', b'hello from disk one')
        command('md d:\\NEWDIR')
        command('copy ARMTEST.TXT d:\\NEWDIR\\X.TXT', b'1 File(s) copied')
        command('copy g:\\GPT.TXT e:\\', b'1 File(s) copied')
        command('copy f:\\L5.TXT c:\\', b'1 File(s) copied')
        command('d:', prompt=b'D:\\>')
        command('dir', b'NEWDIR', prompt=b'D:\\>')
        command('a:')
        for drive in 'cd':
            text = command(f'chkdsk {drive}:', b'bytes total disk space')
            if b'rror' in text or b'lost' in text:
                raise RuntimeError(f'CHKDSK {drive.upper()}: found problems')
        command('chkdsk g:', b'bytes total disk space')
        # INSTALL natively: disk 3 is the blank one (E0h offers disks 1-3).
        text = command('install 3 /y', b'ARM DOS is installed on disk 3')
        found = re.search(rb'Formatting drive ([A-Z]):', text)
        if not found:
            raise RuntimeError('INSTALL did not name the new drive')
        letter = found.group(1).decode()
        command(f'dir {letter}:\\EFI\\BOOT', b'BOOTAA64 EFI')
        command(f'type {letter}:\\ARMTEST.TXT', b'ARM64 FAT read')
        # Disk 1's volumes are drives C: and D:: INSTALL must not wipe it.
        command('install 1 /y', b'part of it is already a drive')
    finally:
        selector.close()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        if args.log:
            args.log.with_name(args.log.stem + '-disks.log').write_bytes(output)
    check_partition(image, boot_start, len(extra) // 512, 'boot disk partition 2',
                    [('L5.TXT', b'logical\r\n')])
    check_partition(disk1, ext_base + 2048, 8192, 'disk 1 logical drive', [('L5.TXT', b'logical\r\n')])
    check_partition(disk1, 2048, 32768, 'disk 1 partition 1',
                    [('HELLO.TXT', hello), ('NEWDIR/X.TXT', b'ARM64 FAT read\r\n')])
    check_partition(disk1, 2048 + 32768, 8192, 'disk 1 partition 2', [('GPT.TXT', b'gpt ok\r\n')])
    check_partition(disk2, 2048, 20480, 'GPT disk', [('HELLO.TXT', hello)])
    mbr = blank.read_bytes()[:512]
    kind, start, sectors = mbr[446 + 4], *struct.unpack_from('<II', mbr, 446 + 8)
    if mbr[510:512] != b'\x55\xaa' or kind != 0xef:
        raise RuntimeError('INSTALL wrote no MBR partition')
    check_partition(blank, start, sectors, 'installed disk',
                    [('ARMTEST.TXT', b'ARM64 FAT read\r\n')])
    print(f'PASS: multi-disk session (C:-G: on the boot disk and two more disks, MBR, EBR and GPT, native INSTALL '
          f'to drive {letter}:), {checks} checks; fsck.fat clean on every volume.')
# End of the multi-disk checks.
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('image', type=Path)
    parser.add_argument('--firmware', required=True, type=Path)
    parser.add_argument('--qemu', default='qemu-system-aarch64')
    parser.add_argument('--timeout', type=float, default=45)
    parser.add_argument('--log', type=Path)
    parser.add_argument('--mode', choices=['native', 'firmware'], default='native',
                        help='firmware: boot without ACPI so the kernel must stay on UEFI')
    parser.add_argument('--no-disks', action='store_true',
                        help='skip the multi-disk session (native mode)')
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
            command('ver', b'ARM DOS Version 4.00')
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
            # Restart loops (no CALL) replace the batch file: 20 rounds, more
            # than the 16 nested levels allowed.
            command('set N=')
            command('echo @set N=%N%x>LOOP.BAT')
            command('echo @if not "%N%"=="xxxxxxxxxxxxxxxxxxxx" loop>>LOOP.BAT')
            command('echo @echo loop-done>>LOOP.BAT')
            command('loop', b'loop-done')
            command('set N=')
            command('del LOOP.BAT')
            command('del C?.BAT')
            # CTTY lasts past its own command line (AUX is the same UART).
            command('ctty aux')
            command('echo via-aux', b'\nvia-aux\n')
            command('ctty con')
            command('del EL.BAT')
            # The command word ends at = / . \\ as in COMMAND; & is text.
            command('echo.hello World', b'\nhello World\n')
            command('echo .dot', b'\n.dot\n')
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
            # Milestone 6: utilities from MS-DOS 4.0 src/CMD.
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
            # FORMAT /SELECT (INSTALL's call) asks nothing; INSTALL offers no
            # disk here: the only disk is the boot disk (or the native kernel).
            text = command('format c: /select /v:WORK', b'Format complete.')
            if b'(Y/N)' in text or b'Volume label' in text:
                raise RuntimeError('FORMAT /SELECT asked a question')
            command('install', b'No disk to install on')
            command('install /x', b'Usage: INSTALL [disk] [/Y]')
            command('install /y', b'needs the disk number')
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
            if b'ARM DOS Version' not in keys(b'x', b'A:\\>'):
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
            # ARM BASIC: a program from the disk, typed lines, INPUT, SAVE,
            # Ctrl-C in a loop and an error report.
            command('basic primes', b' 89  97 \nOk', prompt=b'Ok\r\n')
            command('LIST 30', b'30 FOR N = 2 TO 99', prompt=b'Ok\r\n')
            command('NEW', prompt=b'Ok\r\n')
            command('10 A$="ARM": FOR I=1 TO 3: PRINT A$;I;: NEXT: PRINT',
                    prompt=b'NEXT: PRINT')
            command('20 INPUT "N";N: PRINT N*2; LEFT$(A$,2); LEN(A$)',
                    prompt=b'LEN(A$)')
            command('RUN', b'ARM 1 ARM 2 ARM 3 \nN? ', prompt=b'N? ')
            command('21', b' 42 AR 3 \nOk', prompt=b'Ok\r\n')
            command('SAVE "T1"', prompt=b'Ok\r\n')
            command('PRINT 1/0', b'Division by zero', prompt=b'Ok\r\n')
            command('RUN', b'N? ', prompt=b'N? ')
            keys(b'\x03', b'^C')
            command('', b'Break in 20', prompt=b'Ok\r\n')
            command('NEW', prompt=b'Ok\r\n')
            command('30 GOTO 30', prompt=b'GOTO 30')
            keys(b'RUN\r', b'RUN')
            time.sleep(1)
            if b'Break in 30' not in keys(b'\x03', b'Ok\r\n'):
                raise RuntimeError('Ctrl-C did not stop the BASIC program')
            checks += 1
            command('NEW', prompt=b'Ok\r\n')
            for line in ('10 DATA 3, ok,, 7',
                         '20 READ N, M$, Z, S: ON N GOSUB 100, 100, 200: PRINT M$; Z+S',
                         '30 IF DIFF THEN PRINT "bad" ELSE PRINT "else-ok": REM ELSE PRINT "bad"',
                         '40 PRINT 2^3^2; 10 \\ 3 * 2 \' precedence as in GW-BASIC',
                         '50 END', '100 PRINT "one-two": RETURN', '200 PRINT "three": RETURN'):
                command(line, prompt=line[-12:].encode())
            command('RUN', b'three\nok 7 \nelse-ok\n 64  1 \nOk', prompt=b'Ok\r\n')
            if b'50 END' in command('LIST 100-200', b'100 PRINT "one-two"', prompt=b'Ok\r\n'):
                raise RuntimeError('LIST 100-200 listed line 50')
            command('SAVE "T2"', prompt=b'Ok\r\n')
            command('NEW', prompt=b'Ok\r\n')
            command('LOAD "T2"', prompt=b'Ok\r\n')
            command('LIST -10', b'10 DATA 3, ok,, 7\nOk', prompt=b'Ok\r\n')
            command('RUN', b'three\nok 7 \nelse-ok', prompt=b'Ok\r\n')
            command('PRINT 9223372036854775807+1', b'Overflow', prompt=b'Ok\r\n')
            command('SYSTEM')
            command('del T2.BAS')
            command('type T1.BAS', b'20 INPUT "N";N: PRINT N*2; LEFT$(A$,2); LEN(A$)')
            command('del T1.BAS')
            # COUNTRY.SYS (assembled from MKCNTRY.ASM) supplies other code pages.
            command('chcp', b'Active code page: 437')
            command('chcp 850')
            command('chcp', b'Active code page: 850')
            command('chcp 865', b'Invalid code page')
            command('chcp 437')
            # The UEFI console shows ESC as '?': ANSI sequences must become
            # ConOut calls in firmware mode, never reach it as text (checked
            # in both modes so `check` and `validate` cover it).
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
        if args.mode == 'native' and not args.no_disks:
            multidisk_session(args, directory, image)


if __name__ == '__main__':
    main()
