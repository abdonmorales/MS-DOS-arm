#!/usr/bin/env python3
"""Host-side unit tests: call individual AArch64 routines from kernel.elf.

The routines run under the Unicorn CPU emulator with no firmware and no boot,
so leaf code can be checked against a Python reference over every input in
its domain (or a large exhaustive slice of it) in a few seconds. Where the
domain is finite and fully enumerated, a pass is a proof for that routine.

Only routines that need no UEFI services are called here. Anything that
reaches firmware stops with a clear error instead of running off into
unmapped memory.
"""
import argparse
import concurrent.futures
import datetime
import functools
import itertools
import os
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

try:
    from unicorn import Uc, UcError, UC_ARCH_ARM64, UC_MODE_ARM, UC_PROT_ALL, UC_HOOK_CODE
    from unicorn.arm64_const import UC_ARM64_REG_X0, UC_ARM64_REG_SP, UC_ARM64_REG_LR, \
        UC_ARM64_REG_PC
except ImportError:
    sys.exit('unit.py needs the Unicorn emulator: python3 -m pip install unicorn')

SOURCE = Path(__file__).resolve().parent.parent
IMAGE_BASE = 0x1000          # link.ld: first section VMA; kernel.bin starts here
MEMORY_SIZE = 0x400000
SCRATCH = 0x300000           # argument strings
STACK_TOP = 0x3F0000
RETURN_TRAP = 0x3FF000       # BRK #0; reaching it ends a call
CALL_TIMEOUT = 2.0           # seconds; any single routine call is microseconds


class Kernel:
    def __init__(self, build, nm):
        self.symbols = {}
        listing = subprocess.check_output([nm, str(build / 'kernel.elf')], text=True)
        for line in listing.splitlines():
            parts = line.split()
            if len(parts) == 3:
                self.symbols.setdefault(parts[2], int(parts[0], 16))
        image = (build / 'kernel.bin').read_bytes()
        end = self.symbols.get('__image_end', IMAGE_BASE + len(image))
        if end >= SCRATCH:
            raise RuntimeError('kernel image overlaps the unit-test scratch area')
        self.cpu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        self.cpu.mem_map(0, MEMORY_SIZE, UC_PROT_ALL)
        self.cpu.mem_write(IMAGE_BASE, image)
        self.cpu.mem_write(RETURN_TRAP, bytes.fromhex('000020d4'))
        self.stops = {}
        self.stopped_at = None
        # A hung routine must fail the test, not stall it. Unicorn's own
        # count=/timeout= limits make every call several times slower, so a
        # watchdog thread stops the CPU when one call runs past CALL_TIMEOUT.
        self.call_serial = 0
        self.in_call = False
        self.timed_out = False
        threading.Thread(target=self._watchdog, daemon=True).start()

    def _watchdog(self):
        seen = None
        while True:
            time.sleep(CALL_TIMEOUT / 2)
            current = (self.call_serial, self.in_call)
            if current[1] and current == seen:
                self.timed_out = True
                self.cpu.emu_stop()
            seen = current

    def address(self, name):
        try:
            return self.symbols[name]
        except KeyError:
            raise RuntimeError('symbol not found in kernel.elf: ' + name) from None

    def stop_at(self, names):
        """Stop a call as soon as execution reaches any of these symbols."""
        for name in names:
            address = self.address(name)
            if address not in self.stops:
                self.stops[address] = name
                self.cpu.hook_add(UC_HOOK_CODE, self._stop_hook, begin=address, end=address)

    def _stop_hook(self, cpu, address, size, data):
        self.stopped_at = self.stops[address]
        cpu.emu_stop()

    def call(self, name, *args, w8=None, results=3):
        """Run a routine with AAPCS64 integer arguments; return x0 onward.

        Only the registers named by the call are written and read, because
        each Unicorn register access costs about as much as a short routine.
        """
        cpu = self.cpu
        for index, value in enumerate(args):
            cpu.reg_write(UC_ARM64_REG_X0 + index, value)
        if w8 is not None:
            cpu.reg_write(UC_ARM64_REG_X0 + 8, w8)
        cpu.reg_write(UC_ARM64_REG_SP, STACK_TOP)
        cpu.reg_write(UC_ARM64_REG_LR, RETURN_TRAP)
        self.stopped_at = None
        self.call_serial += 1
        self.in_call = True
        try:
            # No count/timeout limit: either one makes Unicorn several times slower.
            cpu.emu_start(self.address(name), RETURN_TRAP)
        except UcError as error:
            pc = cpu.reg_read(UC_ARM64_REG_PC)
            raise RuntimeError(f'{name} faulted at pc={pc:#x}: {error}') from None
        finally:
            self.in_call = False
        pc = cpu.reg_read(UC_ARM64_REG_PC)
        if self.timed_out:
            raise RuntimeError(f'{name} did not return within {CALL_TIMEOUT:g}s '
                               f'(pc={pc:#x}); infinite loop?')
        if self.stopped_at is None and pc != RETURN_TRAP:
            raise RuntimeError(f'{name} stopped at pc={pc:#x} without returning')
        return [cpu.reg_read(UC_ARM64_REG_X0 + index) for index in range(results)]

    def strings(self, *values):
        """Place NUL-terminated byte strings in scratch memory; return addresses."""
        addresses, cursor = [], SCRATCH
        for value in values:
            self.cpu.mem_write(cursor, value + b'\0')
            addresses.append(cursor)
            cursor += (len(value) + 16) & ~15
        return addresses


