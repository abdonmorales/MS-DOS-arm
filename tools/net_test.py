#!/usr/bin/env python3
"""Networking test: virtio-net, the E1h packet driver and TFTP.EXE under QEMU.

Boots the disk image on QEMU virt with a virtio-net device on user-mode
networking (slirp). TFTP.EXE fetches a 100 KiB pseudo-random file from
slirp's built-in TFTP server (read-only, octet only, blksize supported),
and talks to a small TFTP server in this script (reached through slirp's
10.0.2.2 -> host loopback mapping) for PUT, netascii and lost or duplicated
packets. After shutdown every file is checked on the host with mtools.
"""
import argparse
import hashlib
import os
from pathlib import Path
import random
import re
import selectors
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time


def pseudo_random(size, seed):
    return random.Random(seed).randbytes(size)


class TftpServer(threading.Thread):
    """Minimal RFC 1350/2348 server with deterministic fault injection.

    Faults (each fires once per transfer): RRQ drops the first DATA 3 and
    sends DATA 5 twice; WRQ drops the first ACK 2 and sends ACK 4 twice.
    Files are stored and served as raw bytes (no netascii translation), so
    the test sees exactly what went over the wire.
    """

    def __init__(self, root):
        super().__init__(daemon=True)
        self.root = Path(root)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(('127.0.0.1', 0))
        self.port = self.sock.getsockname()[1]
        self.sock.settimeout(0.2)
        self.stop = False
        self.log = []
        self.retransmissions = 0
        self.duplicates_seen = 0
        self.client_errors = []     # ERROR packets sent to the main port

    def run(self):
        while not self.stop:
            try:
                data, peer = self.sock.recvfrom(2048)
            except socket.timeout:
                continue
            if data[:2] == b'\0\5':
                self.client_errors.append(data)
                continue
            threading.Thread(target=self.transfer, args=(data, peer), daemon=True).start()

    @staticmethod
    def error(sock, peer, code, text):
        sock.sendto(struct.pack('!HH', 5, code) + text.encode() + b'\0', peer)

    def transfer(self, request, peer):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(('127.0.0.1', 0))
        sock.settimeout(1.0)
        try:
            opcode = struct.unpack('!H', request[:2])[0]
            fields = request[2:].split(b'\0')
            name, mode = fields[0].decode(), fields[1].decode().lower()
            options = dict(zip([f.decode().lower() for f in fields[2::2]],
                               [f.decode() for f in fields[3::2]]))
            self.log.append((opcode, name, mode, options))
            blksize = 512
            oack = b''
            if 'blksize' in options:
                blksize = min(int(options['blksize']), 1024)
                oack = struct.pack('!H', 6) + b'blksize\0' + str(blksize).encode() + b'\0'
            path = self.root / Path(name).name
            if name == 'SLOW.BIN':
                return                      # never answers: Ctrl-C test
            if opcode == 1:
                if not path.exists():
                    self.error(sock, peer, 1, 'File not found')
                    return
                self.send_file(sock, peer, path.read_bytes(), blksize, oack)
            elif opcode == 2:
                self.receive_file(sock, peer, path, blksize, oack)
        except (OSError, ValueError, IndexError) as error:
            self.log.append(('error', str(error)))
        finally:
            sock.close()

    def expect(self, sock, peer, want_opcode, want_block):
        for _ in range(6):
            try:
                data, source = sock.recvfrom(2048)
            except socket.timeout:
                return None
            if source != peer or len(data) < 4:
                continue
            opcode, block = struct.unpack('!HH', data[:4])
            if opcode == want_opcode and block == want_block:
                return data
            if opcode == want_opcode:
                self.duplicates_seen += 1
        return None

    def send_file(self, sock, peer, content, blksize, oack):
        if oack:
            for _ in range(5):
                sock.sendto(oack, peer)
                if self.expect(sock, peer, 4, 0) is not None:
                    break
            else:
                return
        dropped = duplicated = False
        block = 1
        while True:
            chunk = content[(block - 1) * blksize:block * blksize]
            packet = struct.pack('!HH', 3, block & 0xffff) + chunk
            for attempt in range(6):
                if block == 3 and not dropped:
                    dropped = True          # "lost": the client must time out
                else:
                    sock.sendto(packet, peer)
                    if block == 5 and not duplicated:
                        duplicated = True
                        sock.sendto(packet, peer)
                if attempt:
                    self.retransmissions += 1
                if self.expect(sock, peer, 4, block & 0xffff) is not None:
                    break
            else:
                return
            if len(chunk) < blksize:
                return
            block += 1

    def receive_file(self, sock, peer, path, blksize, oack):
        dropped = duplicated = False
        reply = oack or struct.pack('!HH', 4, 0)
        sock.sendto(reply, peer)
        received = bytearray()
        block = 1
        while True:
            data = self.expect(sock, peer, 3, block & 0xffff)
            if data is None:
                sock.sendto(reply, peer)    # our reply was lost: repeat it
                self.retransmissions += 1
                data = self.expect(sock, peer, 3, block & 0xffff)
                if data is None:
                    return
            received += data[4:]
            reply = struct.pack('!HH', 4, block & 0xffff)
            if block == 2 and not dropped:
                dropped = True
            else:
                sock.sendto(reply, peer)
                if block == 4 and not duplicated:
                    duplicated = True
                    sock.sendto(reply, peer)
            if len(data) - 4 < blksize:
                path.write_bytes(received)
                # Dally: answer a repeated last block.
                if self.expect(sock, peer, 3, block & 0xffff) is not None:
                    sock.sendto(reply, peer)
                return
            block += 1


