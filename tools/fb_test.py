#!/usr/bin/env python3
"""Check the framebuffer console (src/fbcon.S) by reading the screen back.

1. QEMU virt with `-device ramfb` (EDK2 publishes a GOP for it): boot the
   disk natively, type commands on the serial line, take `screendump`s over
   QMP and decode every character cell against the font bitmaps in
   src/font8x16.S, so the test sees the text, its colours and the cursor.
2. QEMU raspi3b: tests/pi/fbtest.S allocates a framebuffer through the
   VideoCore mailbox and draws a fixed screen, decoded the same way.
"""
import argparse
import json
from pathlib import Path
import os
import re
import selectors
import shutil
import socket
import subprocess
import tempfile
import time

SOURCE = Path(__file__).resolve().parent.parent
CGA = [0x000000, 0x0000aa, 0x00aa00, 0x00aaaa, 0xaa0000, 0xaa00aa, 0xaa5500, 0xaaaaaa,
       0x555555, 0x5555ff, 0x55ff55, 0x55ffff, 0xff5555, 0xff55ff, 0xffff55, 0xffffff]
GREY, BLACK = 0xaaaaaa, 0x000000


def load_font():
    """Glyph rows (16 bytes) of the 256 characters, as assembled."""
    rows = []
    for line in (SOURCE / 'src/font8x16.S').read_text().splitlines():
        if line.strip().startswith('.byte'):
            rows.append(tuple(int(v, 16) for v in re.findall(r'0x([0-9a-f]{2})', line)))
    if len(rows) != 256 or any(len(r) != 16 for r in rows):
        raise SystemExit('src/font8x16.S: expected 256 glyphs of 16 rows')
    lookup = {}
    # Printable ASCII wins where another glyph has the same bitmap.
    for code in list(range(0x20, 0x7f)) + list(range(256)):
        lookup.setdefault(rows[code], (chr(code) if 0x20 <= code < 0x7f else f'<{code:02x}>',
                                       False))
        cursor = rows[code][:14] + (0xff, 0xff)
        lookup.setdefault(cursor, lookup[rows[code]][:1] + (True,))
    return lookup


FONT = load_font()


