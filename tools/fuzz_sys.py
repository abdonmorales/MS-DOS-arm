#!/usr/bin/env python3
"""System fuzzer: ARM BASIC programs, PE32+ loader input, COMMAND lines.

Three surfaces, each seeded and time-bounded:

  exe    malformed .EXE images fed to the kernel's pe_load (the EXEC/4Bh
         loader) under Unicorn, with the file, allocator and copy routines
         stubbed in Python. Every heap block is mapped on its own, exactly
         as large as dos_allocate makes it, at an address that is never
         reused, so any out-of-block access, use after free, double free,
         leak or hang is caught precisely.
  basic  generated and mutated BASIC programs, many per QEMU boot: each is
         LOADed and RUN by BASIC.EXE; a CPU exception, a hang in a program
         with no backward jumps, or an interpreter that stops answering is
         a finding.
  cmd    long and odd COMMAND.COM lines typed at the prompt, plus batch
         files with control bytes, %vars, quoting, pipes and redirection,
         many per boot; a CPU exception or a shell that stops answering is
         a finding.

Failing inputs go to build/fuzz-crashes/<surface>/ with a .txt note that
names the reproducer command (--replay FILE).
"""
import argparse
import os
import random
import re
import selectors
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SOURCE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SOURCE / 'tools'))


# ---------------------------------------------------------------------------
# Findings

class Findings:
    def __init__(self, build, seed):
        self.root = build / 'fuzz-crashes'
        self.seed = seed
        self.count = 0
        self.kinds = set()

    def save(self, surface, kind, data, note, suffix):
        directory = self.root / surface
        directory.mkdir(parents=True, exist_ok=True)
        stem = f'{kind}-{self.seed}-{self.count:04d}'
        self.count += 1
        path = directory / (stem + suffix)
        path.write_bytes(data)
        (directory / (stem + '.txt')).write_text(
            f'surface: {surface}\nkind: {kind}\nseed: {self.seed}\n'
            f'reproduce: python3 tools/fuzz_sys.py --replay {path}\n\n{note}\n')
        self.kinds.add((surface, kind))
        print(f'FINDING {surface}/{kind}: {path}', flush=True)
        return path


# ---------------------------------------------------------------------------
# EXE: pe_load under Unicorn

HEAP_BASE = 0x1_0000_0000
ARENA_LIMIT = 0x1000000         # dos_allocate refuses larger requests
ARENA_SLOTS = 64
INFO_BUFFER = 0x3E0000          # stub EFI_FILE_INFO; size at +8


class LoaderHarness:
    STUBS = ['dos_open', 'file_handle', 'get_file_info', 'dos_allocate', 'dos_read',
             'dos_close', 'dos_free', 'fat_memcpy', 'fat_zero_bytes', 'plat_sync_code']

    def __init__(self, build, nm):
        from unit import Kernel
        from unicorn import UC_HOOK_CODE, UC_HOOK_MEM_WRITE
        from unicorn.arm64_const import UC_ARM64_REG_X0, UC_ARM64_REG_LR, UC_ARM64_REG_PC
        self.X0, self.LR, self.PC = UC_ARM64_REG_X0, UC_ARM64_REG_LR, UC_ARM64_REG_PC
        self.kernel = Kernel(build, nm)
        self.cpu = self.kernel.cpu
        self.next_address = HEAP_BASE
        for name in self.STUBS:
            address = self.kernel.address(name)
            self.cpu.hook_add(UC_HOOK_CODE, self._stub, user_data=name,
                              begin=address, end=address)
        # pe_load itself writes only its stack frame and heap blocks.
        stack_low = 0x380000
        self.cpu.hook_add(UC_HOOK_MEM_WRITE, self._low_write, begin=0, end=stack_low - 1)

    def _low_write(self, cpu, access, address, size, value, data):
        self.problems.append(f'write of {size} bytes to kernel memory {address:#x}')
        cpu.emu_stop()

    def reg(self, n):
        return self.cpu.reg_read(self.X0 + n)

    def ret(self, *values):
        for index, value in enumerate(values):
            self.cpu.reg_write(self.X0 + index, value & 0xffffffffffffffff)
        self.cpu.reg_write(self.PC, self.cpu.reg_read(self.LR))

    def allocate(self, size):
        rounded = (size + 0xffff) & ~0xffff
        base = self.next_address
        self.next_address += rounded + 0x100000     # unmapped guard after each block
        self.cpu.mem_map(base, rounded)
        self.blocks[base] = rounded
        return base

    def checked(self, address, length, what):
        """True when [address, address+length) lies in mapped memory we own."""
        if length == 0:
            return True
        end = address + length
        if 0x380000 <= address and end <= 0x3F0000:
            return True
        for base, size in self.blocks.items():
            if base <= address and end <= base + size:
                return True
        self.problems.append(f'{what} of {length:#x} bytes at {address:#x} is outside '
                             f'every live block')
        self.cpu.emu_stop()
        return False

    def _stub(self, cpu, address, size, name):
        x0, x1, x2 = self.reg(0), self.reg(1), self.reg(2)
        if name == 'dos_open':
            self.opened += 1
            self.ret(5, 0)
        elif name == 'file_handle':
            self.ret(0x5000)
        elif name == 'get_file_info':
            cpu.mem_write(INFO_BUFFER, bytes(8) + struct.pack('<Q', len(self.data)))
            self.ret(0, INFO_BUFFER)
        elif name == 'dos_allocate':
            if x0 == 0 or x0 > ARENA_LIMIT or len(self.live) >= ARENA_SLOTS:
                self.ret(8, 1)
            else:
                base = self.allocate(x0)
                self.live.add(base)
                self.ret(base, 0)
        elif name == 'dos_free':
            if x0 not in self.live:
                self.problems.append(f'free of {x0:#x}, not a live block')
                cpu.emu_stop()
                return
            self.live.discard(x0)
            cpu.mem_unmap(x0, self.blocks.pop(x0))
            self.ret(0, 0)
        elif name == 'dos_read':
            if self.closed:
                self.problems.append('read after close')
            remaining = len(self.data) - self.position
            count = min(x2, remaining, self.read_chunk)
            if self.checked(x1, count, 'dos_read'):
                cpu.mem_write(x1, self.data[self.position:self.position + count])
                self.position += count
                self.ret(count, 0)
        elif name == 'dos_close':
            self.closed += 1
            self.ret(0, 0)
        elif name == 'fat_memcpy':
            if self.checked(x0, x2, 'memcpy destination') and \
                    self.checked(x1, x2, 'memcpy source'):
                if x2:
                    cpu.mem_write(x0, bytes(cpu.mem_read(x1, x2)))
                self.ret(x0)
        elif name == 'fat_zero_bytes':
            if self.checked(x0, x1, 'zero'):
                if x1:
                    cpu.mem_write(x0, bytes(x1))
                self.ret(x0)
        elif name == 'plat_sync_code':
            self.checked(x0, x1, 'sync_code')
            self.ret(x0)

    def load(self, data, mode=1, read_chunk=1 << 30, overlay=0):
        """Run pe_load; return a list of problems (empty: handled correctly)."""
        self.data, self.position, self.read_chunk = data, 0, read_chunk
        self.blocks, self.live, self.problems = {}, set(), []
        self.opened = self.closed = 0
        destination = capacity = 0
        if mode == 3:
            capacity = overlay
            destination = self.allocate(capacity)
        path, = self.kernel.strings(b'FUZZ.EXE')
        try:
            x0, x1, x2, x3 = self.kernel.call('pe_load', path, destination, capacity,
                                              results=4)
        except RuntimeError as error:
            self.problems.append(str(error))
            x0 = x1 = x2 = x3 = None
        self.kernel.timed_out = False
        if not self.problems and x1 is not None:
            if self.closed != 1:
                self.problems.append(f'file closed {self.closed} times')
            if x1 == 0:
                image = destination if mode == 3 else x0
                expected_live = set() if mode == 3 else {image}
                if self.live != expected_live:
                    self.problems.append(f'leaked blocks on success: {sorted(self.live)}')
                if mode == 3 and x0 != destination:
                    self.problems.append('overlay loaded at the wrong address')
                if not (x0 <= x2 < x0 + x3):
                    self.problems.append(f'entry {x2:#x} outside image {x0:#x}+{x3:#x}')
            elif x1 == 1:
                if self.live:
                    self.problems.append(f'leaked blocks on error {x0}: {sorted(self.live)}')
                if x0 not in (2, 3, 5, 8, 11):
                    self.problems.append(f'unexpected DOS error {x0}')
            else:
                self.problems.append(f'x1={x1:#x} is neither success nor error')
        for base in list(self.blocks):
            self.cpu.mem_unmap(base, self.blocks.pop(base))
        return self.problems


