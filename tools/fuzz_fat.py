#!/usr/bin/env python3
"""Fuzz src/fat.S with corrupt FAT12/16/32 images (host harness under qemu-aarch64).

    fuzz_fat.py fuzz [--seconds N] [--seed S] [--jobs J]
    fuzz_fat.py regress
    fuzz_fat.py run IMAGE [--sector N] [--mode fuzz|fuzzro]

Base images are built with mkfs.fat and mtools (deterministic through
SOURCE_DATE_EPOCH), then mutated: BPB fields, FAT entries, directory
entries, random bytes, truncation, a mismatched device sector size. Each
mutated image is run through `build/fat_host IMAGE SECTOR fuzz|fuzzro`
(tests/fat_host.c), which mounts it, lists the whole tree, reads every file
and, in `fuzz` mode, creates, writes, renames and deletes files and
directories. A finding is a crash (signal), a hang (timeout), a harness
violation (Block I/O outside the driver's guarded memory or the disk, a
write to the boot sector, any write during a `fuzzro` run). Clean errors are
fine. Findings are minimised byte by byte against their base image and saved
to build/fuzz-crashes/fat/ with the seed that found them.

Everything is reproducible from (seed, iteration): each iteration seeds its
own random generator, so `--seed S` replays the same inputs on any machine
(timing only changes how many iterations fit in the time budget).
"""
import argparse
import gzip
import hashlib
import json
import multiprocessing
import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
EPOCH = '1700000000'
TIMEOUT = 5.0
VIOLATIONS = {94: 'overflow', 95: 'bootwrite', 96: 'rowrite', 97: 'oob'}


# ---------------------------------------------------------------------------
# Base images.

def run(cmd, env=None):
    r = subprocess.run(cmd, capture_output=True, env=env)
    if r.returncode:
        raise RuntimeError(f'{cmd[0]} failed: {r.stderr.decode(errors="replace")}')
    return r


def mtools_env():
    return dict(os.environ, MTOOLS_SKIP_CHECK='1', MTOOLS_NO_VFAT='0', LC_ALL='C.UTF-8',
                SOURCE_DATE_EPOCH=EPOCH)


def make_image(path, bits, size, sector, spc, populate=True, label='FUZZ'):
    """A FAT image made by mkfs.fat; populated with files, nested directories,
    long names, a crowded directory and a fragmented file when asked."""
    with open(path, 'wb') as f:
        f.truncate(size)
    env = mtools_env()
    run(['mkfs.fat', '-F', str(bits), '-S', str(sector), '-s', str(spc), '-i', '12345678',
         '-n', label, str(path)], env=env)
    if not populate:
        return
    src = Path(str(path) + '.src')
    src.mkdir(exist_ok=True)

    def put(name, data, dest):
        p = src / name.replace('/', '_')
        p.write_bytes(data)
        os.utime(p, (int(EPOCH), int(EPOCH)))
        run(['mcopy', '-o', '-i', str(path), str(p), '::/' + dest], env=env)

    def md(d):
        run(['mmd', '-i', str(path), '::/' + d], env=env)

    def blob(n, k):
        return bytes(((i * 131 + k * 7) ^ (i >> 5)) & 0xff for i in range(n))

    cl = sector * spc
    put('HELLO.TXT', b'hello\r\n', 'HELLO.TXT')
    put('long', b'long name\r\n', 'A long file name.text')
    for i, n in enumerate([cl, cl * 3, cl * 2, cl * 4]):
        put(f'frag{i}', blob(n, i), f'FRAG{i}.BIN')
    md('Sub Dir')
    md('Sub Dir/Deeper')
    md('Sub Dir/Deeper/Deepest')
    put('inner', blob(cl * 5 + 100, 9), 'Sub Dir/inner.dat')
    put('deep', b'deep\r\n', 'Sub Dir/Deeper/Deepest/leaf.txt')
    md('CROWD')
    for i in range(40):
        put(f'c{i}', b'x' * (i * 37 % 300), f'CROWD/crowded file number {i:02}.txt')
    # Fragment: free FRAG1 and FRAG3, then a file that needs both gaps.
    run(['mdel', '-i', str(path), '::/FRAG1.BIN', '::/FRAG3.BIN'], env=env)
    put('chain', blob(cl * 9 + 33, 5), 'LONGCHN.BIN')
    put('empty', b'', 'EMPTY.TXT')
    shutil.rmtree(src)


