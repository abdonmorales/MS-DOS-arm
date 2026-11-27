#!/usr/bin/env python3
"""Build COUNTRY.SYS from data/country/MKCNTRY.ASM.

MKCNTRY.ASM was an x86 program in MS-DOS 4.0 whose data segment is the
COUNTRY.SYS file; running it wrote that segment out. Only the data segment
is kept in this repository (with MKCNTRY.INC and COPYRIGH.INC beside it). This tool assembles just the data
segment (labels, DB/DW/DD, EQU and the CTRYSTR/CTRYDAT/CTABLE/CINFO
structures of MKCNTRY.INC) so the image carries the same file, byte for byte
in layout, without an x86 toolchain.
"""
import argparse
import re
from pathlib import Path

# Structure fields: (size in bytes, default).
STRUCTS = {
    'ctrystr': [(2, 0)] * 7,
    'ctrydat': [(2, 0), (1, 0), (1, 0), (2, 0), (2, 0)],
    'ctable': [(1, 0xFF), (7, b'CTYINFO'), (2, 'CINFOSIZE')],
    'cinfo': ([(2, 0)] * 3 + [(1, 0)] * 13 + [(1, 0)] * 3 +
              [(4, 0), (1, 0), (1, 0)] + [(2, 0)] * 5),
}
MACROS = {'ctryent': 'ctrystr'}


def struct_size(name):
    return sum(size for size, _ in STRUCTS[name])


def strip_comment(line):
    quote = None
    for i, c in enumerate(line):
        if quote:
            if c == quote:
                quote = None
        elif c in '\'"':
            quote = c
        elif c == ';':
            return line[:i]
    return line


def split_top(text, sep=','):
    parts, depth, quote, cur = [], 0, None, ''
    for c in text:
        if quote:
            cur += c
            if c == quote:
                quote = None
            continue
        if c in '\'"':
            quote = c
        elif c in '(<':
            depth += 1
        elif c in ')>':
            depth -= 1
        elif c == sep and depth == 0:
            parts.append(cur.strip())
            cur = ''
            continue
        cur += c
    parts.append(cur.strip())
    return parts