def valid_dos_date(year, month, day):
    try:
        datetime.date(year, month, day)
    except ValueError:
        return False
    return 1980 <= year <= 2107


def test_dates(kernel):
    """validate_date, date_to_days, days_to_date: every y/m/d for 1975-2111."""
    epoch = datetime.date(1980, 1, 1)
    calls = 0
    for year in range(1975, 2112):
        for month in range(0, 14):
            for day in range(0, 33):
                expected = valid_dos_date(year, month, day)
                actual = kernel.call('validate_date', year, month, day, results=1)[0] == 0
                calls += 1
                if actual != expected:
                    raise AssertionError(f'validate_date({year}, {month}, {day}) = {actual}')
                if not expected:
                    continue
                days = (datetime.date(year, month, day) - epoch).days
                got = kernel.call('date_to_days', year, month, day, results=1)[0]
                if got != days:
                    raise AssertionError(f'date_to_days({year}, {month}, {day}) = {got}, '
                                         f'expected {days}')
                got = kernel.call('days_to_date', days)[:3]
                if got != [year, month, day]:
                    raise AssertionError(f'days_to_date({days}) = {got}')
                calls += 2
    return calls


def efi_time(year, month, day, hour=0, minute=0, second=0):
    return (year.to_bytes(2, 'little') + bytes([month, day, hour, minute, second]) +
            bytes(9))


def test_pack_efi_time(kernel):
    """pack_efi_time: every calendar date 1975-2111, then every time of day."""
    (buffer,) = kernel.strings(bytes(16))
    calls = 0

    def check(year, month, day, hour, minute, second):
        kernel.cpu.mem_write(buffer, efi_time(year, month, day, hour, minute, second))
        date, clock = kernel.call('pack_efi_time', buffer, results=2)
        if 1980 <= year <= 2107:
            expected = (((year - 1980) << 9) | (month << 5) | day,
                        (hour << 11) | (minute << 5) | (second >> 1))
        else:
            expected = (0, 0)
        if (date & 0xffffffff, clock & 0xffffffff) != expected:
            raise AssertionError(f'pack_efi_time({year}-{month}-{day} {hour}:{minute}:'
                                 f'{second}) = {date:#x}, {clock:#x}; expected '
                                 f'{expected[0]:#x}, {expected[1]:#x}')

    day = datetime.date(1975, 1, 1)
    while day.year < 2112:
        check(day.year, day.month, day.day, 23, 59, 59)
        day += datetime.timedelta(days=1)
        calls += 1
    for hour, minute, second in itertools.product(range(24), range(60), range(60)):
        check(2026, 11, 26, hour, minute, second)
        calls += 1
    return calls


def reference_wildcard(pattern, name):
    """DOS-flavoured glob: ? is one character, * any run, ASCII letters fold
    case, and the exact pattern *.* also matches names with no extension."""
    if pattern == b'*.*':
        return True
    fold = bytes.maketrans(b'abcdefghijklmnopqrstuvwxyz', b'ABCDEFGHIJKLMNOPQRSTUVWXYZ')
    pattern, name = pattern.translate(fold), name.translate(fold)

    @functools.lru_cache(maxsize=None)
    def match(p, n):
        if p == len(pattern):
            return n == len(name)
        if pattern[p] == ord('*'):
            return match(p + 1, n) or (n < len(name) and match(p, n + 1))
        if n < len(name) and pattern[p] in (ord('?'), name[n]):
            return match(p + 1, n + 1)
        return False
    return match(0, 0)


