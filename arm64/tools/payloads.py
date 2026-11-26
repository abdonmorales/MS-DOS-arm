"""The DOS payload files the build produces, named from the sources (not by
globbing build/, where stale outputs of removed programs could linger)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def payload_names():
    names = [p.stem.upper() + '.EXE' for p in sorted((ROOT / 'programs').glob('*.S'))]
    names += [p.stem.upper() + '.SYS' for p in sorted((ROOT / 'drivers').glob('*.S'))]
    names.append('COUNTRY.SYS')
    return sorted(names)


def payload_paths(build):
    return [Path(build) / name for name in payload_names()]
