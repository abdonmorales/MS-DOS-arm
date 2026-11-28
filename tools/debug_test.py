#!/usr/bin/env python3
"""Boot checkpoints (src/debug.S) on QEMU virt.

With \\DEBUG.ON on the boot volume every "ARMDOS:" checkpoint must appear, in
boot order: the early ones through the firmware console, the rest written
straight to the PL011 after ExitBootServices. A CPU exception in a program
must dump its registers. Without the file not a single checkpoint may appear.
"""
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

ORDER = [
    'ARMDOS: entry',
    'ARMDOS: EL=',
    'ARMDOS: FAT mount ok (native FAT driver)',
    'ARMDOS: debug output on (\\DEBUG.ON)',
    'ARMDOS: console UART (ACPI SPCR or device tree) base=0000000009000000',
    'ARMDOS:   UART type (0 PL011, 1 mini UART/16550 32-bit, 2-3 16550 8-bit)=0000000000000000',
    'ARMDOS:   PCI ECAM (0: none, Raspberry Pi path)=',
    'ARMDOS: exit boot services',
    'ARMDOS: boot services exited, UART direct, vectors set, EL=',
    'ARMDOS: virtio-blk init (0 ok)=0000000000000000',
    'ARMDOS: platform ready, printing banner',
    'ARMDOS: boot self-test',
    'ARMDOS: CONFIG.SYS',
    'ARMDOS: COMMAND (AUTOEXEC.BAT, then the prompt)',
]
FAULT = [
    'ARMDOS: CPU exception, vector=',
    'ARMDOS:   ESR=',
    'ARMDOS:   ELR=',
    'ARMDOS:   ELR in kernel.elf=',
    'ARMDOS:   FAR=',
    'ARMDOS:   SPSR=',
    'ARMDOS:   handler SP+256=',
    'ARMDOS:   x00=',
    'ARMDOS:   x30=',
    'Program terminated by CPU exception.',
]


class Machine:
    def __init__(self, qemu, firmware, image, timeout):
        self.timeout = timeout
        self.output = bytearray()
        self.seen = 0           # end of the last match
        self.process = subprocess.Popen(
            [qemu, '-machine', 'virt', '-cpu', 'cortex-a72', '-m', '256',
             '-bios', str(firmware), '-drive', f'file={image},format=raw,if=none,id=dos',
             '-device', 'virtio-blk-pci,drive=dos', '-nographic', '-monitor', 'none',
             '-net', 'none', '-no-reboot', '-boot', 'menu=on,splash-time=0'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)

    def until(self, expected):
        deadline = time.monotonic() + self.timeout
        # Search on from the last match, not from the end of the output:
        # the next prompt often arrives in the same read as the last match.
        mark = self.seen
        while time.monotonic() < deadline:
            for key, _ in self.selector.select(timeout=0.1):
                chunk = os.read(key.fileobj.fileno(), 8192)
                if not chunk:
                    raise SystemExit('QEMU exited early:\n' + self.text())
                self.output.extend(chunk)
            found = self.output.find(expected, mark)
            if found >= 0:
                self.seen = found + len(expected)
                return
        raise SystemExit(f'Timed out waiting for {expected!r}:\n' + self.text()[-3000:])

    def send(self, line):
        self.process.stdin.write(line.encode() + b'\r')
        self.process.stdin.flush()

    def text(self):
        raw = re.sub(rb'\x1b\[[0-9;=?]*[A-Za-z]', b'', bytes(self.output))
        return raw.decode(errors='replace').replace('\r', '')

    def stop(self):
        self.process.kill()
        self.process.wait(timeout=5)


def in_order(text, items, what):
    position = 0
    for item in items:
        found = text.find(item, position)
        if found < 0:
            raise SystemExit(f'{what}: missing or out of order: {item!r}\n' + text[-4000:])
        position = found + len(item)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('image', type=Path)
    parser.add_argument('--firmware', required=True, type=Path)
    parser.add_argument('--qemu', default='qemu-system-aarch64')
    parser.add_argument('--timeout', type=float, default=45)
    parser.add_argument('--log', type=Path)
    args = parser.parse_args()
    log = []
    with tempfile.TemporaryDirectory(prefix='arm64-debug-') as directory:
        plain = Path(directory) / 'plain.img'
        shutil.copyfile(args.image, plain)
        machine = Machine(args.qemu, args.firmware, plain, args.timeout)
        try:
            machine.until(b'A:\\>')
        finally:
            machine.stop()
        log.append(machine.text())
        if 'ARMDOS:' in machine.text():
            raise SystemExit('Checkpoints printed without \\DEBUG.ON:\n' + machine.text())

        image = Path(directory) / 'debug.img'
        shutil.copyfile(args.image, image)
        with image.open('rb') as disk:
            start = struct.unpack_from('<I', disk.read(512), 454)[0]
        flag = Path(directory) / 'DEBUG.ON'
        flag.write_bytes(b'')
        subprocess.run(['mcopy', '-i', f'{image}@@{start * 512}', str(flag), '::/DEBUG.ON'],
                       check=True, env=dict(os.environ, MTOOLS_SKIP_CHECK='1'))
        machine = Machine(args.qemu, args.firmware, image, args.timeout)
        try:
            machine.until(b'A:\\>')
            boot = machine.text()
            machine.send('native fault')
            machine.until(b'Program terminated by CPU exception.')
            machine.until(b'A:\\>')
            machine.send('ver')
            machine.until(b'ARM DOS Version 4.00')
        finally:
            machine.stop()
        text = machine.text()
        log.append(text)
        if args.log:
            args.log.write_text('\n==== with \\DEBUG.ON ====\n'.join(log))
    in_order(boot, ORDER, 'Boot checkpoints')
    if boot.count('ARMDOS: entry') != 1:
        raise SystemExit('Checkpoint "entry" printed more than once')
    in_order(text[len(boot):], FAULT, 'Exception dump')
    print(f'PASS: {len(ORDER)} boot checkpoints in order with \\DEBUG.ON, '
          f'{len(FAULT)} exception-dump lines, none without the file.')


if __name__ == '__main__':
    main()
