#!/usr/bin/env python3
"""Boot the ARM DOS ROM builds in QEMU `virt` and check them.

1. Network boot (EDK2 PXE over QEMU's TFTP, no disk attached): the generic
   ROM build's ARMDOS.EFI goes native through ACPI SPCR. A: is the ROM
   disk: files read, programs and ARM BASIC run, every kind of write is
   refused and leaves A: unchanged, and the RAM disk B: takes the writes.
2. The same file with ACPI hidden: EDK2 hands over a device tree and the
   kernel finds its UART through /chosen stdout-path.
3. U-Boot from NOR flash: the FIT image in QEMU's second flash bank, copied
   to RAM and started with bootm, as on a board with SPI flash. U-Boot gives
   no ACPI, so this is the device tree path again, under another firmware.
3b. A test build with extra programs: a raw sector write (IOCTL) to A: is
   refused and leaves no trace; an FCB open of a ROM file works.
4. The Pi ROM build's ARMDOS.EFI (no NATIVE.ON) network-boots and stays in
   UEFI firmware mode, with the same ROM disk checks.
5. The Pi 3 and Pi 4 images: the FAT LBA partition the Pi's boot ROM needs,
   the firmware, and the Pi ROM build as the only ARM DOS file.
6. Rebuilding a ROM disk gives the same bytes.
"""
import argparse
import os
from pathlib import Path
import re
import selectors
import shutil
import struct
import subprocess
import sys
import tempfile
import time


class Session:
    def __init__(self, args, qemu_args, prompt=b'A:\\>'):
        cmd = [args.qemu, '-machine', 'virt', '-cpu', 'cortex-a72', '-m', '256',
               '-nographic', '-monitor', 'none', '-no-reboot', *qemu_args]
        self.timeout = args.timeout
        self.prompt = prompt
        self.process = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.output = bytearray()

    def until(self, expected, timeout=None):
        deadline = time.monotonic() + (timeout or self.timeout)
        mark = len(self.output)
        while time.monotonic() < deadline:
            for key, _ in self.selector.select(timeout=0.1):
                chunk = os.read(key.fileobj.fileno(), 8192)
                if not chunk:
                    raise RuntimeError('QEMU exited: ' +
                                       self.output[-800:].decode(errors='replace'))
                self.output.extend(chunk)
            text = re.sub(rb'\x1b\[[0-9;=?]*[A-Za-z]', b'',
                          self.output[mark:]).replace(b'\r', b'')
            if expected in text:
                return text
        raise RuntimeError(f'timed out waiting for {expected!r}:\n' +
                           self.output[-1500:].decode(errors='replace'))

    def send(self, text, expected, timeout=None):
        self.process.stdin.write(text.encode() + b'\r')
        self.process.stdin.flush()
        return self.until(expected, timeout)

    def command(self, line, expected=b'', prompt=None, timeout=None):
        text = self.send(line, prompt or self.prompt, timeout)
        # Look for the answer after the echoed command line, not in the echo.
        text = text.split(b'\n', 1)[1] if b'\n' in text else b''
        if expected not in text:
            raise RuntimeError(f'{line!r}: expected {expected!r} in {text!r}')
        return text

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def boot_checks(s, platform):
    """The banner, then the ROM disk's behaviour. platform: expected text."""
    banner = s.until(b'A:\\>', 120)
    for expected in (platform,
                     b'Storage: native FAT12 driver over the built-in ROM disk (read-only)',
                     b'ROM system: drive A: is built in and read-only',
                     b'RAMDrive version 3.06 virtual disk B:',
                     b'ARM DOS Version 4.00'):       # AUTOEXEC.BAT runs VER
        if expected not in banner:
            raise RuntimeError(f'boot: expected {expected!r} in {banner!r}')
    if b'native AArch64 kernel' in platform and \
            b'Memory protection: kernel code read-only' not in banner:
        raise RuntimeError('native boot did not enable memory protection')
    if b'SELFTEST' in banner:
        raise RuntimeError('the write self-test ran on the read-only ROM disk')
    listing = s.command('dir', b'BASIC    EXE')
    for name in (b'COMMAND', b'DOSTEST', b'TESTDRV', b'BOOTAA64'):
        if name in listing:
            raise RuntimeError(f'{name!r} should not be on the ROM disk')
    s.command('vol', b'ARMDOS ROM')
    s.command('type README.TXT', b'Drive A: is built into ARMDOS.EFI')
    s.command('native', b'Native AArch64 program OK')
    s.command('find "FOR" PRIMES.BAS', b'FOR N = 2 TO 99')
    # Every kind of write is refused with an error, and A: stays as it was.
    for line, error in (('echo test>A:\\T.TXT', b'File/device error'),
                        ('md A:\\NEWDIR', b'File/device error'),
                        ('del A:\\README.TXT', b'File/device error'),
                        ('ren A:\\README.TXT X.TXT', b'Duplicate file name or file not found'),
                        ('copy A:\\PRIMES.BAS A:\\P2.BAS', b'File/device error'),
                        ('attrib +r A:\\README.TXT', b'File/device error')):
        s.command(line, error)
    after = s.command('dir A:\\')
    for name in (b'T        TXT', b'NEWDIR', b'X        TXT', b'P2       BAS'):
        if name in after:
            raise RuntimeError(f'{name!r} was written to the ROM disk')
    s.command('type A:\\README.TXT', b'Drive A: is built into ARMDOS.EFI')
    attributes = s.command('attrib A:\\README.TXT', b'A:\\README.TXT')
    if b' R ' in attributes or b'R  ' in attributes.split(b'A:\\README.TXT')[0]:
        raise RuntimeError('ATTRIB changed a file on the ROM disk')
    # The RAM disk takes the writes; ARM BASIC runs and saves there.
    s.command('echo rom-ok>B:\\L.TXT')
    s.command('type B:\\L.TXT', b'rom-ok')
    s.command('copy A:\\PRIMES.BAS B:\\', b'1 File(s) copied')
    s.command('basic primes', b' 89  97 \nOk', prompt=b'Ok\n')
    s.command('SAVE "A:\\T1"', b'disk error', prompt=b'Ok\n')
    s.command('SAVE "B:\\T1"', b'', prompt=b'Ok\n')
    s.command('SYSTEM')
    if b'T1       BAS' in s.command('dir A:\\'):
        raise RuntimeError('BASIC saved to the ROM disk')
    s.command('dir B:\\', b'T1       BAS')
    s.command('chkdsk A:', b'bytes total disk space')



