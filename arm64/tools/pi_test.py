#!/usr/bin/env python3
"""Run tests/pi/sdtest.S (the Pi 3 SD and UART drivers) on QEMU raspi3b.

Two card sizes cover both addressing modes: the 64 MiB test image is a
standard-capacity (byte-addressed) card and a 4 GiB sparse copy is SDHC
(block-addressed).
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def run(qemu, kernel, card, directory):
    pl011, mini = directory / 'pl011.log', directory / 'mini.log'
    cmd = [qemu, '-M', 'raspi3b', '-m', '1G', '-display', 'none', '-monitor', 'none',
           '-kernel', str(kernel), '-drive', f'file={card},format=raw,if=sd',
           '-serial', f'file:{pl011}', '-serial', f'file:{mini}']
    process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            text = pl011.read_text(errors='replace') if pl011.exists() else ''
            if 'SDTEST PASS' in text or 'SDTEST FAIL' in text:
                break
            time.sleep(0.2)
    finally:
        process.terminate()
        process.wait(timeout=5)
    text = pl011.read_text(errors='replace') if pl011.exists() else ''
    if 'SDTEST PASS' not in text:
        raise SystemExit('Pi driver test failed:\n' + text)
    if 'MU OK' not in mini.read_text(errors='replace'):
        raise SystemExit('Pi mini UART output missing')
    return text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('kernel', type=Path)
    parser.add_argument('image', type=Path)
    parser.add_argument('--qemu', default='qemu-system-aarch64')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='arm64-pi-') as name:
        directory = Path(name)
        card = directory / 'sdsc.img'
        shutil.copyfile(args.image, card)
        text = run(args.qemu, args.kernel, card, directory)
        if 'block addressed' in text:
            raise SystemExit('64 MiB card unexpectedly block addressed')
        big = directory / 'sdhc.img'
        with args.image.open('rb') as source, big.open('wb') as output:
            output.write(source.read(1 << 20))
            output.truncate(4 << 30)
        for log in directory.glob('*.log'):
            log.unlink()
        text = run(args.qemu, args.kernel, big, directory)
        if 'block addressed' not in text:
            raise SystemExit('4 GiB card not block addressed')
    print('PASS: Pi 3 SDHCI driver (SDSC and SDHC cards) and mini UART on QEMU raspi3b.')


if __name__ == '__main__':
    main()
