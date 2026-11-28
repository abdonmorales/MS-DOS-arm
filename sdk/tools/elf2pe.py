#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Convert an ARM DOS C program (ELF linked with sdk/link.ld and
--emit-relocs) into the AArch64 PE32+ image the kernel loads.

Unlike tools/pe.py (assembly programs, which are fully position independent),
C code keeps absolute pointers in data: string tables, function pointer
arrays, static pointer initialisers. The linker resolves those for image base
0 and, with --emit-relocs, records each as R_AARCH64_ABS64 in the output. Each
becomes an IMAGE_REL_BASED_DIR64 fixup; the kernel adds the load address.
Any other absolute relocation (ABS32, MOVW_UABS) cannot be fixed up by the
loader and is rejected, with the symbol named.
"""
import argparse
from pathlib import Path
import struct
import sys

SHT_SYMTAB, SHT_RELA, SHT_NOBITS = 2, 4, 8
SHF_ALLOC, SHF_EXECINSTR = 2, 4
R_AARCH64_NONE = 0
R_AARCH64_ABS64 = 257
# Relocations that hold a full or partial absolute address: not relocatable.
ABSOLUTE = {258: 'ABS32', 259: 'ABS16', 263: 'MOVW_UABS_G0', 264: 'MOVW_UABS_G0_NC',
            265: 'MOVW_UABS_G1', 266: 'MOVW_UABS_G1_NC', 267: 'MOVW_UABS_G2',
            268: 'MOVW_UABS_G2_NC', 269: 'MOVW_UABS_G3', 1027: 'RELATIVE',
            1025: 'GLOB_DAT', 1026: 'JUMP_SLOT'}
TEXT_RVA = 0x1000
SHN_ABS = 0xfff1


def align(value, boundary):
    return (value + boundary - 1) & -boundary


class Elf:
    def __init__(self, data):
        if data[:4] != b'\x7fELF' or data[4] != 2 or data[5] != 1:
            raise SystemExit('not a little-endian ELF64 file')
        (self.type, machine, _, self.entry, _, shoff, _, _, _, _, shentsize, shnum,
         shstrndx) = struct.unpack_from('<HHIQQQIHHHHHH', data, 16)
        if machine != 183:
            raise SystemExit('not an AArch64 ELF file')
        self.data = data
        self.sections = []
        for i in range(shnum):
            fields = struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * shentsize)
            self.sections.append(dict(zip(
                ('name', 'type', 'flags', 'addr', 'offset', 'size', 'link', 'info',
                 'align', 'entsize'), fields)))
        names = self.sections[shstrndx]
        for s in self.sections:
            s['name'] = self.cstring(names['offset'] + s['name'])

    def cstring(self, offset):
        return self.data[offset:self.data.index(b'\0', offset)].decode()

    def symbols(self):
        """(name, value, shndx) for the symbol table."""
        result = []
        for s in self.sections:
            if s['type'] != SHT_SYMTAB:
                continue
            strtab = self.sections[s['link']]
            for i in range(s['size'] // 24):
                name, _, _, shndx, value, _ = struct.unpack_from(
                    '<IBBHQQ', self.data, s['offset'] + i * 24)
                result.append((self.cstring(strtab['offset'] + name), value, shndx))
        return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('elf', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    elf = Elf(args.elf.read_bytes())
    symbols = elf.symbols()
    by_name = {name: value for name, value, _ in symbols if name}
    for needed in ('_start', '__data_start', '__image_end'):
        if needed not in by_name:
            raise SystemExit(f'{args.elf}: missing symbol {needed} (link with sdk/link.ld)')
    data_rva = by_name['__data_start']
    image_end = align(by_name['__image_end'], 16)

    # The memory image from TEXT_RVA up to the last initialised byte.
    alloc = [s for s in elf.sections if s['flags'] & SHF_ALLOC and s['size']]
    for s in alloc:
        if s['addr'] < TEXT_RVA or s['addr'] + s['size'] > image_end:
            raise SystemExit(f'section {s["name"]} lies outside the image '
                             f'({s["addr"]:#x}); is it named in sdk/link.ld?')
    loaded = [s for s in alloc if s['type'] != SHT_NOBITS]
    file_end = max([s['addr'] + s['size'] for s in loaded] + [data_rva])
    image = bytearray(file_end - TEXT_RVA)
    for s in loaded:
        start = s['addr'] - TEXT_RVA
        image[start:start + s['size']] = elf.data[s['offset']:s['offset'] + s['size']]

    # Relocations against loaded sections.
    syms_by_section = {}
    for s in elf.sections:
        if s['type'] == SHT_SYMTAB:
            syms_by_section = s
    fixups = []
    problems = []
    for s in elf.sections:
        if s['type'] != SHT_RELA:
            continue
        target = elf.sections[s['info']]
        if not target['flags'] & SHF_ALLOC:
            continue    # debug information
        for i in range(s['size'] // 24):
            offset, info, _addend = struct.unpack_from('<QQq', elf.data, s['offset'] + i * 24)
            kind, symbol = info & 0xffffffff, info >> 32
            sym_name, sym_shndx = '?', 0
            if syms_by_section and symbol:
                name, _, _, shndx, _, _ = struct.unpack_from(
                    '<IBBHQQ', elf.data, syms_by_section['offset'] + symbol * 24)
                strtab = elf.sections[syms_by_section['link']]
                sym_name, sym_shndx = elf.cstring(strtab['offset'] + name), shndx
            if kind == R_AARCH64_ABS64:
                if sym_shndx == SHN_ABS:
                    continue    # an absolute constant, not an address
                if target['type'] == SHT_NOBITS:
                    problems.append(f'ABS64 in .bss at {offset:#x}')
                    continue
                if offset & 7:
                    problems.append(f'unaligned ABS64 at {offset:#x} ({sym_name})')
                fixups.append(offset)
            elif kind in ABSOLUTE:
                problems.append(f'{ABSOLUTE[kind]} relocation at {offset:#x} '
                                f'against {sym_name or "a section"} in {target["name"]}')
    if problems:
        raise SystemExit(f'{args.elf}: not loadable at an arbitrary address:\n  ' +
                         '\n  '.join(problems[:20]) +
                         '\n(compile with -fno-pic -mcmodel=small; no -mcmodel=large)')
    # GOT slots the linker filled in itself (weak references in non-PIC
    # code) carry no output relocation: every nonzero slot is an address.
    for s in elf.sections:
        if s['name'] in ('.got', '.got.plt') and s['type'] != SHT_NOBITS:
            for slot in range(0, s['size'] - 7, 8):
                rva = s['addr'] + slot
                if struct.unpack_from('<Q', image, rva - TEXT_RVA)[0]:
                    fixups.append(rva)
    fixups = sorted(set(fixups))

    # .reloc: one block per 4 KiB page, DIR64 entries, padded to 4 bytes.
    reloc = bytearray()
    pages = {}
    for rva in fixups:
        pages.setdefault(rva & ~0xfff, []).append(rva & 0xfff)
    for page, offsets in sorted(pages.items()):
        entries = [(10 << 12) | o for o in offsets]
        if len(entries) % 2:
            entries.append(0)   # IMAGE_REL_BASED_ABSOLUTE padding
        reloc += struct.pack('<II', page, 8 + 2 * len(entries))
        reloc += struct.pack(f'<{len(entries)}H', *entries)
    if not reloc:
        reloc = bytearray(struct.pack('<IIHH', 0, 12, 0, 0))  # empty, valid block

    code = image[:data_rva - TEXT_RVA]
    data = image[data_rva - TEXT_RVA:]
    code_size = align(len(code), 512)
    data_size = align(max(len(data), 1), 512)
    reloc_rva = align(image_end, 4096)
    reloc_raw = align(len(reloc), 512)
    size_of_image = reloc_rva + align(len(reloc), 4096)
    if size_of_image > 0x1000000:
        raise SystemExit('image larger than the 16 MiB the loader accepts')
    entry = by_name['_start']

    headers = bytearray(512)
    headers[:2] = b'MZ'
    struct.pack_into('<I', headers, 0x3c, 0x80)
    headers[0x80:0x84] = b'PE\0\0'
    struct.pack_into('<HHIIIHH', headers, 0x84, 0xaa64, 3, 0, 0, 0, 240, 0x0022)
    optional = 0x98
    struct.pack_into('<HBBIIIIIQII', headers, optional,
                     0x20b, 0, 0, code_size, data_size + reloc_raw,
                     image_end - file_end if image_end > file_end else 0,
                     entry, TEXT_RVA, 0, 4096, 512)
    struct.pack_into('<HHHHHH', headers, optional + 40, 0, 0, 0, 0, 2, 0)
    struct.pack_into('<IIIIHH', headers, optional + 52,
                     0, size_of_image, 512, 0, 10, 0x0040)
    struct.pack_into('<QQQQII', headers, optional + 72,
                     0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
    struct.pack_into('<II', headers, optional + 112 + 5 * 8, reloc_rva, len(reloc))
    sections = optional + 240
    struct.pack_into('<8sIIIIIIHHI', headers, sections,
                     b'.text', data_rva - TEXT_RVA, TEXT_RVA, code_size,
                     512, 0, 0, 0, 0, 0x60000020)
    struct.pack_into('<8sIIIIIIHHI', headers, sections + 40,
                     b'.data', image_end - data_rva, data_rva, data_size,
                     512 + code_size, 0, 0, 0, 0, 0xc0000040)
    struct.pack_into('<8sIIIIIIHHI', headers, sections + 80,
                     b'.reloc', len(reloc), reloc_rva, reloc_raw,
                     512 + code_size + data_size, 0, 0, 0, 0, 0x42000040)
    args.output.write_bytes(headers + code.ljust(code_size, b'\0') +
                            data.ljust(data_size, b'\0') + reloc.ljust(reloc_raw, b'\0'))
    print(f'{args.output}: AArch64 PE32+ ARM DOS program, {len(fixups)} fixups, '
          f'image {size_of_image // 1024} KiB')


if __name__ == '__main__':
    sys.exit(main())