def run(args, label, qemu_args, platform, before=None):
    s = Session(args, qemu_args)
    try:
        if before:
            before(s)
        boot_checks(s, platform)
    finally:
        s.close()
    print(f'PASS: {label}')


def pi_image_checks(build, pi_efi):
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
    efi = pi_efi.read_bytes()
    for model, start_file in (('3', 'start.elf'), ('4', 'start4.elf')):
        image = build / 'rom-pi' / f'armdos-rom-pi{model}.img'
        with image.open('rb') as f:
            mbr = f.read(512)
        if mbr[510:512] != b'\x55\xaa' or mbr[446 + 4] != 0x0c:
            raise RuntimeError(f'{image}: no FAT LBA (0Ch) partition for the Pi boot ROM')
        start = struct.unpack_from('<I', mbr, 446 + 8)[0]
        disk = f'{image}@@{start * 512}'
        listing = subprocess.run(['mdir', '-b', '-/', '-i', disk, '::'], env=env, check=True,
                                 capture_output=True, text=True).stdout.lower()
        for name in ('config.txt', 'rpi_efi.fd', start_file, 'efi/boot/bootaa64.efi',
                     'license.txt', 'broadcom.txt'):
            if '::/' + name not in listing:
                raise RuntimeError(f'{image}: {name} missing')
        for name in ('basic.exe', 'command', 'autoexec.bat', 'config.sys'):
            if name in listing:
                raise RuntimeError(f'{image}: {name} should be inside ARMDOS.EFI only')
        copied = subprocess.run(['mtype', '-i', disk, '::/EFI/BOOT/BOOTAA64.EFI'], env=env,
                                check=True, capture_output=True).stdout
        if copied != efi:
            raise RuntimeError(f'{image}: BOOTAA64.EFI is not the Pi ROM build')
        with tempfile.TemporaryDirectory(prefix='rom-test-fsck-') as name:
            volume = Path(name) / 'volume.img'
            volume.write_bytes(image.read_bytes()[start * 512:])
            fsck = subprocess.run(['fsck.fat', '-n', str(volume)], capture_output=True,
                                  text=True)
            if fsck.returncode:
                raise RuntimeError(f'{image}: fsck.fat:\n{fsck.stdout}{fsck.stderr}')
    print('PASS: Pi 3 and Pi 4 ROM images: firmware, FAT LBA partition, fsck clean, '
          'ROM build only')


