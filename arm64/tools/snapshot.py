#!/usr/bin/env python3
"""Package only images whose exact bytes/source passed recorded validation."""
import argparse
import json
import lzma
from pathlib import Path
import shutil
from validate import digest, source_digest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', type=Path, default=Path('build'))
    parser.add_argument('--output', type=Path, default=Path('images'))
    args = parser.parse_args()
    report = json.loads((args.build / 'validation.json').read_text())
    source = Path(__file__).resolve().parent.parent
    if report['source_files_sha256'] != source_digest(source):
        raise SystemExit('Source changed since validation; run make validate')
    if report['complete_msdos_port'] is not False:
        raise SystemExit('Invalid completion claim in validation report')
    args.output.mkdir(exist_ok=True, parents=True)
    for name in ['msdos-arm64', 'msdos-arm64-pi3']:
        path = args.build / (name + '.img')
        evidence = report['images'][name]
        if (digest(path) != evidence['sha256'] or
                evidence['aarch64_uefi_qemu_boot'] != 'pass' or
                evidence['filesystem_check'] != 'pass' or
                evidence['payload_check'] != 'pass'):
            raise SystemExit('Image bytes or validation mismatch: ' + name)
        output = args.output / (name + '.img.xz')
        with path.open('rb') as raw, lzma.open(output, 'wb', preset=6) as compressed:
            shutil.copyfileobj(raw, compressed)
        manifest = json.loads(path.with_suffix('.json').read_text())
        manifest['compressed_sha256'] = digest(output)
        manifest['compressed_bytes'] = output.stat().st_size
        (args.output / (name + '.json')).write_text(json.dumps(manifest, indent=2) + '\n')
        (args.output / (name + '.img.sha256')).write_text(
            f"{evidence['sha256']}  {name}.img\n")
        (args.output / (name + '.img.xz.sha256')).write_text(
            f"{manifest['compressed_sha256']}  {output.name}\n")
        print(f'{output}: {output.stat().st_size} compressed bytes')
    shutil.copyfile(args.build / 'validation.json', args.output / 'validation.json')


if __name__ == '__main__':
    main()