def check_wildcard(kernel, pairs):
    calls = 0
    for pattern, name in pairs:
        pattern_address, name_address = kernel.strings(pattern, name)
        actual = kernel.call('wildcard_match', pattern_address, name_address,
                             results=1)[0] == 1
        calls += 1
        if actual != reference_wildcard(pattern, name):
            raise AssertionError(f'wildcard_match({pattern!r}, {name!r}) = {actual}')
    return calls


def test_wildcard_strings(kernel):
    """wildcard_match: every pattern over {a,B,?,*,.} and name over {a,b,B,.} up to
    four characters, plus DOS spellings."""
    patterns = [bytes(p) for n in range(5) for p in itertools.product(b'aB?*.', repeat=n)]
    names = [bytes(p) for n in range(5) for p in itertools.product(b'abB.', repeat=n)]
    extra = [(b'*.*', b'NOEXT'), (b'*.*', b''), (b're?amed.*', b'RENAMED.TXT'),
             (b'*.TXT', b'armtest.txt'), (b'*.TXT', b'ARMTEST.TX'), (b'A*B*C', b'AXBYBC')]
    return check_wildcard(kernel, itertools.chain(itertools.product(patterns, names), extra))


def test_wildcard_bytes(kernel):
    """wildcard_match: every pair of single bytes 1-255, which covers case folding."""
    single = [bytes([n]) for n in range(1, 256)]
    return check_wildcard(kernel, itertools.product(single, single))


def documented_functions():
    """Function numbers listed in the ABI.md dispatch table."""
    numbers = set()
    for line in (SOURCE / 'ABI.md').read_text().splitlines():
        cell = line.split('|')[1] if line.startswith('| `') else ''
        numbers.update(int(value, 16) for value in re.findall(r'`([0-9A-Fa-f]{2})h`', cell))
    return numbers


# DOS function number -> handler label in dos_call. This is the spec the binary
# is checked against; change it together with dispatch.S and ABI.md.
DISPATCH = {
    0x00: 'dos_terminate_zero', 0x01: 'dos_console_input', 0x02: 'dos_console_out',
    0x03: 'dos_aux_input', 0x04: 'dos_aux_output', 0x05: 'dos_printer_output',
    0x06: 'dos_console_direct', 0x07: 'dos_console_noecho', 0x08: 'dos_console_noecho',
    0x09: 'dos_print_string', 0x0a: 'dos_console_buffer', 0x0b: 'dos_console_status',
    0x0c: 'dos_console_flush', 0x0d: 'dos_disk_reset', 0x0e: 'dos_set_drive',
    0x0f: 'fcbx_open', 0x10: 'fcbx_close', 0x11: 'dos_fcb_find_first',
    0x12: 'dos_fcb_find_next', 0x13: 'dos_fcb_delete_wild', 0x14: 'fcbx_seq_read',
    0x15: 'fcbx_seq_write', 0x16: 'fcbx_create', 0x17: 'dos_fcb_rename',
    0x18: 'dos_null_function', 0x19: 'dos_get_drive', 0x1a: 'dos_set_dta',
    0x1b: 'dos_alloc_info_default', 0x1c: 'dos_alloc_info', 0x1d: 'dos_null_function',
    0x1e: 'dos_null_function', 0x1f: 'dos_get_dpb_default', 0x20: 'dos_null_function',
    0x21: 'fcbx_random_read', 0x22: 'fcbx_random_write', 0x23: 'fcbx_get_length',
    0x24: 'fcbx_get_position', 0x25: 'dos_set_vector', 0x26: 'dos_create_psp',
    0x27: 'fcbx_block_read', 0x28: 'fcbx_block_write', 0x29: 'dos_parse_filename',
    0x2a: 'dos_get_date', 0x2b: 'dos_set_date', 0x2c: 'dos_get_time',
    0x2d: 'dos_set_time', 0x2e: 'dos_set_verify', 0x2f: 'dos_get_dta',
    0x30: 'dos_get_version', 0x31: 'dos_keep_process', 0x32: 'dos_get_dpb',
    0x33: 'dos_break', 0x34: 'dos_get_indos', 0x35: 'dos_get_vector',
    0x36: 'dos_free_space', 0x37: 'dos_switchar', 0x38: 'dos_country',
    0x39: 'dos_mkdir', 0x3a: 'dos_rmdir', 0x3b: 'dos_chdir', 0x3c: 'dos_create',
    0x3d: 'dos_open', 0x3e: 'dos_close', 0x3f: 'dos_read', 0x40: 'dos_write',
    0x41: 'dos_delete', 0x42: 'dos_seek', 0x43: 'dos_attributes', 0x44: 'dos_ioctl',
    0x45: 'dos_dup', 0x46: 'dos_dup2', 0x47: 'dos_getcwd', 0x48: 'dos_allocate',
    0x49: 'dos_free', 0x4a: 'dos_resize', 0x4b: 'dos_exec_call', 0x4c: 'dos_terminate',
    0x4d: 'dos_get_exit_code', 0x4e: 'dos_find_first', 0x4f: 'dos_find_next',
    0x50: 'dos_set_psp', 0x51: 'dos_get_psp', 0x52: 'dos_list_of_lists',
    0x53: 'dos_translate_bpb', 0x54: 'dos_get_verify', 0x55: 'dos_child_psp',
    0x56: 'dos_rename', 0x57: 'dos_file_time', 0x58: 'dos_strategy',
    0x59: 'dos_extended_error', 0x5a: 'dos_create_temp', 0x5b: 'dos_create_new',
    0x5c: 'dos_lock', 0x5d: 'dos_server', 0x5e: 'dos_network_machine',
    0x5f: 'dos_network_redirect', 0x60: 'dos_truename', 0x61: 'dos_null_function',
    0x62: 'dos_get_psp', 0x63: 'dos_dbcs', 0x64: 'dos_null_function',
    0x65: 'dos_ext_country', 0x66: 'dos_code_page', 0x67: 'dos_handle_count',
    0x68: 'dos_commit', 0x69: 'dos_media_id', 0x6a: 'dos_commit',
    0x6b: 'dos_null_function', 0x6c: 'dos_extended_open',
}