BASES = [
    # name, FAT bits, bytes, sector size, sectors per cluster
    ('fat12', 12, 1474560, 512, 1),
    ('fat12-2k', 12, 4 * 1024 * 1024, 2048, 1),
    ('fat16', 16, 8 * 1024 * 1024, 512, 2),
    ('fat16-4k', 16, 24 * 1024 * 1024, 4096, 1),
    ('fat32', 32, 34 * 1024 * 1024, 512, 1),
]


class Geometry:
    """BPB and directory tree of a valid base image."""

    def __init__(self, data):
        le = int.from_bytes
        self.bps = le(data[11:13], 'little')
        self.spc = data[13]
        self.reserved = le(data[14:16], 'little')
        self.nfats = data[16]
        self.root_entries = le(data[17:19], 'little')
        total = le(data[19:21], 'little') or le(data[32:36], 'little')
        fatsz = le(data[22:24], 'little') or le(data[36:40], 'little')
        self.fatsz = fatsz
        self.root_start = self.reserved + self.nfats * fatsz
        root_secs = (self.root_entries * 32 + self.bps - 1) // self.bps
        self.data_start = self.root_start + root_secs
        self.clusters = (total - self.data_start) // self.spc
        self.bits = 12 if self.clusters < 4085 else 16 if self.clusters < 65525 else 32
        self.root_cluster = le(data[44:48], 'little') if self.bits == 32 else 0
        self.cbytes = self.bps * self.spc
        self.data = data
        self.entries = []        # (byte offset, attr, first cluster, size, dir cluster)
        self.dirs = {}           # dir cluster -> chain
        self.chains = {}         # first cluster -> chain
        self.walk(0, 0)

    def fat_get(self, c, data=None):
        data = data or self.data
        base = self.reserved * self.bps
        if self.bits == 12:
            off = base + c + c // 2
            v = data[off] | data[off + 1] << 8
            return (v >> 4) if c & 1 else v & 0xfff
        if self.bits == 16:
            return int.from_bytes(data[base + 2 * c:base + 2 * c + 2], 'little')
        return int.from_bytes(data[base + 4 * c:base + 4 * c + 4], 'little') & 0x0fffffff

    def eoc(self):
        return {12: 0xff8, 16: 0xfff8, 32: 0x0ffffff8}[self.bits]

    def chain(self, c):
        out = []
        while 2 <= c < self.clusters + 2 and c not in out and len(out) < 100000:
            out.append(c)
            c = self.fat_get(c)
        return out

    def lba(self, c):
        return self.data_start + (c - 2) * self.spc

    def dir_slots(self, cluster):
        if cluster == 0 and self.bits != 32:
            start = self.root_start * self.bps
            return [start + 32 * i for i in range(self.root_entries)]
        c = cluster or self.root_cluster
        slots = []
        for k in self.chain(c):
            start = self.lba(k) * self.bps
            slots += [start + 32 * i for i in range(self.cbytes // 32)]
        return slots

    def walk(self, cluster, depth):
        if cluster in self.dirs or depth > 10:
            return
        self.dirs[cluster] = self.chain(cluster or self.root_cluster) if (cluster or self.bits == 32) else []
        for off in self.dir_slots(cluster):
            e = self.data[off:off + 32]
            if e[0] == 0:
                break
            if e[0] == 0xe5 or e[11] & 0x3f == 0x0f or e[11] & 8:
                continue
            first = int.from_bytes(e[26:28], 'little')
            if self.bits == 32:
                first |= int.from_bytes(e[20:22], 'little') << 16
            size = int.from_bytes(e[28:32], 'little')
            self.entries.append((off, e[11], first, size, cluster))
            if first >= 2:
                self.chains[first] = self.chain(first)
            if e[11] & 0x10 and e[0] != ord('.') and first >= 2:
                self.walk(first, depth + 1)

    def lfn_slots(self):
        out = []
        for cluster in self.dirs:
            for off in self.dir_slots(cluster):
                e = self.data[off:off + 32]
                if e[0] == 0:
                    break
                if e[0] != 0xe5 and e[11] & 0x3f == 0x0f:
                    out.append(off)
        return out


# ---------------------------------------------------------------------------
# Mutations. Each returns a short description; the image is a bytearray.

def put(data, off, size, value):
    if 0 <= off and off + size <= len(data):
        data[off:off + size] = (value & ((1 << (8 * size)) - 1)).to_bytes(size, 'little')


def fat_set(g, data, c, v, copies):
    for k in range(copies):
        base = (g.reserved + k * g.fatsz) * g.bps
        if g.bits == 12:
            off = base + c + c // 2
            if off + 1 >= len(data):
                continue
            old = data[off] | data[off + 1] << 8
            v12 = v & 0xfff
            new = (old & 0xf) | (v12 << 4) if c & 1 else (old & 0xf000) | v12
            data[off] = new & 0xff
            data[off + 1] = new >> 8
        elif g.bits == 16:
            put(data, base + 2 * c, 2, v)
        else:
            put(data, base + 4 * c, 4, v)


def interesting_cluster(rng, g, near=None):
    top = g.clusters + 2
    choices = [0, 1, 2, top - 1, top, top + 1, g.eoc() - 1, g.eoc(), g.eoc() - 9,
               (1 << g.bits) - 1, rng.randrange(1 << min(g.bits, 28)), rng.randrange(2, top)]
    if g.bits == 32:
        choices += [0x0ffffff7, 0xffffffff, 0x10000000 | rng.randrange(2, top)]
    used = list(g.chains) + [c for c in g.dirs if c]
    if used:
        choices += [rng.choice(used)] * 4
    if near is not None:
        choices += [near] * 3
    return rng.choice(choices)


def mut_bpb(rng, g, data):
    field = rng.choice(['bps', 'spc', 'reserved', 'nfats', 'root', 'total16', 'total32', 'fatsz16',
                        'fatsz32', 'rootclus', 'fsinfo', 'sig', 'media'])
    if field == 'bps':
        put(data, 11, 2, rng.choice([0, 1, 128, 256, 511, 513, 1024, 2048, 4096, 8192, 0xffff]))
    elif field == 'spc':
        data[13] = rng.choice([0, 1, 2, 3, 5, 6, 7, 12, 64, 128, 255])
    elif field == 'reserved':
        put(data, 14, 2, rng.choice([0, 1, g.reserved - 1, g.reserved + 1, g.root_start, 0x7fff, 0xffff]))
    elif field == 'nfats':
        data[16] = rng.choice([0, 1, 3, 4, 16, 128, 255])
    elif field == 'root':
        put(data, 17, 2, rng.choice([0, 1, 15, 16, 17, 512, 4096, 0x8000, 0xffff]))
    elif field in ('total16', 'total32'):
        v = rng.choice([0, 1, g.data_start - 1, g.data_start, g.data_start + 1, g.data_start + g.spc,
                        g.data_start + 4084 * g.spc, g.data_start + 4085 * g.spc,
                        g.data_start + 65524 * g.spc, g.data_start + 65525 * g.spc,
                        0xffff, 0xffffffff, rng.randrange(1 << 32)])
        if field == 'total16':
            put(data, 19, 2, v)
        else:
            put(data, 32, 4, v)
            if rng.random() < 0.5:
                put(data, 19, 2, 0)
    elif field == 'fatsz16':
        put(data, 22, 2, rng.choice([0, 1, 2, g.fatsz - 1, g.fatsz + 1, 0xffff]))
    elif field == 'fatsz32':
        put(data, 36, 4, rng.choice([0, 1, g.fatsz - 1, g.fatsz + 1, 0xffffff, 0xffffffff]))
    elif field == 'rootclus':
        put(data, 44, 4, interesting_cluster(rng, g))
    elif field == 'fsinfo':
        put(data, 48, 2, rng.choice([0, 1, 2, 6, g.reserved - 1, g.reserved, 0xffff]))
        if rng.random() < 0.5:     # a garbage next-free hint
            put(data, g.bps + 492, 4, interesting_cluster(rng, g))
    elif field == 'sig':
        data[510] = rng.choice([0, 0x55, 0xaa])
    else:
        data[21] = rng.randrange(256)
    return f'bpb:{field}'


def mut_fat(rng, g, data):
    chains = [c for c in g.chains.values() if c] + [c for c in g.dirs.values() if c]
    copies = g.nfats if rng.random() < 0.7 else 1
    kind = rng.choice(['loop', 'self', 'cross', 'value', 'value', 'freefirst', 'random'])
    if kind == 'random' or not chains:
        c = rng.randrange(2, g.clusters + 2)
        fat_set(g, data, c, interesting_cluster(rng, g), copies)
        return f'fat:random:{c}'
    ch = rng.choice(chains)
    i = rng.randrange(len(ch))
    if kind == 'loop':
        fat_set(g, data, ch[i], ch[rng.randrange(i + 1)], copies)
    elif kind == 'self':
        fat_set(g, data, ch[i], ch[i], copies)
    elif kind == 'cross':
        other = rng.choice(chains)
        fat_set(g, data, ch[i], rng.choice(other), copies)
    elif kind == 'freefirst':
        fat_set(g, data, ch[i], 0, copies)
    else:
        fat_set(g, data, ch[i], interesting_cluster(rng, g), copies)
    return f'fat:{kind}:{ch[i]}'


def mut_dirent(rng, g, data):
    if not g.entries:
        return mut_bytes(rng, g, data)
    off, attr, first, size, parent = rng.choice(g.entries)
    kind = rng.choice(['cluster', 'cluster', 'size', 'attr', 'name0', 'name', 'dotloop', 'selfdir',
                       'lfn', 'zero'])
    if kind == 'cluster':
        v = interesting_cluster(rng, g, near=parent or g.root_cluster)
        put(data, off + 26, 2, v)
        if g.bits == 32 or rng.random() < 0.2:
            put(data, off + 20, 2, v >> 16)
    elif kind == 'size':
        put(data, off + 28, 4, rng.choice([0, 1, size + 1, size * 2 + g.cbytes * 50, 0x7fffffff,
                                           0xffffffff, 0xfffffe00, rng.randrange(1 << 32)]))
    elif kind == 'attr':
        data[off + 11] = rng.choice([attr ^ 0x10, 0x0f, 0x08, 0x18, 0x3f, 0xff, 0x10, 0x01,
                                     rng.randrange(256)])
    elif kind == 'name0':
        data[off] = rng.choice([0, 0xe5, 0x05, ord('.'), 0x20, 0xff])
    elif kind == 'name':
        for _ in range(rng.randrange(1, 4)):
            data[off + rng.randrange(11)] = rng.choice([0, 1, 0x1f, 0x7f, 0x80, 0xff, ord('\\'),
                                                        ord('/'), ord('.'), ord(' '), ord('*')])
    elif kind in ('dotloop', 'selfdir'):
        dirs = [e for e in g.entries if e[1] & 0x10 and e[2] >= 2]
        if not dirs:
            return 'dirent:none'
        doff, _, dfirst, _, dparent = rng.choice(dirs)
        target_off = doff
        if kind == 'dotloop':      # a "." or ".." entry naming the wrong place
            slots = g.dir_slots(dfirst)
            target_off = slots[rng.randrange(2)] if len(slots) >= 2 else doff
            v = rng.choice([dfirst, 0, g.root_cluster, dparent, rng.choice(list(g.dirs) or [0])])
        else:                      # a directory entry naming its own parent
            v = dparent or g.root_cluster
        put(data, target_off + 26, 2, v)
        put(data, target_off + 20, 2, v >> 16 if g.bits == 32 else 0)
        return f'dirent:{kind}:{target_off}'
    elif kind == 'lfn':
        lfns = g.lfn_slots()
        if lfns:
            lo = rng.choice(lfns)
            which = rng.choice([0, 13, 11, rng.randrange(32)])
            data[lo + which] = rng.choice([0, 0x40, 0x41, 0x54, 0x55, 0x7f, 0xff, rng.randrange(256)])
            return f'dirent:lfn:{lo}+{which}'
    else:
        data[off:off + 32] = bytes(32)
    return f'dirent:{kind}:{off}'


def mut_bytes(rng, g, data):
    meta_end = min(len(data), (g.data_start + g.spc * 64) * g.bps)
    n = rng.choice([1, 1, 2, 4, 8, 32])
    for _ in range(n):
        if rng.random() < 0.8:
            off = rng.randrange(meta_end)
        else:
            off = rng.randrange(len(data))
        if rng.random() < 0.5:
            data[off] ^= 1 << rng.randrange(8)
        else:
            data[off] = rng.choice([0, 0xff, 0x80, 0x7f, rng.randrange(256)])
    return f'bytes:{n}'


def mutate(rng, g, base):
    data = bytearray(base)
    desc = []
    for _ in range(rng.choice([1, 1, 2, 2, 3, 4, 6])):
        m = rng.choices([mut_bpb, mut_fat, mut_dirent, mut_bytes], weights=[2, 4, 4, 2])[0]
        desc.append(m(rng, g, data))
    if rng.random() < 0.08:
        cut = rng.choice([rng.randrange(len(data)), g.data_start * g.bps + rng.randrange(-3, 4) * g.bps,
                          rng.randrange(0, 4096), len(data) - g.bps, len(data) - 1])
        del data[max(cut, 0):]
        desc.append(f'truncate:{len(data)}')
    sector = g.bps
    if rng.random() < 0.05:
        sector = rng.choice([512, 1024, 2048, 4096])
        desc.append(f'sector:{sector}')
    mode = 'fuzzro' if rng.random() < 0.35 else 'fuzz'
    return bytes(data), sector, mode, desc


# ---------------------------------------------------------------------------
# Running the harness.

def execute(host, qemu, image_path, sector, mode, timeout=TIMEOUT):
    """Returns (kind or None, output). kind: crash, hang, oob, rowrite, ..."""
    try:
        r = subprocess.run([qemu, str(host), str(image_path), str(sector), mode],
                           capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b'') + (e.stderr or b'')
        return 'hang', out.decode(errors='replace')
    out = (r.stdout + r.stderr).decode(errors='replace')
    if r.returncode < 0 or 'uncaught target signal' in out:
        return 'crash', out
    if r.returncode in VIOLATIONS:
        return VIOLATIONS[r.returncode], out
    if r.returncode != 0:
        return 'error', out
    return None, out


class Runner:
    def __init__(self, host, qemu, work):
        self.host, self.qemu = host, qemu
        self.path = Path(work) / f'img-{os.getpid()}.img'

    def __call__(self, data, sector, mode, timeout=TIMEOUT):
        self.path.write_bytes(data)
        return execute(self.host, self.qemu, self.path, sector, mode, timeout)


def minimise(runner, base, data, sector, mode, kind, budget=150):
    """Byte-level reduction toward the base image: undo truncation, then undo
    differing runs of bytes (halving chunks), keeping the same finding."""
    tests = [0]
    timeout = TIMEOUT

    def still(candidate):
        if tests[0] >= budget:
            return False
        tests[0] += 1
        return runner(bytes(candidate), sector, mode, timeout)[0] == kind

    cur = bytearray(data)
    if len(cur) < len(base):
        trial = cur + base[len(cur):]
        if still(trial):
            cur = trial
    if len(cur) != len(base):
        return bytes(cur), tests[0]
    diff = [off + k for off, hx in fast_diff(base, cur) for k in range(len(hx) // 2)]
    chunk = max(1, len(diff) // 2)
    while diff and chunk >= 1 and tests[0] < budget:
        i = 0
        progress = False
        while i < len(diff) and tests[0] < budget:
            part = diff[i:i + chunk]
            trial = bytearray(cur)
            for p in part:
                trial[p] = base[p]
            if still(trial):
                cur = trial
                diff = diff[:i] + diff[i + chunk:]
                progress = True
            else:
                i += chunk
        if chunk == 1 and not progress:
            break
        chunk = max(1, chunk // 2) if chunk > 1 else 1
    return bytes(cur), tests[0]


def fast_diff(base, data):
    """[(offset, hex bytes)] runs where data differs from base (same length)."""
    runs, i, n = [], 0, min(len(base), len(data))
    # Compare in blocks for speed.
    while i < n:
        j = min(n, i + 65536)
        if base[i:j] == data[i:j]:
            i = j
            continue
        while i < j:
            if base[i] != data[i]:
                k = i
                while k < n and base[k] != data[k]:
                    k += 1
                runs.append((i, data[i:k].hex()))
                i = k
            else:
                i += 1
    return runs


# ---------------------------------------------------------------------------
# Fuzz loop.

_W = {}


def worker_init(host, qemu, work, bases):
    _W['runner'] = Runner(host, qemu, work)
    _W['bases'] = {}
    for name, path in bases.items():
        data = Path(path).read_bytes()
        _W['bases'][name] = (data, Geometry(data))


def one_iteration(args):
    seed, it = args
    rng = random.Random(f'{seed}:{it}')
    name = rng.choice(sorted(_W['bases']))
    base, g = _W['bases'][name]
    data, sector, mode, desc = mutate(rng, g, base)
    t0 = time.time()
    kind, out = _W['runner'](data, sector, mode)
    elapsed = time.time() - t0
    if kind in (None, 'error'):
        return it, name, None, desc, elapsed, None
    # Confirm (hangs can be load) and minimise in the worker.
    kind2, out = _W['runner'](data, sector, mode, TIMEOUT * (2 if kind == 'hang' else 1))
    if kind2 != kind:
        return it, name, None, desc + [f'flaky:{kind}'], elapsed, None
    small, tests = minimise(_W['runner'], base, data, sector, mode, kind)
    kind3, out = _W['runner'](small, sector, mode)
    return it, name, kind, desc, elapsed, dict(image=small, sector=sector, mode=mode, output=out[-3000:],
                                               tests=tests, confirmed=kind3 == kind)


def build_bases(work):
    paths = {}
    for name, bits, size, sector, spc in BASES:
        p = Path(work) / f'base-{name}.img'
        if not p.exists():
            make_image(p, bits, size, sector, spc)
        g = Geometry(p.read_bytes())
        assert g.bits == bits, (name, g.bits)
        paths[name] = str(p)
    return paths


def save_finding(outdir, seed, it, name, kind, desc, base, f):
    diff = fast_diff(base, f['image']) if len(f['image']) == len(base) else None
    key = hashlib.sha1(json.dumps([kind, name, diff, len(f['image'])]).encode()).hexdigest()[:10]
    d = Path(outdir) / f'{kind}-{name}-{key}'
    if d.exists():
        return d, False
    d.mkdir(parents=True)
    with gzip.open(d / 'image.img.gz', 'wb') as z:
        z.write(f['image'])
    info = dict(kind=kind, base=name, seed=seed, iteration=it, sector=f['sector'], mode=f['mode'],
                mutations=desc, length=len(f['image']), base_length=len(base), diff=diff,
                confirmed=f['confirmed'], minimise_tests=f['tests'],
                replay=f'tools/fuzz_fat.py replay {d}', output=f['output'])
    (d / 'info.json').write_text(json.dumps(info, indent=1))
    return d, True


def fuzz(args):
    host, qemu = Path(args.host).resolve(), args.qemu
    work = Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    bases = build_bases(work)
    base_data = {n: Path(p).read_bytes() for n, p in bases.items()}
    outdir = Path(args.out)
    deadline = time.time() + args.seconds
    print(f'fuzz-fat: seed {args.seed}, {args.seconds}s, {args.jobs} jobs, bases {", ".join(bases)}',
          flush=True)
    counts = {}
    found = 0
    it = args.start
    slow = 0
    tmp = tempfile.mkdtemp(prefix='fuzzfat-', dir=work)
    with multiprocessing.Pool(args.jobs, worker_init, (host, qemu, tmp, bases)) as pool:
        pending = []
        while time.time() < deadline or pending:
            while time.time() < deadline and len(pending) < args.jobs * 2:
                pending.append(pool.apply_async(one_iteration, ((args.seed, it),)))
                it += 1
            pending[0].wait()
            r = pending.pop(0).get()
            i, name, kind, desc, elapsed, f = r
            if elapsed > TIMEOUT / 2 and not kind:
                slow += 1
            counts[name] = counts.get(name, 0) + 1
            if kind:
                d, new = save_finding(outdir, args.seed, i, name, kind, desc, base_data[name], f)
                if new:
                    found += 1
                    print(f'FINDING {kind} on {name} (seed {args.seed} iteration {i}, {" ".join(desc)})'
                          f' -> {d}', flush=True)
    shutil.rmtree(tmp, ignore_errors=True)
    total = sum(counts.values())
    print(f'fuzz-fat: {total} runs ({", ".join(f"{k} {v}" for k, v in sorted(counts.items()))}), '
          f'{slow} slow, {found} new findings, next iteration {it}')
    return 1 if found else 0


# ---------------------------------------------------------------------------
# Regression corpus: one generator per bug the fuzzer found. Each builds a
# small image from scratch and applies the corruption by meaning, not bytes.

def regress_cases():
    """(name, base config, patch(data, geometry), sector, mode)."""
    cases = []

    def case(name, base, mode='fuzz'):
        def wrap(fn):
            cases.append((name, base, fn, mode))
            return fn
        return wrap

    small12 = ('fat12', 12, 1474560, 512, 1)
    small16 = ('fat16', 16, 8 * 1024 * 1024, 512, 2)
    small32 = ('fat32', 32, 34 * 1024 * 1024, 512, 1)

    def entry(g, name83):
        for off, *_ in g.entries:
            if bytes(g.data[off:off + 11]) == name83:
                return off
        raise KeyError(name83)

    def first_cluster(g, off):
        return int.from_bytes(g.data[off + 26:off + 28], 'little') | (
            int.from_bytes(g.data[off + 20:off + 22], 'little') << 16 if g.bits == 32 else 0)

    # Directory chains that loop back on themselves: listing, lookups and
    # creates each walked the chain from its start for every entry index, up
    # to 65536 entries, which took minutes (a hang) per directory scan.
    @case('dir-chain-loop-fat16', small16)
    def _(data, g):
        c = first_cluster(g, entry(g, b'CROWD      '))
        fat_set(g, data, g.chain(c)[-1], c, g.nfats)

    @case('dir-chain-loop-fat32-root', small32, 'fuzzro')
    def _(data, g):
        fat_set(g, data, g.root_cluster, g.root_cluster, g.nfats)

    @case('dir-chain-loop-fat12-sub', small12)
    def _(data, g):
        c = first_cluster(g, entry(g, b'SUBDIR~1   '))
        fat_set(g, data, c, c, g.nfats)

    # Sanity cases kept from the fuzzer's mutation classes.
    @case('dot-names-root-fat32', small32)
    def _(data, g):
        c = first_cluster(g, entry(g, b'SUBDIR~1   '))
        dot = g.dir_slots(c)[0]
        put(data, dot + 26, 2, g.root_cluster)
        put(data, dot + 20, 2, g.root_cluster >> 16)

    @case('file-huge-size-loop-fat16', small16, 'fuzzro')
    def _(data, g):
        off = entry(g, b'LONGCHN BIN')
        put(data, off + 28, 4, 0xffffffff)
        ch = g.chain(first_cluster(g, off))
        fat_set(g, data, ch[-1], ch[0], g.nfats)

    return cases


def regress(args):
    host, qemu = Path(args.host).resolve(), args.qemu
    failures = 0
    with tempfile.TemporaryDirectory(prefix='fuzz-fat-regress-') as tmp:
        built = {}
        cases = regress_cases()
        for name, base, patch, mode in cases:
            if base[0] not in built:
                p = Path(tmp) / f'{base[0]}.img'
                make_image(p, *base[1:])
                built[base[0]] = p.read_bytes()
            data = bytearray(built[base[0]])
            g = Geometry(bytes(data))
            patch(data, g)
            img = Path(tmp) / f'{name}.img'
            img.write_bytes(data)
            for m in sorted({mode, 'fuzzro', 'fuzz'}):
                kind, out = execute(host, qemu, img, g.bps, m)
                if kind and kind != 'error':
                    failures += 1
                    print(f'FAIL: {name} ({m}): {kind}\n{out[-2000:]}')
                elif kind == 'error':
                    failures += 1
                    print(f'FAIL: {name} ({m}): harness error\n{out[-2000:]}')
            print(f'PASS: {name}' if not failures else f'...: {name}', flush=True)
    if failures:
        print(f'fuzz-fat-regress: {failures} failures')
        return 1
    print(f'PASS: fuzz-fat regression corpus, {len(cases)} cases, no crash/hang/violation.')
    return 0


def replay(args):
    d = Path(args.finding)
    info = json.loads((d / 'info.json').read_text())
    with gzip.open(d / 'image.img.gz') as z:
        data = z.read()
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / 'x.img'
        p.write_bytes(data)
        kind, out = execute(Path(args.host).resolve(), args.qemu, p, info['sector'], info['mode'])
    print(out[-3000:])
    print(f'replay: {kind or "clean"} (recorded {info["kind"]})')
    return 1 if kind and kind != 'error' else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default=str(ROOT / 'build' / 'fat_host'))
    ap.add_argument('--qemu', default='qemu-aarch64')
    sub = ap.add_subparsers(dest='cmd', required=True)
    f = sub.add_parser('fuzz')
    f.add_argument('--seconds', type=float, default=float(os.environ.get('FUZZ_SECONDS') or 60))
    f.add_argument('--seed', default=os.environ.get('FUZZ_SEED') or '1')
    f.add_argument('--start', type=int, default=0, help='first iteration number')
    f.add_argument('--jobs', type=int, default=int(os.environ.get('FUZZ_JOBS') or os.cpu_count() or 2))
    f.add_argument('--work', default=str(ROOT / 'build' / 'fuzz-fat-work'))
    f.add_argument('--out', default=str(ROOT / 'build' / 'fuzz-crashes' / 'fat'))
    sub.add_parser('regress')
    r = sub.add_parser('replay')
    r.add_argument('finding')
    args = ap.parse_args()
    sys.exit({'fuzz': fuzz, 'regress': regress, 'replay': replay}[args.cmd](args))


if __name__ == '__main__':
    main()
