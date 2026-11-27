#!/usr/bin/env python3
"""Package the generic ROM build (ARMDOS.EFI) for U-Boot boards.

Writes:
- a FIT image (armdos-rom.itb) holding ARMDOS.EFI as an "efi" kernel, which
  U-Boot starts with `bootm <address>` wherever the image sits: RAM after
  `sf read`/`load`, or memory-mapped NOR flash;
- a 64 MiB NOR flash image (armdos-rom-flash.bin) with the FIT at offset 0,
  the size of QEMU virt's second flash bank (0x04000000), so
  `-drive if=pflash,unit=1,format=raw,file=armdos-rom-flash.bin` and
  `bootm 0x04000000` boot it with no disk at all.

Boards that boot EFI applications directly (EDK2, or U-Boot's `bootefi`)
can take ARMDOS.EFI itself.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

FLASH_BYTES = 64 << 20
ITS = '''/dts-v1/;

/ {
	description = "ARM DOS 4.0 ROM build";
	#address-cells = <1>;

	images {
		armdos {
			description = "ARM DOS kernel with its ROM disk (ARMDOS.EFI)";
			data = /incbin/("%s");
			type = "kernel_noload";
			arch = "arm64";
			os = "efi";
			compression = "none";
			load = <0>;
			entry = <0>;
			hash-1 {
				algo = "sha256";
			};
		};
	};

	configurations {
		default = "armdos";
		armdos {
			description = "ARM DOS";
			kernel = "armdos";
		};
	};
};
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('efi', type=Path)
    parser.add_argument('--fit', type=Path, required=True)
    parser.add_argument('--flash', type=Path, required=True)
    parser.add_argument('--mkimage', default='mkimage')
    args = parser.parse_args()
    env = dict(os.environ)
    env.setdefault('SOURCE_DATE_EPOCH', '1749168000')   # reproducible timestamp
    with tempfile.TemporaryDirectory(prefix='arm64-fit-') as name:
        its = Path(name) / 'armdos.its'
        its.write_text(ITS % args.efi.resolve())
        output = args.fit.with_suffix('.tmp')
        subprocess.run([args.mkimage, '-f', str(its), str(output)], env=env, check=True,
                       stdout=subprocess.DEVNULL)
        os.replace(output, args.fit)
    fit = args.fit.read_bytes()
    if len(fit) > FLASH_BYTES:
        raise SystemExit('the FIT image does not fit the flash image')
    # Erased NOR flash reads as FFh.
    args.flash.write_bytes(fit + b'\xff' * (FLASH_BYTES - len(fit)))
    print(f'{args.fit}: FIT image, {len(fit)} bytes; {args.flash}: 64 MiB NOR flash image')


if __name__ == '__main__':
    main()
