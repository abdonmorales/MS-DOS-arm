#!/usr/bin/env python3
"""Stress src/fat.S on FAT12/16/32 images and cross-check with dosfstools/mtools.

The driver runs as a Linux AArch64 program under qemu-aarch64 (see
tests/fat_host.c). Images are prepared with mkfs.fat and mtools, modified by
the native driver, then checked with `fsck.fat -n` and read back with mtools.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

CONFIGS = [
    # name, FAT bits, MiB, sector size, sectors per cluster
    ('fat12', 12, 4, 512, 4),
    ('fat16', 16, 32, 512, 4),
    ('fat16-4k-sectors', 16, 64, 4096, 1),
    ('fat32', 32, 64, 512, 1),
    ('fat32-4k-clusters', 32, 320, 512, 8),
]


def pattern(seed, i):
    return ((i * 131 + seed * 7 + (i >> 9)) ^ (i >> 3)) & 0xff


def expected_big():
    data = bytearray(pattern(1, i) for i in range(90000))
    data[70001:90000] = bytes(90000 - 70001)
    return bytes(data)


def run(cmd, env=None, check=True):
    result = subprocess.run(cmd, capture_output=True, text=True, errors='replace', env=env)
    if check and result.returncode:
        raise RuntimeError(f'{cmd[0]} failed ({result.returncode}):\n'
                           f'{result.stdout}{result.stderr}')
    return result


def mtools(env, *args, binary=False):
    result = subprocess.run(list(args), capture_output=True, env=env)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stderr.decode(errors="replace")}')
    return result.stdout if binary else result.stdout.decode(errors='replace')


def fsck(image):
    # fsck.fat reads the logical sector size from the boot sector itself.
    result = run(['fsck.fat', '-n', '-v', str(image)], check=False)
    text = result.stdout + result.stderr
    if result.returncode != 0:
        raise RuntimeError('fsck.fat reported problems:\n' + text)
    return text


def check_config(host, qemu, work, name, bits, mib, sector, spc):
    image = work / f'{name}.img'
    with image.open('wb') as f:
        f.truncate(mib * 1024 * 1024)
    run(['mkfs.fat', '-F', str(bits), '-S', str(sector), '-s', str(spc),
         '-n', 'ARMTEST', str(image)])
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1', MTOOLS_NO_VFAT='0', LC_ALL='C.UTF-8')
    src = work / f'{name}-src'
    src.mkdir()
    files = {'UPPER.TXT': b'upper\r\n', 'Hello.txt': b'hello\r\n',
             'A long file name.text': b'long\r\n',
             'Caf\u2603 menu.txt': b'non-ascii\r\n'}   # phase1 deletes it by its alias
    for filename, data in files.items():
        (src / filename).write_bytes(data)
        mtools(env, 'mcopy', '-i', str(image), str(src / filename), '::/' + filename)
    mtools(env, 'mmd', '-i', str(image), '::/Sub Dir')
    inner = bytes(pattern(3, i) for i in range(100000))
    (src / 'inner.dat').write_bytes(inner)
    mtools(env, 'mcopy', '-i', str(image), str(src / 'inner.dat'), '::/Sub Dir/inner.dat')
    fsck(image)

    for phase in ['phase1', 'phase2']:
        result = run([qemu, str(host), str(image), str(sector), phase], check=False)
        if result.returncode:
            raise RuntimeError(f'{name} {phase}:\n{result.stdout}{result.stderr}')
        fsck(image)

    # Independent read-back of what the native driver wrote.
    big = mtools(env, 'mtype', '-i', str(image), '::/BIG.BIN', binary=True)
    if big != expected_big():
        raise RuntimeError(f'{name}: BIG.BIN differs when read by mtools')
    if mtools(env, 'mtype', '-i', str(image), '::/Sub Dir/inner.dat', binary=True) != inner:
        raise RuntimeError(f'{name}: pre-existing file damaged')
    for path, data in [('::/New Dir/renamed zero.TXT', b'content 0\r\n'),
                       ('::/New Dir/file number 149.txt', b'content 149\r\n'),
                       ('::/New Dir/after delete with a long name.txt', b'after'),
                       ('::/Sub Dir/moved.txt', b'content 1\r\n'),
                       ('::/Child Moved/leaf.txt', b'leaf'),
                       ('::/upper.txt', b'upper\r\n'),
                       ('::/lower.txt', b'lc')]:
        got = mtools(env, 'mtype', '-i', str(image), path, binary=True)
        if got != data:
            raise RuntimeError(f'{name}: {path} read {got!r}')
    listing = mtools(env, 'mdir', '-i', str(image), '-b', '::/New Dir')
    count = len([line for line in listing.splitlines() if line.strip()])
    if count != 100:
        raise RuntimeError(f'{name}: mtools sees {count} entries in New Dir')
    root = mtools(env, 'mdir', '-i', str(image), '-b', '::/')
    if 'Caf' in root:
        raise RuntimeError(f'{name}: deleted non-ASCII long name still listed:\n{root}')
    for expected in ['lower.txt', 'MiXed.TXT', 'upper.txt', 'Child Moved']:
        if '/' + expected not in root:
            raise RuntimeError(f'{name}: {expected!r} missing from mtools listing:\n{root}')
    attrib = mtools(env, 'mattrib', '-i', str(image), '::/lower.txt')
    if 'R' not in attrib.split('::')[0]:
        raise RuntimeError(f'{name}: read-only attribute not visible to mtools')
    return f'{name}: FAT{bits}, {sector}-byte sectors, {sector * spc}-byte clusters'


def corrupt_image(work, name, patch):
    """A small FAT16 image holding KEEP.TXT, BAD.TXT and BADDIR, then patched."""
    image = work / f'{name}.img'
    with image.open('wb') as f:
        f.truncate(8 * 1024 * 1024)
    run(['mkfs.fat', '-F', '16', '-S', '512', '-s', '1', '-n', 'CORRUPT', str(image)])
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
    src = work / f'{name}-src'
    src.mkdir()
    for filename, data in [('KEEP.TXT', b'keep\r\n'), ('BAD.TXT', bytes(10000))]:
        (src / filename).write_bytes(data)
        mtools(env, 'mcopy', '-i', str(image), str(src / filename), '::/' + filename)
    mtools(env, 'mmd', '-i', str(image), '::/BADDIR')
    data = bytearray(image.read_bytes())
    reserved = int.from_bytes(data[14:16], 'little')
    fats, fat_size = data[16], int.from_bytes(data[22:24], 'little')
    root = (reserved + fats * fat_size) * 512
    entries = {bytes(data[root + i:root + i + 11]): root + i for i in range(0, 512 * 32, 32)}
    patch(data, entries)
    image.write_bytes(data)
    return image


def check_corrupt(host, qemu, work):
    """Metadata that would steer writes outside the FAT or the volume."""
    def short_fat(data, entries):
        # Claim a 30 MiB volume (about 61,000 clusters, still FAT16) while
        # the FATs stay sized for 8 MiB (about 16,000 entries).
        data.extend(bytes(30 * 1024 * 1024 - len(data)))
        data[19:21] = bytes(2)
        data[32:36] = (30 * 2048).to_bytes(4, 'little')

    def bad_cluster(data, entries):
        bad = entries[b'BAD     TXT']
        data[bad + 26:bad + 28] = (0xfff0).to_bytes(2, 'little')   # past the volume
        baddir = entries[b'BADDIR     ']
        data[baddir + 26:baddir + 28] = (1).to_bytes(2, 'little')  # reserved cluster

    for phase, patch in [('shortfat', short_fat), ('badcluster', bad_cluster)]:
        image = corrupt_image(work, phase, patch)
        before = image.read_bytes()
        result = run([qemu, str(host), str(image), '512', phase], check=False)
        if result.returncode:
            raise RuntimeError(f'{phase}:\n{result.stdout}{result.stderr}')
        if phase == 'badcluster' and image.read_bytes() != before:
            raise RuntimeError('badcluster: the driver wrote to a volume it should refuse')
    return 'corrupt metadata: short FAT and out-of-range clusters are contained'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', type=Path, default=Path('build/fat_host'))
    parser.add_argument('--qemu', default='qemu-aarch64')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='fat-test-') as directory:
        for config in CONFIGS:
            print('PASS:', check_config(args.host.resolve(), args.qemu, Path(directory), *config))
        print('PASS:', check_corrupt(args.host.resolve(), args.qemu, Path(directory)))
    print('PASS: native FAT driver host tests, fsck.fat clean, mtools read-back matches.')


if __name__ == '__main__':
    main()