class Screen:
    """A decoded PPM screendump: text, colours and the cursor position."""

    def __init__(self, path):
        data = path.read_bytes()
        fields = re.match(rb'P6\s+(\d+)\s+(\d+)\s+(\d+)\s', data)
        if not fields or fields.group(3) != b'255':
            raise RuntimeError(f'{path}: not an 8-bit PPM')
        self.width, self.height = int(fields.group(1)), int(fields.group(2))
        pixels = data[fields.end():]
        # The layout fbcon_setup computes.
        self.cols, self.rows = min(80, self.width // 8), min(25, self.height // 16)
        ox = ((self.width - self.cols * 8) // 2) & ~1
        oy = (self.height - self.rows * 16) // 2
        self.text, self.fg, self.bg, self.cursor, self.bad = [], [], [], None, []

        def pixel(x, y):
            i = (y * self.width + x) * 3
            return pixels[i] << 16 | pixels[i + 1] << 8 | pixels[i + 2]
        border = {pixel(x, y) for x in range(self.width) for y in range(0, oy)}
        border |= {pixel(x, y) for x in range(ox) for y in range(self.height)}
        if border - {BLACK}:
            raise RuntimeError('pixels outside the text area are not black')
        for row in range(self.rows):
            line, fgs, bgs = [], [], []
            for col in range(self.cols):
                cell = [[pixel(ox + col * 8 + x, oy + row * 16 + y) for x in range(8)]
                        for y in range(16)]
                char, fg, bg, cursor = self.decode(cell)
                if char is None:
                    self.bad.append((row, col))
                    char = '\0'
                if cursor:
                    self.cursor = (row, col)
                line.append(char)
                fgs.append(fg)
                bgs.append(bg)
            self.text.append(''.join(line))
            self.fg.append(fgs)
            self.bg.append(bgs)

    @staticmethod
    def decode(cell):
        colours = sorted({c for line in cell for c in line})
        if len(colours) == 1:
            return ' ', None, colours[0], False
        if len(colours) != 2:
            return None, None, None, False
        found = []
        for fg, bg in (colours, colours[::-1]):
            bits = tuple(sum(0x80 >> x for x in range(8) if line[x] == fg) for line in cell)
            if bits in FONT:
                found.append((FONT[bits], fg, bg))
        if not found:
            return None, None, None, False
        # Prefer ASCII, then a plain glyph over a cursor reading.
        found.sort(key=lambda f: (len(f[0][0]) > 1, f[0][1]))
        (char, cursor), fg, bg = found[0]
        return char, fg, bg, cursor

    def lines(self):
        return [line.rstrip() for line in self.text]

    def find(self, text):
        for row, line in enumerate(self.text):
            col = line.find(text)
            if col >= 0:
                return row, col
        raise RuntimeError(f'{text!r} is not on the screen:\n' + self.dump())

    def colours(self, text):
        """(foreground, background) of every cell of the first text match."""
        row, col = self.find(text)
        return [(self.fg[row][c], self.bg[row][c]) for c in range(col, col + len(text))]

    def dump(self):
        return '\n'.join(f'{n:2} |{line}|' for n, line in enumerate(self.lines()))


def expect(condition, message, screen):
    if not condition:
        raise RuntimeError(message + '\n' + screen.dump())


def check_clean(screen):
    expect(not screen.bad, f'cells that are not a font glyph: {screen.bad[:8]}', screen)


class Qmp:
    def __init__(self, path, deadline):
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX)
                self.sock.connect(str(path))
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise RuntimeError('QMP socket did not appear')
                time.sleep(0.05)
        self.file = self.sock.makefile('rw')
        self.read()                                     # greeting
        self.command('qmp_capabilities')

    def read(self):
        while True:
            line = self.file.readline()
            if not line:
                raise RuntimeError('QMP connection closed')
            reply = json.loads(line)
            if 'event' not in reply:
                return reply

    def command(self, name, **arguments):
        self.file.write(json.dumps({'execute': name, 'arguments': arguments}) + '\n')
        self.file.flush()
        reply = self.read()
        if 'error' in reply:
            raise RuntimeError(f'QMP {name}: {reply["error"]}')
        return reply['return']

    def screen(self, path):
        self.command('screendump', filename=str(path))
        return Screen(path)


def start(cmd, directory, name):
    qmp = directory / f'{name}.qmp'
    process = subprocess.Popen(cmd + ['-qmp', f'unix:{qmp},server=on,wait=off'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT)
    return process, Qmp(qmp, time.monotonic() + 10)


def stop(process):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def test_virt(args, directory):
    image = directory / 'test.img'
    shutil.copyfile(args.image, image)
    cmd = [args.qemu, '-machine', 'virt', '-cpu', 'cortex-a72', '-m', '256',
           '-bios', str(args.firmware), '-drive', f'file={image},format=raw,if=none,id=dos',
           '-device', 'virtio-blk-pci,drive=dos', '-device', 'ramfb', '-display', 'none',
           '-serial', 'stdio', '-monitor', 'none', '-net', 'none', '-no-reboot',
           '-boot', 'menu=on,splash-time=0']
    process, qmp = start(cmd, directory, 'virt')
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    output = bytearray()
    shot = iter(range(1000))

    def until(expected):
        deadline = time.monotonic() + args.timeout
        mark = len(output)
        while time.monotonic() < deadline:
            for key, _ in selector.select(timeout=0.1):
                chunk = os.read(key.fileobj.fileno(), 8192)
                if not chunk:
                    raise RuntimeError('QEMU exited:\n' + output[-400:].decode(errors='replace'))
                output.extend(chunk)
            if expected in re.sub(rb'\x1b\[[0-9;=?]*[A-Za-z]', b'', output[mark:]):
                return
        raise RuntimeError(f'timed out waiting for {expected!r}')

    def command(line, prompt=b'A:\\>'):
        process.stdin.write(line.encode() + b'\r')
        process.stdin.flush()
        until(prompt)
        time.sleep(0.2)             # the prompt's last byte reaches the screen too
        screen = qmp.screen(directory / f'shot{next(shot)}.ppm')
        check_clean(screen)
        return screen

    checks = 0
    try:
        until(b'A:\\>')
        time.sleep(0.2)
        screen = qmp.screen(directory / 'boot.ppm')
        check_clean(screen)
        expect((screen.cols, screen.rows) == (80, 25), 'expected an 80x25 grid', screen)
        lines = screen.lines()
        expect('AUTOEXEC.BAT ran' in lines, 'boot output missing on the screen', screen)
        last = max(n for n, line in enumerate(lines) if line)
        expect(lines[last] == 'A:\\>', 'the prompt is not the last line', screen)
        expect(screen.cursor == (last, 4), f'cursor at {screen.cursor}, not after the prompt',
               screen)
        expect(set(c for c, _ in screen.colours('A:\\>')) == {GREY}, 'prompt not grey', screen)
        checks += 1

        screen = command('ver')
        row, _ = screen.find('ARM DOS Version 4.00 (AArch64)')
        expect(screen.lines()[row - 1] == 'A:\\>ver', 'the typed command is not echoed', screen)
        checks += 1

        # DIR scrolls the screen: the listing ends just above the prompt.
        screen = command('dir')
        lines = screen.lines()
        expect(lines[24] == 'A:\\>' and screen.cursor == (24, 4),
               'after DIR the prompt is not on the bottom line', screen)
        expect(any(line.startswith('ARMTEST  TXT') for line in lines), 'DIR entry missing',
               screen)
        expect('bytes free' in lines[23], 'DIR summary not above the prompt', screen)
        checks += 1

        # Line editing: backspace and the editor's ESC[D / ESC[K redraws.
        screen = command('echo abcX\bd')
        lines = screen.lines()
        expect(lines[22:25] == ['A:\\>echo abcd', 'abcd', 'A:\\>'],
               'edited command line wrong on the screen', screen)
        checks += 1

        # ANSI colours through ANSI.SYS: bold yellow on blue, red, reverse.
        command('prompt $e[1;33;44mHI$e[0m$e[31mRED$e[7mREV$e[0m$p$g')
        screen = command('rem', prompt=b'REVA:\\>')
        # The first match is the prompt line printed before REM was typed.
        expect(screen.colours('HIREDREV') == [(CGA[14], CGA[1])] * 2 + [(CGA[4], BLACK)] * 3
               + [(BLACK, CGA[4])] * 3, 'bold yellow on blue, red, then reverse video',
               screen)
        expect(screen.lines()[24] == 'HIREDREVA:\\>', 'coloured prompt line', screen)
        checks += 1
        command('prompt $p$g')

        # CLS: ESC[2J and ESC[H clear the screen and home the cursor.
        screen = command('cls')
        expect(screen.lines() == ['A:\\>'] + [''] * 24 and screen.cursor == (0, 4),
               'CLS did not clear the screen', screen)
        checks += 1

        # Cursor save/restore and positioning, as ANSI.SYS passes them on.
        screen = command('prompt $e[s$e[10;30Hat 10,30$e[u$p$g')
        expect(screen.lines()[9] == ' ' * 29 + 'at 10,30', 'ESC[r;cH misplaced text', screen)
        expect(screen.lines()[1] == 'A:\\>' and screen.cursor == (1, 4),
               'ESC[u did not restore the cursor', screen)
        checks += 1
        command('prompt $p$g')
    finally:
        selector.close()
        stop(process)
    print(f'PASS: framebuffer console on QEMU virt ramfb ({checks} screen checks, '
          f'{screen.width}x{screen.height}, every cell a font glyph).')


def test_pi(args, directory):
    log = directory / 'pi.log'
    cmd = [args.qemu, '-M', 'raspi3b', '-m', '1G', '-display', 'none', '-monitor', 'none',
           '-kernel', str(args.pi_kernel), '-serial', f'file:{log}']
    process, qmp = start(cmd, directory, 'pi')
    try:
        deadline = time.monotonic() + args.timeout
        text = ''
        while time.monotonic() < deadline:
            text = log.read_text(errors='replace') if log.exists() else ''
            if 'FBTEST READY' in text or 'FBTEST FAIL' in text:
                break
            time.sleep(0.1)
        if 'FBTEST READY' not in text:
            raise RuntimeError('Pi framebuffer test did not finish:\n' + text)
        screen = qmp.screen(directory / 'pi.ppm')
    finally:
        stop(process)
    check_clean(screen)
    expected = [f'Line {n:02}' for n in range(8, 31)] + ['Raspberryx GREENPi 3E', 'era']
    expected[2] = 'Line 10            moved'
    expect((screen.width, screen.height) == (640, 480), 'expected a 640x480 framebuffer',
           screen)
    expect(screen.lines() == expected, 'Pi screen differs from the expected text', screen)
    expect(screen.colours('GREEN') == [(CGA[10], BLACK)] * 5, 'bold green', screen)
    expect(screen.colours('Pi 3') == [(GREY, BLACK)] * 2 + [(None, BLACK), (GREY, BLACK)],
           'normal text after ESC[0m', screen)
    expect(screen.fg[23][20] == GREY and screen.bg[23][20] == CGA[1], 'ESC[44;37m: grey on blue',
           screen)
    expect(screen.cursor == (23, 20), f'cursor at {screen.cursor}', screen)
    print('PASS: Pi mailbox framebuffer on QEMU raspi3b (640x480, scrolling, colours, '
          'cursor moves, erase).')


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('image', type=Path)
    parser.add_argument('--firmware', required=True, type=Path)
    parser.add_argument('--pi-kernel', type=Path, help='build/fbtest.bin (raspi3b test)')
    parser.add_argument('--qemu', default='qemu-system-aarch64')
    parser.add_argument('--timeout', type=float, default=45)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='arm64-fb-') as name:
        directory = Path(name)
        try:
            test_virt(args, directory)
            if args.pi_kernel:
                test_pi(args, directory)
        except RuntimeError as error:
            raise SystemExit(f'FAIL: {error}')


if __name__ == '__main__':
    main()
