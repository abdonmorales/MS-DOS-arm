#!/usr/bin/env python3
"""Download ARM DOS release assets from GitHub and verify them.

    fetch_release.py                        every asset of the latest release
    fetch_release.py armdos.iso             just the live ISO
    fetch_release.py --tag v1.0.0 --dest d  a given release, into folder d

Assets go into images/ by default. Every file is checked against the
release's SHA256SUMS before it is kept; a file already present with the
right checksum is not downloaded again. Standard library only.
"""
import argparse
import hashlib
import re
import os
from pathlib import Path
import sys
import urllib.error
import urllib.request

REPO = 'abdonmorales/MS-DOS-arm'
DEFAULT_DEST = Path(__file__).resolve().parent.parent / 'images'
# Overridable for testing against a local mirror laid out like GitHub's
# <base>/releases/download/<tag>/<asset>.
BASE = os.environ.get('ARMDOS_RELEASE_BASE', f'https://github.com/{REPO}').rstrip('/')
USER_AGENT = 'armdos-fetch-release'


def open_url(url):
    request = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
    return urllib.request.urlopen(request, timeout=60)


def latest_tag():
    """The tag that github.com/<repo>/releases/latest redirects to."""
    with open_url(BASE + '/releases/latest') as response:
        final = response.geturl().rstrip('/')
    marker = '/releases/tag/'
    if marker not in final:
        raise SystemExit('No published release found at ' + BASE + '/releases; '
                         'build the images yourself with make iso / make image')
    return urllib.request.unquote(final.split(marker, 1)[1])


def parse_sums(text):
    sums = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        checksum, name = line.split(None, 1)
        name = name.lstrip('*')
        if '/' in name or '\\' in name or name in ('.', '..') or not re.fullmatch(r'[0-9a-fA-F]{64}', checksum):
            raise SystemExit('Malformed SHA256SUMS line: ' + line)
        sums[name] = checksum.lower()
    return sums


def file_digest(path):
    sha = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            sha.update(block)
    return sha.hexdigest()


def download(url, target, expected):
    partial = target.with_name(target.name + '.part')
    sha = hashlib.sha256()
    try:
        with open_url(url) as response, partial.open('wb') as output:
            total = int(response.headers.get('Content-Length') or 0)
            done = 0
            for block in iter(lambda: response.read(1 << 20), b''):
                output.write(block)
                sha.update(block)
                done += len(block)
                if total and sys.stderr.isatty():
                    print(f'\r  {target.name}: {done * 100 // total}%', end='',
                          file=sys.stderr, flush=True)
        if total and sys.stderr.isatty():
            print(file=sys.stderr)
        if sha.hexdigest() != expected:
            raise SystemExit(f'{target.name}: checksum mismatch, download discarded')
        partial.replace(target)
    finally:
        partial.unlink(missing_ok=True)


def fetch(names=None, tag=None, dest=DEFAULT_DEST):
    """Fetch and verify assets; return {name: path}. names=None means all."""
    tag = tag or latest_tag()
    base = f'{BASE}/releases/download/{urllib.request.quote(tag)}/'
    try:
        with open_url(base + 'SHA256SUMS') as response:
            sums = parse_sums(response.read().decode())
    except urllib.error.HTTPError as error:
        raise SystemExit(f'Release {tag}: cannot read SHA256SUMS ({error.code})')
    wanted = list(sums) if not names else names
    missing = [name for name in wanted if name not in sums]
    if missing:
        raise SystemExit(f'Release {tag} has no asset ' + ', '.join(missing))
    dest.mkdir(parents=True, exist_ok=True)
    paths = {}
    for name in wanted:
        target = dest / name
        if target.is_file() and file_digest(target) == sums[name]:
            print(f'{target}: already up to date ({tag})')
        else:
            print(f'Downloading {name} from release {tag}', flush=True)
            download(base + urllib.request.quote(name), target, sums[name])
            print(f'{target}: SHA-256 verified')
        paths[name] = target
    # Keep the checksums beside the files for `sha256sum -c SHA256SUMS`:
    # lines for what is in dest (earlier fetches too), so the check passes.
    listed = dest / 'SHA256SUMS'
    kept = {}
    if listed.is_file():
        try:
            kept = parse_sums(listed.read_text())
        except (SystemExit, ValueError):
            kept = {}
    kept.update({name: sums[name] for name in paths})
    listed.write_text(''.join(f'{kept[name]}  {name}\n' for name in sorted(kept)
                              if (dest / name).is_file()))
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('assets', nargs='*',
                        help='asset names, e.g. armdos.iso (default: all)')
    parser.add_argument('--tag', help='release tag (default: the latest release)')
    parser.add_argument('--dest', type=Path, default=DEFAULT_DEST,
                        help='download folder (default: images/)')
    args = parser.parse_args()
    try:
        fetch(args.assets or None, args.tag, args.dest)
    except urllib.error.URLError as error:
        raise SystemExit(f'Download failed: {error}')


if __name__ == '__main__':
    main()