class Assembler:
    def __init__(self, include_dir):
        self.include_dir = include_dir
        self.symbols = {
            'CENTRYSIZE': struct_size('ctrystr') - 2,
            'CDATASIZE': struct_size('ctrydat') - 2,
            'CINFOSIZE': struct_size('cinfo'),
            'CNTRYCNT': 0,
        }
        self.labels = {}

    def value(self, expr, final):
        expr = expr.strip()
        if not expr:
            return 0
        if len(expr) == 3 and expr[0] in '\'"' and expr[2] == expr[0]:
            return ord(expr[1])
        expr = re.sub(r'(?i)\boffset\b', '', expr).strip()
        terms = re.split(r'([+-])', expr)
        total, sign = 0, 1
        for term in terms:
            term = term.strip()
            if term == '+':
                sign = 1
            elif term == '-':
                sign = -1
            elif term:
                total += sign * self.atom(term, final)
        return total

    def atom(self, term, final):
        if term.startswith('(') and term.endswith(')'):
            return self.value(term[1:-1], final)
        if term[0] in '\'"' and term[-1] == term[0] and len(term) == 3:
            return ord(term[1])
        if re.fullmatch(r'[0-9][0-9a-fA-F]*[hH]', term):
            return int(term[:-1], 16)
        if re.fullmatch(r'[0-9]+', term):
            return int(term, 10)
        key = term.upper()
        if key in self.symbols:
            return self.symbols[key]
        if key in self.labels:
            return self.labels[key]
        if final:
            raise ValueError(f'undefined symbol {term}')
        return 0

    def data(self, size, items, final):
        out = bytearray()
        for item in split_top(items):
            match = re.fullmatch(r'(?is)(.+?)\s+dup\s*\((.*)\)', item)
            if match:
                count = self.value(match.group(1), final)
                for _ in range(count):
                    out += self.data(size, match.group(2), final)
            elif size == 1 and len(item) >= 2 and item[0] in '\'"' and item[-1] == item[0]:
                out += item[1:-1].encode('latin-1')
            else:
                out += (self.value(item, final) & ((1 << (8 * size)) - 1)).to_bytes(size, 'little')
        return out

    def struct(self, name, args, final):
        fields = STRUCTS[name]
        values = split_top(args.strip()[1:-1]) if args.strip() else []
        out = bytearray()
        for i, (size, default) in enumerate(fields):
            given = values[i] if i < len(values) else ''
            if not given:
                if isinstance(default, bytes):
                    out += default
                elif isinstance(default, str):
                    out += self.value(default, final).to_bytes(size, 'little')
                else:
                    out += default.to_bytes(size, 'little')
            elif given[0] in '\'"' and len(given) > 3:
                out += given[1:-1].encode('latin-1').ljust(size, b' ')[:size]
            else:
                out += (self.value(given, final) & ((1 << (8 * size)) - 1)).to_bytes(size, 'little')
        return out

    def lines(self, path):
        for line in path.read_text(encoding='latin-1').splitlines():
            line = strip_comment(line).rstrip().replace('\t', ' ')
            words = line.split()
            if len(words) == 2 and words[0].lower() == 'include':
                local = path.parent / words[1].upper()
                yield from self.lines(local if local.exists() else
                                      self.include_dir / words[1].upper())
            else:
                yield line

    def assemble(self, path, final):
        self.symbols['CNTRYCNT'] = 0
        out = bytearray()
        active = in_macro = False
        for line in self.lines(path):
            if not line.strip():
                continue
            label, body = None, line.strip()
            first = body.split()[0].lower()
            if not line[0].isspace() and first not in ('db', 'dw', 'dd', 'page', 'dummy'):
                label, _, body = body.partition(' ')
                body = body.strip()
                if '\t' in label:
                    label, _, more = label.partition('\t')
                    body = (more + ' ' + body).strip()
            op, _, args = body.partition(' ') if ' ' in body else body.partition('\t')
            op, args = op.lower(), args.strip()
            if '\t' in op:
                op, _, more = op.partition('\t')
                args = (more + ' ' + args).strip()
            if not active:
                if label and label.lower() == 'dseg' and op == 'segment':
                    active = True
                elif label and op == 'equ' and label.upper() not in self.symbols:
                    self.symbols[label.upper()] = self.value(args, False)
                continue
            if label and label.lower() == 'cdiend':
                break
            if op == 'macro' or args.lower().startswith('macro'):
                in_macro = True
                continue
            if in_macro:
                in_macro = op != 'endm' and (label or '').lower() != 'endm'
                continue
            if label and '=' in label:
                continue                # cntrycnt=0
            if label and op == 'equ':
                self.symbols[label.upper()] = len(out) if args == '$' else self.value(args, final)
                continue
            if label:
                self.labels[label.upper()] = len(out)
            if op in ('', 'label', 'page'):
                continue
            if op in ('db', 'dw', 'dd'):
                out += self.data({'db': 1, 'dw': 2, 'dd': 4}[op], args, final)
            elif op in STRUCTS or op in MACROS:
                out += self.struct(MACROS.get(op, op), args, final)
                if op == 'ctryent':
                    self.symbols['CNTRYCNT'] += 1
            elif op == 'dummy':
                self.symbols['FINALCNT'] = self.symbols['CNTRYCNT']
            else:
                raise ValueError(f'unsupported line: {line}')
        return bytes(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    assembler = Assembler(args.source.parent)
    assembler.assemble(args.source, False)
    data = assembler.assemble(args.source, True)
    if data[:8] != b'\xffCOUNTRY':
        raise SystemExit('COUNTRY.SYS signature missing')
    args.output.write_bytes(data)


if __name__ == '__main__':
    main()
