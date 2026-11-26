#!/usr/bin/env python3
"""Wrap a PIC AArch64 flat image in the UEFI PE32+ application format."""
import argparse
from pathlib import Path
import struct
import subprocess


def align(value, boundary):
    return (value + boundary - 1) & -boundary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--nm', default='aarch64-linux-gnu-nm')
    parser.add_argument('elf', type=Path)
    parser.add_argument('binary', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    symbols = {}
    for line in subprocess.check_output([args.nm, '-n', args.elf], text=True).splitlines():
        fields = line.split()
        if len(fields) == 3:
            symbols[fields[2]] = int(fields[0], 16)
    payload = args.binary.read_bytes()
    image_end = symbols['__image_end']
    reloc_rva = align(image_end, 4096)
    data_rva = symbols['__data_start']
    code = payload[:data_rva - 0x1000]
    data = payload[data_rva - 0x1000:]
    code_size = align(len(code), 512)
    data_size = align(len(data), 512)
    headers = bytearray(512)
    headers[:2] = b'MZ'
    struct.pack_into('<I', headers, 0x3c, 0x80)
    headers[0x80:0x84] = b'PE\0\0'
    struct.pack_into('<HHIIIHH', headers, 0x84,
                     0xaa64, 3, 0, 0, 0, 240, 0x0022)
    optional = 0x98
    struct.pack_into('<HBBIIIIIQII', headers, optional,
                     0x20b, 0, 0, code_size, data_size + 512, image_end - symbols['__file_end'],
                     symbols['efi_main'], 0x1000, 0, 4096, 512)
    struct.pack_into('<HHHHHH', headers, optional + 40, 0, 0, 0, 0, 2, 0)
    struct.pack_into('<IIIIHH', headers, optional + 52,
                     0, reloc_rva + 4096, 512, 0, 10, 0x0040)
    struct.pack_into('<QQQQII', headers, optional + 72,
                     0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
    # A relocation block of IMAGE_REL_BASED_ABSOLUTE entries. Code/data are
    # position-independent; advertising relocation permits any firmware base.
    struct.pack_into('<II', headers, optional + 112 + 5 * 8, reloc_rva, 12)
    sections = optional + 240
    struct.pack_into('<8sIIIIIIHHI', headers, sections,
                     b'.text', data_rva - 0x1000, 0x1000, code_size,
                     512, 0, 0, 0, 0, 0x60000020)
    struct.pack_into('<8sIIIIIIHHI', headers, sections + 40,
                     b'.data', image_end - data_rva, data_rva, data_size,
                     512 + code_size, 0, 0, 0, 0, 0xc0000040)
    struct.pack_into('<8sIIIIIIHHI', headers, sections + 80,
                     b'.reloc', 12, reloc_rva, 512, 512 + code_size + data_size,
                     0, 0, 0, 0, 0x42000040)
    relocations = struct.pack('<IIHH', 0, 12, 0, 0).ljust(512, b'\0')
    args.output.write_bytes(headers + code.ljust(code_size, b'\0') +
                            data.ljust(data_size, b'\0') + relocations)
    print(f'{args.output}: ARM64 UEFI application, entry RVA {symbols["efi_main"]:#x}')


if __name__ == '__main__':
    main()
