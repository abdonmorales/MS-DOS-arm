#!/usr/bin/env python3
"""Create a deterministic MBR/FAT16 UEFI disk image without privileged mounts."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

SECTOR = 512
TOTAL_SECTORS = 131072  # 64 MiB, power of two for QEMU and physical media.
START = 2048
PARTITION_SECTORS = TOTAL_SECTORS - START
SPC = 4
RESERVED = 1
FATS = 2
ROOT_ENTRIES = 512
ROOT_SECTORS = ROOT_ENTRIES * 32 // SECTOR
FAT_SECTORS = 128
DATA_START = RESERVED + FATS * FAT_SECTORS + ROOT_SECTORS
CLUSTERS = (PARTITION_SECTORS - DATA_START) // SPC


def entry(name, attr, cluster, size):
    if len(name) != 11:
        raise ValueError('Name must already be encoded in 8.3 form')
    item = bytearray(32)
    item[:11] = name
    item[11] = attr
    struct.pack_into('<HHHI', item, 22, 0, 0x5ac6, cluster, size)  # 2025-06-06
    return item


class FatImage:
    def __init__(self, image):
        self.image = image
        self.fat = bytearray(FAT_SECTORS * SECTOR)
        struct.pack_into('<HH', self.fat, 0, 0xfff8, 0xffff)
        self.next_cluster = 2
        self.root = bytearray(ROOT_SECTORS * SECTOR)
        self.root_slot = 0

    def add(self, data):
        count = max(1, (len(data) + SPC * SECTOR - 1) // (SPC * SECTOR))
        first = self.next_cluster
        if first + count - 2 >= CLUSTERS:
            raise ValueError('Disk image is full')
        for cluster in range(first, first + count):
            struct.pack_into('<H', self.fat, cluster * 2,
                             cluster + 1 if cluster + 1 < first + count else 0xffff)
            offset = (START + DATA_START + (cluster - 2) * SPC) * SECTOR
            start = (cluster - first) * SPC * SECTOR
            block = data[start:start + SPC * SECTOR]
            self.image[offset:offset + len(block)] = block
        self.next_cluster += count
        return first

    def root_entry(self, item):
        self.root[self.root_slot * 32:(self.root_slot + 1) * 32] = item
        self.root_slot += 1

    def finish(self):
        for copy in range(FATS):
            offset = (START + RESERVED + copy * FAT_SECTORS) * SECTOR
            self.image[offset:offset + len(self.fat)] = self.fat
        offset = (START + RESERVED + FATS * FAT_SECTORS) * SECTOR
        self.image[offset:offset + len(self.root)] = self.root


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('efi', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if not 4085 <= CLUSTERS < 65525 or (CLUSTERS + 2) * 2 > FAT_SECTORS * SECTOR:
        raise ValueError('Invalid FAT16 geometry')
    disk = bytearray(TOTAL_SECTORS * SECTOR)
    # EFI System Partition in an MBR, starting at the 1 MiB boundary.
    struct.pack_into('<B3sB3sII', disk, 446,
                     0, b'\xfe\xff\xff', 0xef, b'\xfe\xff\xff',
                     START, PARTITION_SECTORS)
    disk[510:512] = b'\x55\xaa'
    boot = memoryview(disk)[START * SECTOR:(START + 1) * SECTOR]
    boot[:3] = b'\xeb\x3c\x90'
    boot[3:11] = b'ARMDOS40'
    struct.pack_into('<HBHBHHBHHHII', boot, 11,
                     SECTOR, SPC, RESERVED, FATS, ROOT_ENTRIES, 0, 0xf8,
                     FAT_SECTORS, 63, 255, START, PARTITION_SECTORS)
    struct.pack_into('<BBB I 11s 8s', boot, 36,
                     0x80, 0, 0x29, 0x400a6464, b'ARMDOS     ', b'FAT16   ')
    boot[510:512] = b'\x55\xaa'
    fs = FatImage(disk)
    fs.root_entry(entry(b'ARMDOS     ', 0x08, 0, 0))
    application = args.efi.read_bytes()
    app_cluster = fs.add(application)
    boot_entries = entry(b'.          ', 0x10, 0, 0)
    boot_entries += entry(b'..         ', 0x10, 0, 0)
    boot_entries += entry(b'BOOTAA64EFI', 0x20, app_cluster, len(application))
    boot_cluster = fs.add(boot_entries)
    efi_entries = entry(b'.          ', 0x10, 0, 0)
    efi_entries += entry(b'..         ', 0x10, 0, 0)
    efi_entries += entry(b'BOOT       ', 0x10, boot_cluster, 0)
    efi_cluster = fs.add(efi_entries)
    fs.root_entry(entry(b'EFI        ', 0x10, efi_cluster, 0))
    # Set dot/dotdot references after their cluster numbers are known.
    for cluster, parent in [(boot_cluster, efi_cluster), (efi_cluster, 0)]:
        offset = (START + DATA_START + (cluster - 2) * SPC) * SECTOR
        struct.pack_into('<H', disk, offset + 26, cluster)
        struct.pack_into('<H', disk, offset + 32 + 26, parent)
    for name, data in [
        (b'ARMTEST TXT', b'ARM64 FAT read\r\n'),
        (b'README  TXT', b'MS-DOS 4.0 AArch64 development runtime.\r\n'
         b'This is a partial native port, not the full MS-DOS system.\r\n'
         b'Boot with ARM64 UEFI; HELP lists implemented commands.\r\n'),
    ]:
        cluster = fs.add(data)
        fs.root_entry(entry(name, 0x20, cluster, len(data)))
    fs.finish()
    args.output.write_bytes(disk)
    digest = hashlib.sha256(disk).hexdigest()
    args.output.with_suffix('.img.sha256').write_text(f'{digest}  {args.output.name}\n')
    manifest = {'format': 'MBR/FAT16 EFI System Partition',
                'architecture': 'AArch64', 'bytes': len(disk),
                'sha256': digest, 'boot_application': 'EFI/BOOT/BOOTAA64.EFI',
                'complete_msdos_port': False, 'native_hardware_tested': False}
    args.output.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'{args.output}: {len(disk) // 1048576} MiB FAT16 ARM64 UEFI image')


if __name__ == '__main__':
    main()