def reproducible(build, native):
    with tempfile.TemporaryDirectory(prefix='rom-test-') as name:
        again = Path(name) / 'romdisk.img'
        subprocess.run([sys.executable, str(Path(__file__).with_name('romdisk.py')),
                        str(build / 'msdos-arm64.img'), str(again), '--target', 'generic',
                        *(['--native'] if native else [])],
                       check=True, stdout=subprocess.DEVNULL)
        built = build / 'rom-generic' / 'armdos-romdisk.img'
        if again.read_bytes() != built.read_bytes():
            raise RuntimeError('the ROM disk is not reproducible')
    print('PASS: the ROM disk rebuilds byte for byte')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', type=Path, default=Path('build'))
    parser.add_argument('--firmware', required=True, type=Path, help='EDK2 QEMU_EFI.fd')
    parser.add_argument('--uboot', required=True, type=Path, help='U-Boot qemu_arm64 u-boot.bin')
    parser.add_argument('--qemu', default='qemu-system-aarch64')
    parser.add_argument('--timeout', type=float, default=60)
    parser.add_argument('--generic-firmware-mode', action='store_true',
                        help='the generic build was made with GENERIC_NATIVE=0')
    parser.add_argument('--pi-native', action='store_true',
                        help='the Pi build was made with PI_NATIVE=1')
    args = parser.parse_args()
    generic = args.build / 'rom-generic'
    pi_efi = args.build / 'rom-pi' / 'ARMDOS.EFI'
    native = b'Platform: native AArch64 kernel (firmware exited; console UART at 0000000009000000, A: in ROM)'
    firmware = b'Platform: UEFI firmware services (ROM build; native mode not enabled'
    generic_mode = firmware if args.generic_firmware_mode else native
    generic_kind = 'firmware mode' if args.generic_firmware_mode else 'native'
    with tempfile.TemporaryDirectory(prefix='rom-test-tftp-') as name:
        tftp = Path(name)
        shutil.copyfile(generic / 'ARMDOS.EFI', tftp / 'ARMDOS.EFI')
        shutil.copyfile(pi_efi, tftp / 'ARMDOSPI.EFI')
        edk2 = ['-bios', str(args.firmware), '-boot', 'menu=on,splash-time=0']
        net = lambda f: ['-netdev', f'user,id=n0,tftp={tftp},bootfile={f}',
                         '-device', 'virtio-net-pci,netdev=n0,romfile=']
        run(args, f'network boot under EDK2 with ACPI: {generic_kind}, ROM disk A:',
            edk2 + net('ARMDOS.EFI'), generic_mode)
        run(args, f'device tree under EDK2 (ACPI hidden): {generic_kind}',
            ['-machine', 'acpi=off'] + edk2 + net('ARMDOS.EFI'), generic_mode)
        shutil.copyfile(args.build / 'rom-check' / 'ARMDOS.EFI', tftp / 'ROMCHECK.EFI')
        s = Session(args, edk2 + net('ROMCHECK.EFI'))
        try:
            s.until(b'A:\\>', 120)
            # Raw sector writes are refused and leave no trace in the cache.
            s.command('rompoke', b'write refused')
            listing = s.command('dir A:\\', b'ANSI     SYS')
            if b'ZZSI' in listing:
                raise RuntimeError('a refused sector write showed up on A:')
            s.command('romfcb', b'FCB open OK')
        finally:
            s.close()
        print('PASS: ROM disk: refused raw sector writes leave A: unchanged; FCB open works')
        run(args, 'Pi ROM build: ' + ('native' if args.pi_native else 'UEFI firmware mode'),
            edk2 + net('ARMDOSPI.EFI'), native if args.pi_native else firmware)

    def uboot(s):
        s.until(b'Hit any key to stop autoboot', 60)
        s.process.stdin.write(b' ')
        s.process.stdin.flush()
        s.until(b'=> ')
        s.send('cp.b 0x04000000 ${kernel_addr_r} 0x200000; bootm ${kernel_addr_r}',
               b'Verifying Hash Integrity ... sha256+ OK')
    flash = generic / 'armdos-rom-flash.bin'
    run(args, f'U-Boot from NOR flash (FIT, bootm): {generic_kind} (device tree)',
        ['-bios', str(args.uboot), '-net', 'none',
         '-drive', f'if=pflash,unit=1,format=raw,readonly=on,file={flash}'],
        generic_mode, before=uboot)
    pi_image_checks(args.build, pi_efi)
    reproducible(args.build, not args.generic_firmware_mode)


if __name__ == '__main__':
    main()