def test_dispatcher(kernel):
    """dos_call: every function number 0-255, plus out-of-range w8 values.

    Each number in DISPATCH must reach its handler; every other number must
    return x0=1, x1=1 without touching a handler. DISPATCH must list exactly
    the functions ABI.md documents.
    """
    table = DISPATCH
    documented = documented_functions()
    if set(table) != documented:
        raise AssertionError('DISPATCH and ABI.md disagree; only in DISPATCH: '
                             f'{sorted(hex(n) for n in set(table) - documented)}, only in '
                             f'ABI.md: {sorted(hex(n) for n in documented - set(table))}')
    kernel.stop_at(set(table.values()))
    # dos_call must look only at w8: the upper half of x8 is garbage.
    values = list(range(256)) + [0x100 + n for n in table] + [0xffffffff, 0x8000000d,
                                                            0xdead_0000_0000_000d,
                                                            0xffff_ffff_0000_0040]
    for number in values:
        x0, x1 = kernel.call('dos_call', w8=number, results=2)
        expected = table.get(number & 0xffffffff)
        if expected is None:
            if kernel.stopped_at is not None or (x0, x1) != (1, 1):
                raise AssertionError(f'dos_call w8={number:#x} should fail with error 1, '
                                     f'reached {kernel.stopped_at}, x0={x0}, x1={x1}')
        elif kernel.stopped_at != expected:
            raise AssertionError(f'dos_call w8={number:#x} reached {kernel.stopped_at}, '
                                 f'expected {expected}')
    return len(values)


TESTS = [test_wildcard_strings, test_dates, test_pack_efi_time, test_wildcard_bytes,
         test_dispatcher]


def run_test(build, nm, test):
    """Run one test in a fresh emulator; return (name, calls, seconds, error)."""
    began = time.monotonic()
    try:
        calls = test(Kernel(build, nm))
    except (AssertionError, RuntimeError) as error:
        return test.__name__, 0, time.monotonic() - began, str(error)
    return test.__name__, calls, time.monotonic() - began, None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--build', type=Path, default=Path('build'))
    parser.add_argument('--nm', default='aarch64-linux-gnu-nm')
    parser.add_argument('-k', dest='only', help='run tests whose name contains this text')
    parser.add_argument('-j', dest='jobs', type=int, default=os.cpu_count(),
                        help='tests to run in parallel (default: CPU count)')
    args = parser.parse_args()
    started = time.monotonic()
    tests = [test for test in TESTS if not args.only or args.only in test.__name__]
    if not tests:
        sys.exit(f'no unit test name contains {args.only!r}')
    with concurrent.futures.ProcessPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        results = list(pool.map(run_test, itertools.repeat(args.build),
                                itertools.repeat(args.nm), tests))
    failures = 0
    for name, calls, seconds, error in results:
        if error:
            failures += 1
            print(f'FAIL {name}: {error}')
        else:
            print(f'ok   {name}: {calls} calls, {seconds:.2f}s')
    if failures:
        sys.exit(f'{failures} unit test(s) failed')
    print(f'PASS: {len(results)} unit tests, {sum(r[1] for r in results)} routine calls, '
          f'{time.monotonic() - started:.2f}s')


if __name__ == '__main__':
    main()
