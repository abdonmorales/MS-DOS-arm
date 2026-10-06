#!/usr/bin/env bash
# Install the tested cross tools without root or system package changes.
# This helper targets the Debian 13 x86_64 cloud base image.
set -euo pipefail
test "$(uname -m)" = x86_64
test -r /usr/share/keyrings/debian-archive-keyring.gpg
setup_root=/workspace/arm-toolchain
mkdir -p "$setup_root/apt/lists/partial" "$setup_root/apt/empty" \
  "$setup_root/apt/archives/partial" "$setup_root/packages" "$setup_root/runtime"
python3 - <<'PY'
from pathlib import Path
root = Path('/workspace/arm-toolchain/apt')
files = {
    'sources.list': 'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian trixie main\n',
    'apt.conf': '''Dir::Etc::parts "/workspace/arm-toolchain/apt/empty";
Dir::Etc::main "/workspace/arm-toolchain/apt/empty/main.conf";
Dir::Etc::sourcelist "/workspace/arm-toolchain/apt/sources.list";
Dir::Etc::sourceparts "/workspace/arm-toolchain/apt/empty";
Dir::State "/workspace/arm-toolchain/apt";
Dir::State::status "/var/lib/dpkg/status";
Dir::Cache "/workspace/arm-toolchain/apt";
''',
}
for name, content in files.items():
    path = root / name
    if path.exists() and path.read_text() != content:
        raise SystemExit('Preserving differing existing configuration: ' + str(path))
    if not path.exists():
        path.write_text(content)
PY
export APT_CONFIG="$setup_root/apt/apt.conf"
apt-get update
python3 - <<'PY'
from pathlib import Path
import os
import re
import subprocess
root = Path('/workspace/arm-toolchain')
targets = ['binutils-aarch64-linux-gnu', 'qemu-system-arm',
           'qemu-efi-aarch64', 'mtools', 'dosfstools']
simulation = subprocess.check_output(
    ['apt-get', '-s', 'install', '--no-install-recommends', *targets], text=True)
dependencies = re.findall(r'^Inst (\S+) ', simulation, re.M)
packages = sorted(set(targets + dependencies))
# APT verifies signed repository metadata and each downloaded package hash.
subprocess.run(['apt-get', 'download', *packages], cwd=root/'packages', check=True)
for name in packages:
    # Resolve each selected archive exactly; do not extract unrelated files.
    matches = list((root/'packages').glob(name + '_*.deb'))
    if len(matches) != 1:
        raise SystemExit('Multiple/missing package versions; inspect cache: ' + name)
    subprocess.run(['dpkg-deb', '--extract', str(matches[0]), str(root/'runtime')],
                   check=True)
PY
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/env.sh"
aarch64-linux-gnu-as --version
qemu-system-aarch64 --version
make -C "$script_dir/.." smoke FIRMWARE="$setup_root/runtime/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
