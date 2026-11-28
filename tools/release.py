#!/usr/bin/env python3
"""The ARM DOS release file set, shared by the live ISO and the ROM builds.

The release set is build/msdos-arm64.img's root directory with the smoke-test
fixtures left out and a plain CONFIG.SYS and AUTOEXEC.BAT. ARMTEST.TXT and
NATIVE.EXE stay: the boot self-test reads and runs them on writable media.
"""
import os
from pathlib import Path
import struct
import subprocess

# Test fixtures of the disk image that a release does not carry.
TEST_ONLY = {'TESTDRV.SYS', 'DOSTEST.EXE', 'FC1.TXT', 'FC2.TXT',
             'LINES.TXT', 'SORTIN.TXT', 'CHILD.BAT', 'SCRIPT.BAT', 'FEATURES.BAT'}
CONFIG_SYS = (b'REM CONFIG.SYS for ARM DOS\r\n'
              b'FILES=40\r\n'
              b'BUFFERS=20\r\n'
              b'COUNTRY=001\r\n'
              b'LASTDRIVE=Z\r\n'
              b'DEVICE=\\RAMDRIVE.SYS 1024 512 112\r\n'
              b'DEVICE=\\ANSI.SYS\r\n')
AUTOEXEC_BAT = b'@ECHO OFF\r\nPATH A:\\\r\n'
DEFAULT_EPOCH = '1749168000'    # 2025-06-06, as image.py


def mtools_env():
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
    env.setdefault('SOURCE_DATE_EPOCH', DEFAULT_EPOCH)
    return env


def release_tree(image, tree, env, config=CONFIG_SYS, autoexec=AUTOEXEC_BAT):
    """Copy the release file set out of the disk image into tree (empty)."""
    with Path(image).open('rb') as disk:
        mbr = disk.read(512)
    if mbr[510:512] != b'\x55\xaa':
        raise SystemExit('image has no MBR')
    start = struct.unpack_from('<I', mbr, 454)[0]
    source = f'{image}@@{start * 512}'
    subprocess.run(['mcopy', '-s', '-m', '-i', source, '::*', str(tree)],
                   env=env, check=True)
    for name in TEST_ONLY:
        (tree / name).unlink(missing_ok=True)
    (tree / 'CONFIG.SYS').write_bytes(config)
    (tree / 'AUTOEXEC.BAT').write_bytes(autoexec)
    fix_times(tree, env)


def fix_times(tree, env):
    """Give generated files and all directories the fixed build date, so the
    FAT entries mcopy -m stores are the same on every build."""
    epoch = int(env['SOURCE_DATE_EPOCH'])
    for path in [tree / 'CONFIG.SYS', tree / 'AUTOEXEC.BAT',
                 *(p for p in tree.rglob('*') if p.is_dir())]:
        if path.exists():
            os.utime(path, (epoch, epoch))