INTERESTING32 = [0, 1, 2, 7, 8, 0x3f, 0x40, 0x7f, 0x80, 0xff, 0x100, 0x1ff, 0x200, 0xfff,
                 0x1000, 0x1001, 0xffff, 0x10000, 0xfffff, 0x100000, 0xffffff, 0x1000000,
                 0x1000001, 0x7fffffff, 0x80000000, 0xfffffff8, 0xffffffff]


def pe_fields(data):
    """Offsets of interesting header fields: (offset, width) pairs."""
    fields = [(60, 4)]
    if len(data) < 64:
        return fields
    pe = struct.unpack_from('<I', data, 60)[0]
    if pe + 248 > len(data):
        return fields
    opt = pe + 24
    fields += [(pe, 4), (pe + 4, 2), (pe + 6, 2), (pe + 20, 2), (opt, 2), (opt + 16, 4),
               (opt + 24, 8), (opt + 56, 4), (opt + 60, 4), (opt + 92, 4),
               (opt + 152, 4), (opt + 156, 4)]
    sections = opt + struct.unpack_from('<H', data, pe + 20)[0]
    count = struct.unpack_from('<H', data, pe + 6)[0]
    for index in range(min(count, 16)):
        base = sections + index * 40
        if base + 40 > len(data):
            break
        fields += [(base + 8, 4), (base + 12, 4), (base + 16, 4), (base + 20, 4)]
    return fields


def reloc_region(data):
    try:
        pe = struct.unpack_from('<I', data, 60)[0]
        opt = pe + 24
        rva, size = struct.unpack_from('<II', data, opt + 152)
        sections = opt + struct.unpack_from('<H', data, pe + 20)[0]
        for index in range(struct.unpack_from('<H', data, pe + 6)[0]):
            vsize, va, raw_size, raw = struct.unpack_from('<IIII', data, sections + index * 40 + 8)
            if va <= rva < va + max(vsize, raw_size):
                start = raw + rva - va
                return start, min(size, len(data) - start)
    except struct.error:
        pass
    return None


