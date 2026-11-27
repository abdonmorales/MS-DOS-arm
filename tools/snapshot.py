#!/usr/bin/env python3
"""Package only images whose exact bytes/source passed recorded validation.

The result (by default build/release/, `make snapshot SNAPSHOT_DIR=...`) is
the asset set of a GitHub Release: the compressed disk images, the plain
live ISO, their manifests, validation.json and SHA256SUMS over all of them.
Images are no longer committed to the repository.
"""
import argparse
import json
import lzma
from pathlib import Path
import shutil
from validate import digest, source_digest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', type=Path, default=Path('build'))
    parser.add_argument('--output', type=Path, default=Path('build/release'))
    args = parser.parse_args()
    report = json.loads((args.build / 'validation.json').read_text())
    source = Path(__file__).resolve().parent.parent
    if report['source_files_sha256'] != source_digest(source):
        raise SystemExit('Source changed since validation; run make validate')
    if report['complete_msdos_port'] is not False:
        raise SystemExit('Invalid completion claim in validation report')
    args.output.mkdir(exist_ok=True, parents=True)
    written = []
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
        written += [output.name, name + '.json', name + '.img.sha256']
        print(f'{output}: {output.stat().st_size} compressed bytes')
    # The live ISO, packaged only when make iso-test passed on these bytes.
    iso = args.build / 'armdos.iso'
    record = json.loads(iso.with_suffix('.test.json').read_text())
    if (record['iso_test'] != 'pass' or record['sha256'] != digest(iso) or
            record['source_files_sha256'] != report['source_files_sha256']):
        raise SystemExit('ISO bytes or test mismatch: run make iso-test')
    # Published uncompressed so it can be downloaded and booted (or attached
    # to a VM) as-is.
    output = args.output / 'armdos.iso'
    shutil.copyfile(iso, output)
    if digest(output) != record['sha256']:
        raise SystemExit('Copied ISO does not match the tested bytes')
    print(f'{output}: {output.stat().st_size} bytes')
    shutil.copyfile(args.build / 'validation.json', args.output / 'validation.json')
    written += ['armdos.iso', 'validation.json']
    # Sidecars of the old committed layout; SHA256SUMS replaces them.
    for stale in ('armdos.iso.xz', 'armdos.iso.xz.sha256', 'armdos.iso.sha256',
                  'msdos-arm64.img.xz.sha256', 'msdos-arm64-pi3.img.xz.sha256'):
        (args.output / stale).unlink(missing_ok=True)
    write_sums(args.output, written)
    print(f"{args.output / 'SHA256SUMS'}: {len(written)} files")


def write_sums(directory, names):
    """SHA256SUMS in `sha256sum -c` format (also read by fetch_release.py)."""
    lines = ''.join(f'{digest(directory / name)}  {name}\n' for name in sorted(names))
    (directory / 'SHA256SUMS').write_text(lines)


if __name__ == '__main__':
    main()