def partition_of(image, directory):
    with image.open('rb') as disk:
        start = struct.unpack_from('<I', disk.read(512), 454)[0]
        disk.seek(start * 512)
        partition = Path(directory) / 'partition.img'
        partition.write_bytes(disk.read())
    return partition


def mread(partition, name):
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
    result = subprocess.run(['mtype', '-i', str(partition), '::/' + name],
                            capture_output=True, env=env)
    return result.stdout if result.returncode == 0 else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('image', type=Path)
    parser.add_argument('--firmware', required=True, type=Path)
    parser.add_argument('--qemu', default='qemu-system-aarch64')
    parser.add_argument('--timeout', type=float, default=40)
    parser.add_argument('--log', type=Path)
    args = parser.parse_args()
    began = time.monotonic()
    output = bytearray()
    random_data = pseudo_random(100 * 1024, 1350)
    put_data = pseudo_random(5 * 1024 + 300, 2347)   # 300-byte last block
    text = b'line one\r\nbare cr\rbare lf\nend\r\n'
    with tempfile.TemporaryDirectory(prefix='arm64-net-') as directory:
        directory = Path(directory)
        image = directory / 'test.img'
        shutil.copyfile(args.image, image)
        slirp_root = directory / 'slirp'
        slirp_root.mkdir()
        (slirp_root / 'RAND.BIN').write_bytes(random_data)
        own_root = directory / 'own'
        own_root.mkdir()
        (own_root / 'RAND.BIN').write_bytes(random_data)
        # Netascii as sent on the wire: CR NUL is a bare CR.
        (own_root / 'NETASCII.TXT').write_bytes(b'a\r\0b\r\nc\r\0\r\nend\r\n')
        server = TftpServer(own_root)
        server.start()
        # Files to send, put on the disk with mtools first.
        (directory / 'PUTDATA.BIN').write_bytes(put_data)
        (directory / 'TEXT.TXT').write_bytes(text)
        env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
        start = struct.unpack_from('<I', image.read_bytes()[:512], 454)[0]
        for name in ('PUTDATA.BIN', 'TEXT.TXT'):
            subprocess.run(['mcopy', '-i', f'{image}@@{start * 512}',
                            str(directory / name), '::/' + name], check=True, env=env)
        cmd = [args.qemu, '-machine', 'virt', '-cpu', 'cortex-a72', '-m', '256',
               '-bios', str(args.firmware), '-drive',
               f'file={image},format=raw,if=none,id=dos',
               '-device', 'virtio-blk-pci,drive=dos',
               '-netdev', f'user,id=n0,tftp={slirp_root}',
               '-device', 'virtio-net-pci,netdev=n0,romfile=',
               '-nographic', '-monitor', 'none', '-no-reboot',
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
                    return cleaned.replace(b'\r', b'')
                if b'CPU exception' in cleaned or b'Synchronous Exception' in cleaned:
                    raise RuntimeError('Fault: ' + output[-600:].decode(errors='replace'))
            raise RuntimeError('Timed out waiting for ' + repr(expected))

        checks = 0

        def command(line, *expected, absent=()):
            nonlocal checks
            process.stdin.write(line.encode() + b'\r')
            process.stdin.flush()
            text_out = until(b'A:\\>')
            for item in expected:
                if item not in text_out:
                    raise RuntimeError(f'{line}: missing {item!r} in\n'
                                       + text_out.decode(errors='replace'))
            for item in absent:
                if item in text_out:
                    raise RuntimeError(f'{line}: unexpected {item!r}')
            checks += 1
            return text_out

        port = server.port
        try:
            boot = until(b'A:\\>')
            if b'Platform: native AArch64 kernel' not in boot:
                raise RuntimeError('Not in native mode')
            command('tftp', b'TFTP [-i] host[:port] GET',
                    b'Network: Ethernet 52:54:00:12:34:56, link up')
            # slirp's server: 100 KiB in octet mode, with blksize.
            command('tftp -i 10.0.2.2 GET RAND.BIN',
                    f'Transfer successful: {len(random_data)} bytes'.encode())
            # slirp refuses netascii; the error packet is reported and the
            # partial local file removed.
            command('tftp 10.0.2.2 GET RAND.BIN ASCII.BIN', b'Error from server:')
            command('tftp -i 10.0.2.2 GET NOSUCH.BIN', b'Error from server:')
            command('dir ASCII.BIN', b'File not found')
            command('dir NOSUCH.BIN', b'File not found')
            # A failed GET leaves an existing destination alone.
            command('echo keep-me>KEEP.TXT')
            command('tftp -i 10.0.2.2 GET NOSUCH.BIN KEEP.TXT', b'Error from server:')
            command('type KEEP.TXT', b'keep-me')
            command('dir TFTP$$$.TMP', b'File not found')
            # Our server: a lost DATA 3 (timeout and retransmission) and a
            # duplicate DATA 5 (re-acknowledged, written once).
            command(f'tftp -i 10.0.2.2:{port} GET RAND.BIN COPY.BIN',
                    f'Transfer successful: {len(random_data)} bytes'.encode())
            # Ctrl-C while waiting: an ERROR to the server, temp file gone,
            # destination untouched.
            process.stdin.write(f'tftp -i 10.0.2.2:{port} GET SLOW.BIN KEEP.TXT\r'.encode())
            process.stdin.flush()
            time.sleep(1.5)
            process.stdin.write(b'\x03')
            process.stdin.flush()
            if b'Transfer cancelled.' not in until(b'A:\\>'):
                raise RuntimeError('Ctrl-C did not cancel the transfer')
            checks += 1
            command('type KEEP.TXT', b'keep-me')
            command('dir TFTP$$$.TMP', b'File not found')
            command(f'tftp 10.0.2.2:{port} GET NETASCII.TXT TEXTIN.TXT',
                    b'Transfer successful: 14 bytes')
            # PUT with a lost ACK 2 and a duplicate ACK 4.
            command(f'tftp -i 10.0.2.2:{port} PUT PUTDATA.BIN UP.BIN',
                    f'Transfer successful: {len(put_data)} bytes'.encode())
            command(f'tftp 10.0.2.2:{port} PUT TEXT.TXT TEXT.NET', b'Transfer successful')
            command('tftp -i 10.0.2.300 GET X', b'Invalid host')
            command('set IP=10.0.3.15')
            command('set GATEWAY=10.0.3.2')
            command('tftp -i 10.0.2.2 GET RAND.BIN', b'No ARP reply from 10.0.3.2')
            command('set IP=')
            command('set GATEWAY=')
        finally:
            selector.close()
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            server.stop = True
            if args.log:
                args.log.write_bytes(output)
        partition = partition_of(image, directory)
        failures = []
        for name, want in [('RAND.BIN', random_data), ('COPY.BIN', random_data),
                           ('TEXTIN.TXT', b'a\rb\r\nc\r\r\nend\r\n')]:
            got = mread(partition, name)
            if got != want:
                failures.append(f'{name}: {len(got or b"")} bytes, sha256 '
                                f'{hashlib.sha256(got or b"").hexdigest()[:16]}')
        up = own_root / 'UP.BIN'
        if not up.exists() or up.read_bytes() != put_data:
            failures.append('UP.BIN on the server differs')
        net_text = b'line one\r\nbare cr\r\0bare lf\r\nend\r\n'
        if not (own_root / 'TEXT.NET').exists() or (own_root / 'TEXT.NET').read_bytes() != net_text:
            failures.append('TEXT.NET (netascii PUT) differs')
        if not any(packet[2:4] == b'\0\0' and b'Cancelled' in packet
                   for packet in server.client_errors):
            failures.append('no ERROR packet reached the server after Ctrl-C')
        if mread(partition, 'KEEP.TXT') != b'keep-me\r\n':
            failures.append('KEEP.TXT changed')
        if server.retransmissions < 2:
            failures.append(f'fault injection did not trigger retransmissions '
                            f'({server.retransmissions})')
        fsck = subprocess.run(['fsck.fat', '-n', str(partition)], capture_output=True, text=True)
        if fsck.returncode:
            failures.append('fsck.fat: ' + fsck.stdout + fsck.stderr)
        if failures:
            raise SystemExit('FAIL: ' + '; '.join(failures))
        print(f'PASS: virtio-net + TFTP: {checks} console checks, 100 KiB GET verified '
              f'by sha256 ({hashlib.sha256(random_data).hexdigest()[:16]}), PUT, netascii, '
              f'{server.retransmissions} retransmissions recovered, '
              f'{time.monotonic() - began:.1f}s.')


if __name__ == '__main__':
    main()