def mutate_exe(rng, seed_data):
    data = bytearray(seed_data)
    for _ in range(rng.randint(1, 4)):
        choice = rng.random()
        fields = pe_fields(data)
        if choice < 0.45 and fields:
            offset, width = rng.choice(fields)
            if offset + width > len(data):
                continue
            current = int.from_bytes(data[offset:offset + width], 'little')
            value = rng.choice([
                rng.choice(INTERESTING32), current + rng.randint(-16, 16),
                len(data) + rng.randint(-64, 64), rng.getrandbits(32),
                current ^ (1 << rng.randrange(width * 8)), current * 2, current // 2])
            data[offset:offset + width] = (value % (1 << (width * 8))).to_bytes(width, 'little')
        elif choice < 0.6:
            region = reloc_region(data)
            if not region or region[1] <= 0:
                continue
            start, size = region
            offset = start + rng.randrange(max(1, size))
            if rng.random() < 0.5 and offset + 4 <= len(data):
                data[offset:offset + 4] = rng.choice(INTERESTING32 + [rng.getrandbits(32)]) \
                    .to_bytes(4, 'little')
            elif offset + 2 <= len(data):
                data[offset:offset + 2] = rng.getrandbits(16).to_bytes(2, 'little')
        elif choice < 0.7:
            del data[rng.randrange(1, len(data)):]
        elif choice < 0.75:
            data += bytes(rng.choice([1, 100, 4096, 70000]))
        elif choice < 0.85:
            # Copy one section header over another (overlapping sections).
            fields = [f for f in pe_fields(data) if f[1] == 4]
            sec = [f[0] - 8 for f in fields[11:] if (f[0] - fields[11][0]) % 40 == 0] \
                if len(fields) > 11 else []
            if len(sec) >= 2:
                a, b = rng.sample(sec, 2)
                data[b:b + 40] = data[a:a + 40]
        else:
            limit = min(len(data), 1024)
            for _ in range(rng.randint(1, 8)):
                position = rng.randrange(limit)
                data[position] ^= 1 << rng.randrange(8)
    return bytes(data)


def exe_seeds(build):
    seeds = []
    for path in sorted(build.glob('*.EXE')) + sorted(build.glob('*.SYS')):
        data = path.read_bytes()
        if data[:2] == b'MZ' and len(data) <= 0x200000:
            seeds.append((path.name, data))
    return seeds


def exe_case(harness, data, rng):
    mode = rng.choice([1, 1, 3])
    chunk = rng.choice([1 << 30, 1 << 30, 512, 4096])
    overlay = rng.choice([0x10000, 0x20000, 0x1000000])
    return mode, chunk, overlay, harness.load(data, mode, chunk, overlay)


def fuzz_exe(args, findings, rng, seconds):
    harness = LoaderHarness(args.build, args.nm)
    seeds = exe_seeds(args.build)
    # Every real program must still load.
    for name, data in seeds:
        problems = harness.load(data)
        if problems:
            findings.save('exe', 'seed', data, f'{name}: {problems}', '.exe')
    deadline = time.monotonic() + seconds
    cases = 0
    seen = set()
    while time.monotonic() < deadline:
        name, seed_data = rng.choice(seeds)
        data = mutate_exe(rng, seed_data)
        mode, chunk, overlay, problems = exe_case(harness, data, rng)
        cases += 1
        if problems:
            key = re.sub(r'0x[0-9a-f]+|\d+', 'N', problems[0])
            if key in seen:
                continue
            seen.add(key)
            findings.save('exe', 'loader', data,
                          f'base: {name}\nmode: {mode}\nread chunk: {chunk}\n'
                          f'overlay capacity: {overlay:#x}\nproblems:\n  ' +
                          '\n  '.join(problems), f'-m{mode}-c{chunk}-o{overlay}.exe')
            harness = LoaderHarness(args.build, args.nm)
    print(f'exe: {cases} malformed images through pe_load', flush=True)
    return cases


def replay_exe(args, path):
    match = re.search(r'-m(\d+)-c(\d+)-o(\d+)\.exe$', path.name)
    mode, chunk, overlay = (int(match[1]), int(match[2]), int(match[3])) if match \
        else (1, 1 << 30, 0x10000)
    problems = LoaderHarness(args.build, args.nm).load(path.read_bytes(), mode, chunk, overlay)
    print('\n'.join(problems) or 'handled cleanly')
    return not problems


# ---------------------------------------------------------------------------
# QEMU sessions

PARTITION_OFFSET = 2048 * 512
ANSI = re.compile(rb'\x1b\[[0-9;=?]*[A-Za-z]')


class Hang(Exception):
    pass


class Fault(Exception):
    pass


def make_image(build, directory, files):
    """Copy the boot disk and add files under \\FZ with mtools."""
    image = Path(directory) / 'fuzz.img'
    shutil.copyfile(build / 'msdos-arm64.img', image)
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
    target = f'{image}@@{PARTITION_OFFSET}'
    subprocess.run(['mmd', '-i', target, '::/FZ'], check=True, env=env)
    staging = Path(directory) / 'files'
    staging.mkdir(exist_ok=True)
    paths = []
    for name, data in files.items():
        path = staging / name
        path.write_bytes(data)
        paths.append(str(path))
    for start in range(0, len(paths), 200):
        subprocess.run(['mcopy', '-o', '-i', target, *paths[start:start + 200], '::/FZ/'],
                       check=True, env=env)
    return image


class Session:
    def __init__(self, image, firmware, qemu='qemu-system-aarch64'):
        cmd = [qemu, '-machine', 'virt', '-cpu', 'cortex-a72', '-m', '256',
               '-bios', str(firmware), '-drive', f'file={image},format=raw,if=none,id=dos',
               '-device', 'virtio-blk-pci,drive=dos', '-nographic', '-monitor', 'none',
               '-net', 'none', '-no-reboot', '-boot', 'menu=on,splash-time=0']
        self.process = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.output = bytearray()
        self.mark = 0

    def send(self, data):
        try:
            self.process.stdin.write(data)
            self.process.stdin.flush()
        except BrokenPipeError:
            raise Fault('QEMU exited') from None

    def pump(self, timeout):
        for key, _ in self.selector.select(timeout=timeout):
            chunk = os.read(key.fileobj.fileno(), 65536)
            if not chunk:
                raise Fault('QEMU exited')
            self.output.extend(chunk)

    def text(self):
        return ANSI.sub(b'', self.output[self.mark:])

    def until(self, pattern, timeout, answer=None):
        """Wait for a bytes/regex pattern after the mark; return the text."""
        deadline = time.monotonic() + timeout
        regex = pattern if hasattr(pattern, 'search') else re.compile(re.escape(pattern))
        quiet_since = time.monotonic()
        size = len(self.output)
        while time.monotonic() < deadline:
            self.pump(0.05)
            text = self.text()
            if b'CPU exception' in text:
                end = time.monotonic() + 0.3
                while time.monotonic() < end:
                    self.pump(0.05)
                raise Fault(self.text()[-600:].decode(errors='replace'))
            found = regex.search(text)
            if found:
                self.mark += 0  # callers move the mark explicitly
                return text, found
            if len(self.output) != size:
                size, quiet_since = len(self.output), time.monotonic()
            elif answer and time.monotonic() - quiet_since > 0.4:
                reply = answer(text)
                if reply:
                    self.send(reply)
                quiet_since = time.monotonic()
        raise Hang(self.text()[-600:].decode(errors='replace'))

    def advance(self):
        self.mark = len(self.output)

    def close(self):
        self.selector.close()
        self.process.kill()
        self.process.wait()


def boot(image, firmware):
    session = Session(image, firmware)
    try:
        session.until(b'A:\\>', 30)
    except Exception:
        session.close()
        raise
    session.advance()
    return session


def tail_text(session, length=1500):
    return ANSI.sub(b'', session.output[-length:]).decode(errors='replace')


# ---------------------------------------------------------------------------
# BASIC

BASIC_OK = re.compile(rb'\r\nOk\r\n')


class BasicGen:
    """Random BASIC programs. finite=True when nothing jumps backwards."""

    def __init__(self, rng):
        self.rng = rng
        self.finite = True
        self.depth = 0

    def number(self):
        r = self.rng
        return r.choice([str(r.randint(0, 9)), str(r.randint(-1000, 1000)),
                         str(r.getrandbits(63)), '9223372036854775807',
                         '9223372036854775808', '-9223372036854775808',
                         '99999999999999999999999', '0', '1' * r.randint(1, 40),
                         '&H' + format(r.getrandbits(64), 'X'), '1E5', '.5', '00007'])

    def numvar(self):
        return self.rng.choice(['A', 'B', 'I', 'J', 'N', 'X1', 'LONGNAME', 'Z9'])

    def strvar(self):
        return self.rng.choice(['A$', 'B$', 'S$', 'Q$'])

    def string_lit(self):
        r = self.rng
        body = ''.join(r.choice('ABC xyz,:;"\'09!#') for _ in range(r.choice(
            [0, 1, 5, 40, 200, 300])))
        body = body.replace('"', '')
        return '"' + body + ('"' if r.random() < 0.9 else '')

    def nexpr(self, depth=0):
        r = self.rng
        if depth > r.choice([2, 4, 8, 40]) or r.random() < 0.3:
            return r.choice([self.number(), self.numvar(), self.numvar() + '(' +
                             str(r.randint(-2, 12)) + ')'])
        k = r.random()
        if k < 0.4:
            return self.nexpr(depth + 1) + r.choice(
                ['+', '-', '*', '/', '\\', '^', ' MOD ', '=', '<>', '<', '>=', ' AND ',
                 ' OR ']) + self.nexpr(depth + 1)
        if k < 0.55:
            return '(' * 1 + self.nexpr(depth + 1) + ')'
        if k < 0.6:
            return r.choice(['-', 'NOT ']) + self.nexpr(depth + 1)
        if k < 0.8:
            f = r.choice(['ABS', 'SGN', 'INT', 'SQR', 'RND'])
            return f + '(' + self.nexpr(depth + 1) + ')'
        f = r.choice(['LEN', 'ASC', 'VAL'])
        e = self.sexpr(depth + 1)
        if f == 'INSTR':
            return 'INSTR(' + e + ',' + self.sexpr(depth + 1) + ')'
        return f + '(' + e + ')'

    def sexpr(self, depth=0):
        r = self.rng
        if depth > 6 or r.random() < 0.35:
            return r.choice([self.string_lit(), self.strvar(), 'S$(' + str(r.randint(-1, 12)) + ')'])
        k = r.random()
        if k < 0.3:
            return self.sexpr(depth + 1) + '+' + self.sexpr(depth + 1)
        if k < 0.45:
            arg = str(r.choice([r.randint(32, 126), 0, 7, 255, 256, -1]))
            return 'CHR$(' + arg + ')'
        if k < 0.55:
            return 'STR$(' + self.nexpr(depth + 1) + ')'
        if k < 0.7:
            return r.choice(['LEFT$', 'RIGHT$']) + '(' + self.sexpr(depth + 1) + ',' + \
                self.nexpr(depth + 1) + ')'
        if k < 0.85:
            return 'MID$(' + self.sexpr(depth + 1) + ',' + self.nexpr(depth + 1) + \
                (',' + self.nexpr(depth + 1) if r.random() < 0.5 else '') + ')'
        return 'SPACE$(' + self.nexpr(depth + 1) + ')'

    def statement(self, line, lines):
        r = self.rng
        k = r.random()
        later = [n for n in lines if n > line]
        if k < 0.2:
            items = [r.choice([self.nexpr(), self.sexpr(), 'TAB(' + self.nexpr() + ')',
                               'SPC(' + self.nexpr() + ')']) for _ in range(r.randint(0, 4))]
            return r.choice(['PRINT ', '? ']) + r.choice([';', ',', ' ']).join(items) + \
                r.choice(['', ';', ','])
        if k < 0.32:
            return r.choice(['', 'LET ']) + self.numvar() + '=' + self.nexpr()
        if k < 0.4:
            return self.strvar() + '=' + self.sexpr()
        if k < 0.46:
            target = r.choice(later + [r.randint(0, 70000), 65535, 0]) if later else 99999
            if target <= line:
                target = line + 100000
            return r.choice(['GOTO ', 'GOSUB ']) + str(target)
        if k < 0.5:
            self.finite = False         # NEXT, RETURN, WEND may jump back
            return r.choice(['RETURN', 'NEXT', 'NEXT ' + self.numvar(), 'WEND', 'END',
                             'STOP', 'RESTORE', 'CLEAR', 'RANDOMIZE 7', 'CLS', 'REM x'])
        if k < 0.6:
            a, b = r.randint(-3, 6), r.randint(-3, 12)
            step = r.choice(['', ' STEP 1', ' STEP -1', ' STEP 2', ' STEP ' + self.number()])
            if step and step[6:] not in ('1', '-1', '2'):
                self.finite = False     # STEP 0 loops forever, as asked
            # Loop variables K0.. belong to one nesting depth each and are
            # never assigned elsewhere, so a loop always ends.
            v = f'K{self.depth}'
            self.depth += 1
            body = ': '.join(self.statement(line, []) for _ in range(r.randint(0, 2)))
            self.depth -= 1
            if r.random() < 0.8:
                return f'FOR {v}={a} TO {b}{step}: {body}: NEXT {v}'
            self.finite = False
            return f'FOR {v}={a} TO {b}{step}'
        if k < 0.68:
            return 'IF ' + self.nexpr() + ' THEN ' + self.statement(line, lines) + \
                (' ELSE ' + self.statement(line, lines) if r.random() < 0.4 else '')
        if k < 0.74:
            return 'DIM ' + r.choice(['A', 'S$', 'N', 'Q']) + '(' + r.choice(
                [str(r.randint(0, 20)), '-1', '100000000', '9999999999', self.nexpr()]) + ')'
        if k < 0.8:
            return 'DATA ' + ','.join(r.choice([self.number(), 'abc', '"q,r"', ''])
                                      for _ in range(r.randint(0, 5)))
        if k < 0.85:
            return 'READ ' + ','.join(r.choice([self.numvar(), self.strvar()])
                                      for _ in range(r.randint(1, 3)))
        if k < 0.9:
            targets = ','.join(str(r.choice(later or [99999])) for _ in range(r.randint(1, 4)))
            return 'ON ' + self.nexpr() + r.choice([' GOTO ', ' GOSUB ']) + targets
        if k < 0.93:
            return 'WHILE 0: PRINT 1: WEND'
        if k < 0.95:
            return r.choice(['A(', 'S$(']) + str(r.randint(-1, 15)) + ')=' + \
                (self.nexpr() if r.random() < 0.5 else self.sexpr())
        return r.choice(['PRINT ((((((((((((((((((((1))))))))))))))))))))', 'PRINT "' + 'x' * 300,
                         'PRINT 1+', 'PRINT )', 'GOTO', 'FOR', 'IF THEN', 'PRINT A$+1',
                         'A=B$', 'LET =', 'NEXT X Y', 'PRINT 1 2 3', '?' * 20,
                         'PRINT CHR$(', 'X=-' * 30 + '1', 'PRINT ' + '-' * 200 + '1',
                         'PRINT ' + '(' * 3000 + '1'])

    def stress(self):
        """Programs aimed at the interpreter's fixed limits."""
        r = self.rng
        n = r.choice([10, 63, 64, 65, 100, 511, 512, 513, 700, 2000])
        k = r.randrange(9)
        if k == 0:      # variable table
            return ''.join(f'{10 + i} V{i}=1: S{i}$="x"\r\n' for i in range(min(n, 1500)))
        if k == 1:      # FOR stack
            body = ':'.join(f'FOR K{i}=1 TO 1' for i in range(n))
            return f'10 {body}\r\n20 PRINT "deep"\r\n'
        if k == 2:      # GOSUB stack
            return ''.join(f'{10 + i} GOSUB {11 + i}\r\n' for i in range(n)) + \
                f'{10 + n} PRINT "bottom"\r\n'
        if k == 3:      # string space
            size = r.choice([100, 1000, 5000, 100000])
            return (f'10 DIM S$({size})\r\n20 FOR K0=0 TO {size}: S$(K0)=SPACE$(255): '
                    f'NEXT K0\r\n30 PRINT LEN(S$({size}))\r\n')
        if k == 4:      # numeric arrays and the heap
            dims = [r.choice([10, 1000, 100000, 1000000, 2**31, 2**62]) for _ in range(3)]
            return ''.join(f'{10 * (i + 1)} DIM A{i}({d})\r\n' for i, d in enumerate(dims)) + \
                '40 A0(5)=1: PRINT A0(5)\r\n'
        if k == 5:      # string concatenation past 255
            return ('10 A$="x"\r\n20 FOR K0=1 TO 10: A$=A$+A$: PRINT LEN(A$): '
                    'NEXT K0\r\n')
        if k == 6:      # program space
            return ''.join(f'{i + 1} REM ' + 'r' * 240 + '\r\n'
                           for i in range(r.choice([200, 270, 300, 1000])))
        if k == 7:      # DATA/READ mismatch and numbers
            return ('10 DATA 1,,"a",9223372036854775808,-,&HFFFFFFFFFFFFFFFFF,1E999\r\n'
                    '20 FOR K0=1 TO 9: READ A$: PRINT A$: NEXT K0\r\n'
                    '30 RESTORE: READ A: READ B: READ C\r\n')
        # arithmetic edges
        ops = ['-9223372036854775808/-1', '-9223372036854775808\\-1',
               '-9223372036854775808 MOD -1', '2^63', '2^62*2', '(-2)^63', '0^0', '0^-1',
               '2^-1', 'ABS(-9223372036854775808)', '-(-9223372036854775808)',
               'SQR(-1)', 'SQR(9223372036854775807)', 'INT(-9223372036854775808)',
               'VAL("-9223372036854775808")', 'VAL("99999999999999999999")',
               'SGN(-9223372036854775808)', 'RND(-9223372036854775808)', 'RND(0)',
               '1 MOD 0', '1\\0', 'ASC("")', 'CHR$(-1)', 'MID$("abc",0)',
               'MID$("abc",-9223372036854775808)', 'LEFT$("abc",-1)',
               'SPACE$(9223372036854775807)', 'INSTR("","")', 'STR$(-9223372036854775808)',
               'TAB(-9223372036854775808)', 'SPC(9223372036854775807)',
               '-9223372036854775807-1-1', '9223372036854775807*-1-2']
        return ''.join(f'{10 * (i + 1)} PRINT {op}\r\n' for i, op in
                       enumerate(r.sample(ops, 1)))

    def program(self):
        r = self.rng
        if r.random() < 0.15:
            return self.stress().encode()
        count = r.randint(1, 30)
        lines = sorted(r.sample(range(1, 65530), count)) if r.random() < 0.2 else \
            [10 * (i + 1) for i in range(count)]
        out = []
        if r.random() < 0.1:
            # Deep recursion: GOSUB to its own line ends with Out of memory.
            out.append(f'{lines[0]} GOSUB {lines[0]}')
        for line in lines[len(out):]:
            parts = [self.statement(line, lines) for _ in range(r.randint(1, 4))]
            text = f'{line} ' + ': '.join(parts)
            out.append(text)
        if r.random() < 0.08:
            out.append(f'{lines[-1] + 1} ' + 'PRINT "' + 'L' * r.choice([250, 400, 1000]) + '"')
        return ('\r\n'.join(out) + '\r\n').encode()


def mutate_basic(rng, data):
    data = bytearray(data)
    tokens = [b'GOTO ', b'GOSUB ', b'RETURN', b'NEXT', b'FOR I=1 TO ', b'"', b':', b'(',
              b')', b'$', b'99999999999999999999', b'-', b'/0', b'\r\n', b'WEND', b'ELSE',
              b'THEN', b'\x00', b'\x7f', b'\xff', b'\t', b'REM', b"'", b'MID$(', b'DIM A(']
    for _ in range(rng.randint(1, 8)):
        position = rng.randrange(len(data) + 1)
        k = rng.random()
        if k < 0.3 and data:
            data[min(position, len(data) - 1)] = rng.randrange(256)
        elif k < 0.6:
            data[position:position] = rng.choice(tokens)
        elif k < 0.8 and data:
            del data[position:position + rng.randint(1, 20)]
        else:
            start = rng.randrange(len(data) or 1)
            data[position:position] = data[start:start + rng.randint(1, 300)]
    return bytes(data)


def basic_sanitize(data):
    # No ESC (ANSI.SYS would reassign keys), no direct-mode file and exit
    # commands that leave or rewrite the test disk.
    data = data.replace(b'\x1b', b'.').replace(b'\x1a', b'.')
    for word in (b'SAVE', b'LOAD', b'SYSTEM', b'INPUT', b'save', b'load', b'system', b'input'):
        data = data.replace(word, b'REM ')
    return data


def basic_cases(rng, count):
    fixtures = [p.read_bytes() for p in sorted((SOURCE / 'fixtures').glob('*.BAS'))]
    cases = []
    for _ in range(count):
        if fixtures and rng.random() < 0.3:
            cases.append((basic_sanitize(mutate_basic(rng, rng.choice(fixtures))), False))
        else:
            gen = BasicGen(rng)
            program = gen.program()
            if rng.random() < 0.15:
                program = mutate_basic(rng, program)
                gen.finite = False
            # A program text with a backward jump or WHILE can loop forever.
            cases.append((basic_sanitize(program), gen.finite and b'RUN' not in program))
    return cases


def basic_answer(text):
    if text.endswith(b'? '):
        return b'1\r'
    return None


def run_basic_cases(firmware, build, cases, run_timeout=8.0):
    """Run cases in one boot. Returns (index, kind, detail) for the first
    failure, or None; also the number of cases completed."""
    files = {f'B{i:04d}.BAS': data for i, (data, _) in enumerate(cases)}
    with tempfile.TemporaryDirectory(prefix='armdos-fuzz-') as directory:
        image = make_image(build, directory, files)
        session = boot(image, firmware)
        try:
            session.send(b'cd \\FZ\r')
            session.until(b'A:\\FZ>', 10)
            session.advance()
            session.send(b'basic\r')
            session.until(BASIC_OK, 10)
            for index, (data, finite) in enumerate(cases):
                try:
                    session.advance()
                    session.send(b'NEW\r')
                    session.until(BASIC_OK, 5)
                    session.advance()
                    session.send(f'LOAD "B{index:04d}"\r'.encode())
                    session.until(BASIC_OK, 10)
                    session.advance()
                    session.send(b'RUN\r')
                    try:
                        session.until(re.compile(rb'\r\nOk\r\n|A:\\FZ>'),
                                      run_timeout if finite else 3, basic_answer)
                    except Hang:
                        session.send(b'\x03')
                        try:
                            session.until(BASIC_OK, 5)
                        except Hang:
                            return index, 'hang', tail_text(session)
                        if finite:
                            return index, 'loop', tail_text(session)
                    if b'A:\\FZ>' in session.text():
                        session.advance()
                        session.send(b'basic\r')
                        session.until(BASIC_OK, 10)
                    # The interpreter must still answer.
                    session.advance()
                    session.send(b'PRINT "Z"+"QX"\r')
                    try:
                        session.until(b'ZQX\r\nOk\r\n', 5)
                    except Hang:
                        session.advance()
                        session.send(b'\r\x03\rPRINT "Z"+"QX"\r')
                        session.until(b'ZQX\r\nOk\r\n', 5)
                except Fault as error:
                    return index, 'fault', str(error)
                except Hang:
                    return index, 'hang', tail_text(session)
            session.advance()
            session.send(b'SYSTEM\r')
            try:
                session.until(b'A:\\FZ>', 10)
            except (Hang, Fault):
                return len(cases) - 1, 'exit', tail_text(session)
        finally:
            session.close()
    return None


def fuzz_qemu(name, args, findings, rng, seconds, make_cases, runner, suffix, batch):
    deadline = time.monotonic() + seconds
    total = rounds = 0
    while time.monotonic() < deadline - 3:
        cases = make_cases(rng, batch)
        rounds += 1
        result = runner(args.firmware, args.build, cases)
        if result is None:
            total += len(cases)
            continue
        index, kind, detail = result
        total += index + 1
        data = cases[index][0]
        # Confirm alone: a finding that needs earlier cases keeps them.
        alone = runner(args.firmware, args.build, [cases[index]])
        if alone is None:
            prefix = cases[:index + 1]
            note = (f'Not reproduced alone; the {len(prefix)} cases of this boot, in order, '
                    f'are in the .seq file.\n\n{detail}')
            findings.save(name, kind + '-sequence', data, note, suffix(cases[index]))
            seq = findings.root / name / f'{kind}-sequence-{findings.seed}-{findings.count - 1:04d}.seq'
            seq.write_bytes(b'\n\x00SEP\x00\n'.join(c[0] for c in prefix))
        else:
            findings.save(name, alone[1], data, alone[2], suffix(cases[index]))
    print(f'{name}: {total} cases in {rounds} boots', flush=True)
    return total


# ---------------------------------------------------------------------------
# COMMAND lines

PROMPT = re.compile(rb'[A-D]:\\[^\r\n>]*>')
SAFE_WORDS = ['ECHO', 'echo', 'SET', 'REM', 'IF', 'FOR', 'TYPE', 'DIR', 'CD', 'CHDIR', 'MD',
              'VER', 'VOL', 'VERIFY', 'BREAK', 'CHCP', 'TRUENAME', 'CALL', 'GOTO', 'SHIFT',
              'PATH', 'NATIVE', 'native.exe', 'NOSUCH', 'X.EXE', 'Y.BAT', 'HELP', 'CLS',
              'DATE', 'TIME', 'COPY', 'DEL', 'REN', 'ECHO.', 'echo/', 'Echo,', '@echo',
              'MKDIR', 'A.B.C', '"echo"', 'DIR/W', 'CD..', 'TYPE.']
TEXT_FILES = ['T1.TXT', 'T2.TXT', 'EMPTY.TXT', 'NOFILE.TXT', 'O1.TXT', 'O2.TXT']
TOKENS = ['%', '%%', '%1', '%9', '%0', '%PATH%', '%NOSUCH%', '%ARMDOS%', '%%f', '%f',
          '"', '""', '" "', '"a b"', '|', '||', '>', '>>', '<', '>O1.TXT', '>>O2.TXT',
          '<T1.TXT', '|NATIVE', '| TYPE', '/', '/?', '/W', '/S', '/P', '-', '=', '==',
          ',', ';', '+', '[', ']', '.', '..', '...', '\\', 'A:', 'Z:', 'NUL', 'CON',
          'AUX', 'PRN', '*', '*.*', '?', '????????.???', 'ERRORLEVEL', 'EXIST', 'NOT',
          'IN', 'DO', '(', ')', '(a b c)', '()', '@', ':', ':LABEL', 'ON', 'OFF',
          'x' * 8, 'LONGFILENAME.EXTENSION', 'a\\b\\c', 'T1.TXT', 'T2.TXT', 'O1.TXT',
          '12-31-2026', '13-45-99', '25:61:61', '1-1-1980', '0', '99999999999999999999']


def cmd_word(rng, words, max_len):
    if rng.random() < 0.65:
        word = rng.choice(TOKENS)
    elif rng.random() < 0.5:
        word = rng.choice(words)
    else:
        word = ''.join(rng.choice('abcXYZ019_-.\\/"%=,;+|<>:*?') for _ in
                       range(rng.randint(1, 20)))
    return word


def safe_line(line):
    upper = line.upper()
    # Keep the disk, console and test layout intact.
    if re.search(r'(^|[\s@|])(EXIT|CTTY|PROMPT|FORMAT|PAUSE)\b', upper):
        return False
    if re.search(r'SET\s*(PATH|PROMPT|COMSPEC)', upper) or 'PATH ' in upper.lstrip('@'):
        return False
    if re.search(r'(DEL|ERASE|REN|RENAME|RD|RMDIR|COPY|MD|MKDIR|CD|CHDIR)\b.*[\\:]', upper):
        return False
    if re.search(r'(^|[\s|])(DEL|ERASE|REN|COPY)\b.*\*', upper):
        return False
    if re.search(r'(^|[\s|"])N(ATIVE)?\S*\s+[A-Za-z%]', line, re.I) and \
            not re.search(r'NATIVE(\.EXE)?(\s+x|\s*$|\s*[|>])', line, re.I):
        return False
    if re.search(r'NATIVE\S*\s*$|NATIVE\S*\s*[>]', upper) and '|' in upper:
        return False
    if re.search(r'(^|[\s|"(])(TYPE|NATIVE)\b', upper) and not re.search(
            r'TYPE\s*\S*\.TXT|TYPE\s*$|TYPE\s*(NUL|CON\b)|NATIVE', upper):
        return False
    if re.search(r'\bCON\b|\|', upper) and re.search(r'TYPE|COPY|NATIVE|<', upper):
        return False
    if '<' in upper and 'NATIVE' not in upper and re.search(r'<\s*CON|<\s*AUX', upper):
        return False
    if re.search(r'(^|[\s|])(CALL|Y\.BAT|C\d{4})', upper):
        return False
    if re.search(r'[A-Z]:\s*$', upper.strip()) or re.search(r'(^|\s)[A-Z]:(\s|$)', upper):
        return False
    return True


def console_line(rng):
    for _ in range(50):
        words = [rng.choice(SAFE_WORDS)]
        target = rng.choice([10, 40, 120, 126, 127, 128, 129, 200, 254, 255, 256, 300])
        while len(' '.join(words)) < target:
            words.append(cmd_word(rng, SAFE_WORDS, target))
            if rng.random() < 0.15:
                break
        sep = rng.choice([' ', ' ', '  ', '\t', ''])
        line = sep.join(words)
        if rng.random() < 0.3:
            line = line[:target]
        line = ''.join(c if 32 <= ord(c) < 127 else ' ' for c in line)
        if safe_line(line):
            return line
    return 'echo ' + 'x' * rng.choice([126, 127, 128, 255, 300])


def batch_file(rng, name):
    lines = []
    count = rng.randint(1, 15)
    labels = sorted(rng.sample(range(count + 1), min(3, count)))
    for position in range(count):
        if position in labels:
            lines.append(f':L{position}')
        k = rng.random()
        later = [p for p in labels if p > position]
        if k < 0.1 and later:
            line = f'GOTO L{rng.choice(later)}'
        elif k < 0.15:
            line = 'GOTO ' + rng.choice(['NOWHERE', '', ':', 'L' + 'x' * 200])
        elif k < 0.2:
            line = 'FOR %%f IN (' + ' '.join(cmd_word(rng, SAFE_WORDS, 20)
                                            for _ in range(rng.randint(0, 6))) + \
                ') DO ' + rng.choice(['echo %%f', 'echo [%%f]', 'rem %%f', 'echo %f'])
        elif k < 0.25:
            line = 'IF ' + rng.choice(['ERRORLEVEL 1', 'NOT ERRORLEVEL 0', 'EXIST T1.TXT',
                                       'EXIST *.*', '"%1"=="x"', '%1==', '==', 'NOT',
                                       '"a"=="a', 'x==x']) + ' ' + rng.choice(
                ['echo yes', 'echo', 'GOTO NOWHERE', 'SET A=1', ''])
        elif k < 0.3:
            line = 'SET ' + rng.choice(['A', 'B', 'LONG' * 10, '', '=', 'A=%A%%A%',
                                        'B=' + 'v' * 200, 'C=%1%2%3', 'A==', 'a b=c'])
        elif k < 0.33:
            line = rng.choice(['SHIFT', 'SHIFT', 'echo off', 'echo on', '@echo off',
                               'echo %0 %1 %2 %9', 'echo %%', 'echo 100%', 'echo %A%',
                               'echo %' + 'X' * 100, 'echo %%%%%%%', 'EXIT /B'])
        else:
            line = console_line(rng)
            if rng.random() < 0.3:
                line = line.replace(' ', rng.choice(['%1', '%A%', '%%', ' %0 ']), 1)
            if not safe_line(line):
                continue
        if rng.random() < 0.15:
            # Control bytes (never ^Z, ESC or a line end) and high bytes.
            data = bytearray(line.encode())
            for _ in range(rng.randint(1, 4)):
                data.insert(rng.randrange(len(data) + 1),
                            rng.choice([0, 1, 7, 8, 9, 11, 12, 0x7f, 0x80, 0xff, 0xe9, 0x9b]))
            line = data.decode('latin-1')
        if rng.random() < 0.08:
            line = line + ' ' + 'P' * rng.choice([200, 300, 600, 2000])
        lines.append(line)
    if rng.random() < 0.1:
        lines.append(f'CALL {name}')       # recursion: the 16-level limit ends it
    ending = rng.choice(['\r\n', '\n', '\r\n', '\r'])
    data = ending.join(lines).encode('latin-1')
    if rng.random() < 0.7:
        data += ending.encode()
    return data


def cmd_cases(rng, count):
    cases = []
    for index in range(count):
        if rng.random() < 0.6:
            cases.append((console_line(rng).encode(), 'line'))
        else:
            cases.append((batch_file(rng, f'C{index:04d}'), 'batch'))
    return cases


def cmd_answer(text):
    tail = text[-80:]
    if tail.endswith(b'(mm-dd-yy): ') or tail.endswith(b'time: '):
        return b'\r'
    if b'(Y/N)' in tail:
        return b'n\r' if b'Terminate' not in tail else b'y'
    if b'Press any key' in tail or b'continue' in tail:
        return b' '
    return b'\r'


CMD_FILES = {'T1.TXT': b'alpha\r\nbeta\r\n', 'T2.TXT': b'x' * 3000 + b'\r\n',
             'EMPTY.TXT': b''}


def run_cmd_cases(firmware, build, cases, timeout=6.0):
    files = dict(CMD_FILES)
    for index, (data, kind) in enumerate(cases):
        if kind == 'batch':
            files[f'C{index:04d}.BAT'] = data
    with tempfile.TemporaryDirectory(prefix='armdos-fuzz-') as directory:
        image = make_image(build, directory, files)
        session = boot(image, firmware)
        try:
            session.send(b'cd \\FZ\r')
            session.until(b'A:\\FZ>', 10)
            for index, (data, kind) in enumerate(cases):
                session.advance()
                line = data if kind == 'line' else f'C{index:04d}'.encode()
                sentinel = f'ZQ{index}X'.encode()
                try:
                    session.send(line + b'\r')
                    session.until(PROMPT, timeout, cmd_answer)
                    session.advance()
                    # Restore the state a case may change, then a sentinel.
                    session.send(b'echo on\r')
                    session.until(PROMPT, timeout, cmd_answer)
                    session.advance()
                    session.send(b'cd \\FZ\r')
                    session.until(b'A:\\FZ>', timeout, cmd_answer)
                    session.advance()
                    session.send(b'echo ' + sentinel + b'\r')
                    session.until(sentinel + b'\r\n', timeout, cmd_answer)
                except Fault as error:
                    return index, 'fault', str(error)
                except Hang:
                    session.send(b'\x03')
                    try:
                        session.until(PROMPT, 3, cmd_answer)
                        session.advance()
                        session.send(b'cd \\FZ\r')
                        session.until(b'A:\\FZ>', 3, cmd_answer)
                    except (Hang, Fault):
                        return index, 'hang', tail_text(session)
                    return index, 'stuck', tail_text(session)
            session.advance()
            session.send(b'selftest\r')
            try:
                text, _ = session.until(PROMPT, 20)
            except (Hang, Fault):
                return len(cases) - 1, 'selftest', tail_text(session)
            if b'SELFTEST PASS' not in text:
                return len(cases) - 1, 'selftest', tail_text(session)
        finally:
            session.close()
    return None


# ---------------------------------------------------------------------------

def replay(args, path):
    if path.suffix.lower() == '.exe':
        return replay_exe(args, path)
    data = path.read_bytes()
    if path.suffix.lower() == '.bas':
        result = run_basic_cases(args.firmware, args.build, [(data, b'GOTO' not in data)])
    elif path.suffix.lower() == '.bat':
        result = run_cmd_cases(args.firmware, args.build, [(data, 'batch')])
    else:
        result = run_cmd_cases(args.firmware, args.build, [(data.rstrip(b'\r\n'), 'line')])
    print(result[2] if result else 'handled cleanly')
    return result is None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--build', type=Path, default=Path('build'))
    parser.add_argument('--nm', default='aarch64-linux-gnu-nm')
    parser.add_argument('--firmware', type=Path,
                        default=Path('/usr/share/qemu-efi-aarch64/QEMU_EFI.fd'))
    parser.add_argument('--seconds', type=float,
                        default=float(os.environ.get('FUZZ_SECONDS') or 60))
    parser.add_argument('--seed', type=int, default=int(os.environ.get('FUZZ_SEED') or
                                                        int(time.time()) % 100000))
    parser.add_argument('--surfaces', default='exe,basic,cmd')
    parser.add_argument('--replay', type=Path, help='run one saved finding')
    args = parser.parse_args()
    if args.replay:
        sys.exit(0 if replay(args, args.replay) else 1)
    surfaces = args.surfaces.split(',')
    share = {'exe': 0.2, 'basic': 0.4, 'cmd': 0.4}
    total_share = sum(share[s] for s in surfaces)
    findings = Findings(args.build, args.seed)
    print(f'fuzz-sys: seed {args.seed}, {args.seconds:g}s ({",".join(surfaces)})', flush=True)
    for surface in surfaces:
        seconds = args.seconds * share[surface] / total_share
        rng = random.Random(f'{args.seed}-{surface}')
        if surface == 'exe':
            fuzz_exe(args, findings, rng, seconds)
        elif surface == 'basic':
            fuzz_qemu('basic', args, findings, rng, seconds, basic_cases, run_basic_cases,
                      lambda case: '.bas', 40)
        elif surface == 'cmd':
            fuzz_qemu('cmd', args, findings, rng, seconds,
                      cmd_cases, run_cmd_cases,
                      lambda case: '.bat' if case[1] == 'batch' else '.cmd', 60)
    if findings.count:
        sys.exit(f'fuzz-sys: {findings.count} finding(s) in {findings.root} (seed {args.seed})')
    print(f'PASS: fuzz-sys, no findings (seed {args.seed})')


if __name__ == '__main__':
    main()
