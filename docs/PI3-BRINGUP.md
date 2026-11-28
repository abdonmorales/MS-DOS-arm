# Raspberry Pi 3 first boot: bring-up checklist

ARM DOS has never been booted on a physical Raspberry Pi 3. Its Pi drivers
(the mini UART / PL011 console and the SD card on the Arasan SDHCI) pass
`make pi-test` on QEMU's `raspi3b` model, and the whole kernel passes
`make smoke` on QEMU `virt`, but only a real board can confirm them. This
checklist takes you from parts to a log that shows how far the boot got.

Anything marked **(unverified)** comes from the firmware's documentation or
from QEMU, not from a real board. Please correct it with what you see.

## 1. Parts

| Part | Notes |
| --- | --- |
| Raspberry Pi 3 Model B or 3 Model B+ | Not a Pi 4, Pi 5, Pi 2 or Zero 2 W: the image carries Pi 3 UEFI firmware only. See [3B vs 3B+](#9-pi-3b-vs-3b) |
| 5 V, 2.5 A micro-USB power supply | The official Pi 3 supply. A phone charger often browns out the 3B+ (lightning-bolt icon on HDMI, random hangs) |
| microSD card, 128 MB or larger | Any size works (the image is 128 MiB). Its contents are overwritten |
| USB-to-serial adapter, **3.3 V TTL** | CP2102, FTDI FT232R/FT231X, CH340 or PL2303 boards. **Never a 5 V adapter and never RS-232 levels**: they damage the Pi's GPIO. If the board has a 3.3 V / 5 V jumper, set it to 3.3 V |
| 3 female-female jumper wires | GND, TX, RX only |
| Optional: HDMI monitor and USB keyboard | Useful in firmware mode. In native mode the console is the serial port only |

## 2. Wiring

Power the Pi off. Looking at the 40-pin header with the board's USB ports
pointing down, pin 1 is the top-left pin of the left column (odd pins on the
left, even pins on the right; pins 2, 4, 6, 8, 10 run down the outer edge).

| Pi header pin | Pi signal | Adapter pin |
| --- | --- | --- |
| Pin 6 | GND | GND |
| Pin 8 | GPIO 14 / TXD (Pi transmits) | RXD (adapter receives) |
| Pin 10 | GPIO 15 / RXD (Pi receives) | TXD (adapter transmits) |

TX goes to RX in both directions. **Leave the adapter's VCC / 5V / 3V3 pin
unconnected**; the Pi is powered from its own supply. If you see nothing at
all later, swapping the TX and RX wires is the first thing to try (it cannot
harm a 3.3 V adapter).

## 3. Serial terminal (macOS)

Settings: **115200 baud, 8 data bits, no parity, 1 stop bit (8N1), no flow
control**.

Find the adapter's device by listing before and after plugging it in:

```sh
ls /dev/tty.*
```

It appears as `/dev/tty.usbserial-XXXX` (FTDI, newer CP210x and CH340
drivers), `/dev/tty.SLAB_USBtoUART` (older CP210x driver) or
`/dev/tty.wchusbserial*` (older CH340 driver). Start the terminal **before**
powering the Pi, and log everything to a file from the start:

```sh
screen -L -Logfile pi3-boot.log /dev/tty.usbserial-XXXX 115200
```

Quit `screen` with **Ctrl-A, then K, then y**. Or use picocom
(`brew install picocom`):

```sh
picocom -b 115200 --logfile pi3-boot.log /dev/tty.usbserial-XXXX
```

Quit picocom with **Ctrl-A, then Ctrl-X**.

## 4. Get the SD-card image

Either:

- **Release**: download `msdos-arm64-pi3.img.xz` from the repository's
  [GitHub Releases page](https://github.com/abdonmorales/MS-DOS-arm/releases)
  and check it against the published SHA-256 (`shasum -a 256 msdos-arm64-pi3.img.xz`).
  Decompress with `xz -dk msdos-arm64-pi3.img.xz` (Raspberry Pi Imager also
  takes the `.xz` directly).
- **Build**: `make pi-image` builds `build/msdos-arm64-pi3.img` (needs the
  toolchain from the README's Building section; on a Mac add
  `CROSS_COMPILE=aarch64-elf-`). It downloads the pinned, hash-checked
  [Pi 3 UEFI firmware v1.53.1](https://github.com/pftf/RPi3/releases/tag/v1.53.1).
- **Debug build** (recommended for the very first boot if the plain image
  shows nothing from ARM DOS): `make pi-image-debug` builds
  `build/pi-debug/msdos-arm64-pi3.img`, whose kernel prints checkpoints from
  its first instruction and which already has `DEBUG.ON` on the card.

## 5. Write the card (macOS)

**Raspberry Pi Imager**: Choose OS, then *Use custom*, pick the `.img` (or
`.img.xz`), choose the card, Write. Choose *No* if it offers OS
customisation; it does not apply.

**Or `dd`** (double-check the disk number: `dd` overwrites whatever you name):

```sh
diskutil list                         # find the card, e.g. /dev/disk4 (external, physical)
diskutil unmountDisk /dev/disk4
sudo dd if=msdos-arm64-pi3.img of=/dev/rdisk4 bs=4m
sync
diskutil eject /dev/disk4
```

After writing, re-insert the card: macOS mounts it as `/Volumes/ARMDOS`. You
should see `config.txt`, `RPI_EFI.fd`, `start.elf`, `EFI/BOOT/BOOTAA64.EFI`,
`COMMAND`'s programs (`*.EXE`) and the test files.

## 6. Turn on debug checkpoints and native mode

Two empty marker files in the card's root control the boot:

| File | Effect |
| --- | --- |
| `DEBUG.ON` | ARM DOS prints `ARMDOS: <step>` checkpoint lines on the serial console (and on HDMI while UEFI is still running). Without it nothing changes |
| `NATIVE.ON` | ARM DOS leaves the UEFI firmware (`ExitBootServices`) and uses its own UART and SD-card drivers. Without it the Pi stays in firmware mode, using UEFI's console and disk services |

```sh
touch /Volumes/ARMDOS/DEBUG.ON        # checkpoints on
touch /Volumes/ARMDOS/NATIVE.ON       # native drivers (second boot, see below)
diskutil eject /Volumes/ARMDOS
```

Delete a file to turn its feature off again. macOS may add `._*` files and
`.fseventsd`; they are harmless (`dot_clean /Volumes/ARMDOS` removes the
`._*` files).

**Suggested order:**

1. First boot: `DEBUG.ON` only (firmware mode). This checks the firmware,
   the serial wiring and the kernel without the new drivers.
2. Second boot: `DEBUG.ON` and `NATIVE.ON`. This is the real test of the
   native UART and SD drivers.
3. Third boot: `NATIVE.ON` only, to confirm the normal native boot.

### How the checkpoints work

- `DEBUG.ON` is read as soon as the boot volume can be read, so with it the
  first checkpoints (`entry`, `EL=`, `FAT mount`) appear together just
  before the platform probe. The debug build (`make pi-image-debug`, or any
  build with `make ARMDOS_DEBUG=1 BUILD=build/debug`) prints `entry` as the
  kernel's first action instead.
- While UEFI owns the machine the lines go through the firmware console
  (serial and HDMI). From `exit boot services` on, they are written straight
  to the transmit register of the UART that the firmware named in its ACPI
  SPCR table: the same UART the firmware used as its serial console, so its
  baud rate and GPIO 14/15 pin function are already set. They bypass the DOS
  console, `ANSI.SYS` and redirection.
- A CPU exception in native mode with debug on prints `ESR`, `ELR`, the same
  PC as an address in `kernel.elf`, `FAR`, `SPSR`, `SP` and `x00`-`x30`.
- If the SD controller fails to start, its registers (`STATUS`, `CONTROL0`,
  `CONTROL1`, `INTERRUPT`, `CAPS`, `VERSION`) and the GPIO function-select
  registers for the UART pins and the card slot are printed.

### Which UART?

The firmware's `config.txt` (kept exactly as the Pi 3 UEFI firmware ships
it, and checked by `tools/pi_image.py`) has `enable_uart=1` and no
`dtoverlay`. On the 3B and 3B+ the full PL011 UART is wired to Bluetooth, so
GPIO 14/15 carry the **mini UART**, and `enable_uart=1` fixes the VPU core
clock the mini UART's baud rate is derived from. The firmware reports that
UART in SPCR, and ARM DOS uses whatever SPCR says (PL011 or mini UART), so
the kernel's console is always the firmware's serial console. The
`console UART` checkpoint shows which one: base `3f215040`, type 1
is the mini UART; base `3f201000`, type 0 is the PL011. **(unverified: the
expected value on a real 3B/3B+ is the mini UART.)**

Do not add `dtoverlay=disable-bt` or `miniuart-bt` on the first boots.

## 7. Boot, stage by stage

Power on with the terminal already open. Each stage below says what you
should see and, if the boot stops there, the likely cause and what to try.

### Stage 0: power and SD read

- Red LED on steadily; green LED flickers within a few seconds (the boot ROM
  reading `bootcode.bin` from the card).
- **Stops here** (green LED never flickers, or blinks a fixed pattern):
  the card is unreadable or not written correctly. Re-write it, try another
  card, check the PSU. Four long + N short green blinks are the boot ROM's
  error codes (see the Raspberry Pi documentation on LED warning flash codes).

### Stage 1: GPU firmware (rainbow screen)

- HDMI shows a full-screen colour gradient (the "rainbow screen") briefly.
- Serial: `config.txt` has `uart_2ndstage=1`, so the GPU firmware may log
  its own lines (often starting `MESS:`) on the serial port.
  **(unverified on this image)**
- **Stops here** (rainbow stays): `start.elf`/`fixup.dat` or `RPI_EFI.fd`
  are missing or corrupt, or the supply is too weak (look for the
  lightning-bolt icon). Re-write the card; use the 2.5 A supply.

### Stage 2: UEFI firmware

- HDMI: the Raspberry Pi logo and a progress bar; *Esc* enters the firmware
  setup, *F1* the UEFI Shell.
- Serial: the firmware's log and banner, then the boot of
  `\EFI\BOOT\BOOTAA64.EFI`. **(unverified: exact text not known)**
- **No serial output at all here** but HDMI works: wiring (swap TX/RX; check
  GND), wrong device or baud rate, or a 5 V/RS-232 adapter. If the serial
  text is garbage: wrong baud rate, or the mini UART clock: uncomment
  `core_freq=250` in `config.txt` (the pinned firmware is expected to ship it commented out as `#core_freq=250`; if it is missing, add the line).
- **Stops at the logo / drops into the UEFI Shell or setup**: the firmware
  did not find or start `BOOTAA64.EFI`. In the Shell, type
  `fs0:\EFI\BOOT\BOOTAA64.EFI` (the card also has a `startup.nsh` that does
  this). If `fs0:` is not the card, try `map -r` and `fs1:`.

### Stage 3: ARM DOS checkpoints

On QEMU `virt` (tested by `make debug-test`) a debug boot prints the lines
below; the Pi's values differ where noted. In firmware mode (no `NATIVE.ON`):

```
ARMDOS: entry
ARMDOS: EL=0000000000000002                    (QEMU virt: 1; the Pi 3 firmware: probably 2, unverified)
ARMDOS: FAT mount ok (native FAT driver)
ARMDOS: debug output on (\DEBUG.ON)
ARMDOS: console UART (ACPI SPCR or device tree) base=000000003f215040
ARMDOS:   UART type (0 PL011, 1 mini UART/16550 32-bit, 2-3 16550 8-bit)=0000000000000001
ARMDOS:   PCI ECAM (0: none, Raspberry Pi path)=0000000000000000
ARMDOS: Pi 3: no \NATIVE.ON, staying on UEFI
ARMDOS: firmware mode (UEFI console and disk services)
ARMDOS: platform ready, printing banner
```

With `NATIVE.ON`, after the ECAM line:

```
ARMDOS: Pi 3: \NATIVE.ON found, going native
ARMDOS: exit boot services
ARMDOS: boot services exited, UART direct, vectors set, EL=0000000000000002
ARMDOS: sdhci init
ARMDOS: sdhci init ok, block addressed=0000000000000001   (1: SDHC/SDXC card, 0: SDSC up to 2 GB)
ARMDOS: SD boot partition found, LBA=0000000000000800
ARMDOS: platform ready, printing banner
```

| Last line you see | Likely cause | What to try |
| --- | --- | --- |
| No `ARMDOS:` line, but the firmware started `BOOTAA64.EFI` | `DEBUG.ON` missing or misnamed, or a hang before the volume was read | Check the file name in the card's root; use `make pi-image-debug` so `entry` prints first |
| `FAT mount: native driver declined, firmware file system` | The FAT driver did not accept the card; native mode then cannot be used | Re-write the card with the image unchanged; report it |
| `debug output on`, then `firmware mode` without a `console UART` line | No ACPI tables (the firmware is in Device Tree mode) | Firmware setup (*Esc*): Device Manager, Raspberry Pi Configuration, Advanced Configuration, System Table Selection: **ACPI** or **ACPI + Devicetree**. **(unverified)** |
| `UART type ... 0000000000000000` with base `3f201000` | The firmware uses the PL011 on GPIO 14/15 | Fine as long as you see serial output; report it |
| `Pi 3: no \NATIVE.ON` | Expected without `NATIVE.ON` | Add `NATIVE.ON` for the native test |
| `exit boot services`, then nothing | Either `ExitBootServices` hung, or the direct UART writes do not reach the pins (wrong UART, mini UART clock changed) | Uncomment `core_freq=250`; report the `console UART` lines. Delete `NATIVE.ON` to get back to a working boot |
| `boot services exited ...`, then nothing for over a minute | The SD driver is stuck (its waits have timeouts, so it should end in an error within seconds) | Report it; try another card |
| `sdhci init err step=N` plus register dump, then `Boot disk did not restart after leaving firmware.` | The card did not initialise on the Arasan controller. Steps: 1 controller reset, 2 clock, 3 CMD0, 4 ACMD41 (card power-up), 5 CMD2/CMD3, 6 CMD7, 7 CMD16, 8 data clock | Try another card brand/size (an SDHC card of 4-32 GB is the safest); send the dump. Delete `NATIVE.ON` to boot in firmware mode |
| `SD boot partition NOT found` | The driver reads the card but not the expected boot sector (wrong addressing or bad data) | Send the log; this points at the driver's read path |
| `platform ready`, then no banner | Console output after the platform switch | Send the log |
| `boot self-test`, then `SELFTEST FAIL ...` | A file/FCB/process API failed on this card | Send the log |
| `CONFIG.SYS` and then a hang | A `DEVICE=` driver from the test `CONFIG.SYS` | Send the log |
| `CPU exception, vector=...` and the register lines | A fault in the kernel or a program | Send all of it. To map `ELR in kernel.elf` to source, use `aarch64-linux-gnu-addr2line -e build/kernel.elf 0x<value>` with the `kernel.elf` from the **same** build |

### Stage 4: banner and prompt

The banner, then the test `CONFIG.SYS` output (it deliberately contains one
bad line, so `Unrecognized command in CONFIG.SYS` / `Error in CONFIG.SYS line
11` is expected), the RAM disks B:-D:, `AUTOEXEC.BAT ran`, and the prompt:

```
ARM DOS 4.0 for AArch64 (MS-DOS 4.0 compatible)
Native ARM64 assembly. x86 programs do not run.
Platform: native AArch64 kernel (firmware exited; Raspberry Pi 3 UART console, SD card)
Storage: native FAT32 driver over the native SD card driver
...
SELFTEST PASS: file/FCB APIs, directories/search, memory, clock, native processes.
...
AUTOEXEC.BAT ran
A:\>
```

In firmware mode the `Platform:` line reads `UEFI firmware services (no
native drivers for this board)` and the storage line ends `over UEFI Block
I/O` instead of `over the native SD card driver`; HDMI and a USB keyboard work there as well.
In native mode only the serial port works.

## 8. Self-test at the prompt

Type each command and check the result (commands are case-insensitive):

| Command | Expected |
| --- | --- |
| `VER` | `ARM DOS Version 4.00 (AArch64), MS-DOS 4.00 API` |
| `DIR` | The card's files, ending with `bytes free` |
| `MEM` | Memory report including `largest executable program size` |
| `SELFTEST` | `SELFTEST PASS: ...` |
| `NATIVE` | `Native AArch64 program OK` |
| `DOSTEST` | `DOSTEST PASS` (every DOS function) |
| `BASIC PRIMES` | The primes below 100 (`2 3 5 ... 89 97`), then `Ok`; type `SYSTEM` to return |
| `ECHO Pi SD write test>PITEST.TXT` then `TYPE PITEST.TXT` | `Pi SD write test` |
| `COPY PITEST.TXT PITEST2.TXT` then `DIR PITEST*.TXT` | A `file(s) copied` line, both files listed |
| `CHKDSK` | `bytes total disk space`, no errors |
| `NATIVE FAULT` (with `DEBUG.ON`) | The register dump, then `Program terminated by CPU exception.` and the prompt again |
| `EXIT` | Native mode: the Pi powers off through UEFI runtime services **(unverified on the Pi)**; firmware mode: back to UEFI |

Then check that the writes reached the card: power off, put the card in the
Mac, and run `cat /Volumes/ARMDOS/PITEST.TXT` (expect `Pi SD write test`).
macOS's own checker, `diskutil unmount /Volumes/ARMDOS` then
`sudo fsck_msdos -n /dev/disk4s1`, should report no errors.

Backspace works (the terminal's DEL is translated to backspace).

## 9. Pi 3B vs 3B+

| | 3B | 3B+ |
| --- | --- | --- |
| SoC / CPU | BCM2837, 1.2 GHz | BCM2837B0, 1.4 GHz |
| Power | 2.5 A recommended | 2.5 A needed; more sensitive to weak supplies and heat |
| UART on GPIO 14/15 | Mini UART (PL011 goes to Bluetooth) | Same |
| SD controller, GPIO, UART addresses | Same | Same |
| Device tree | `bcm2710-rpi-3-b.dtb` | `bcm2710-rpi-3-b-plus.dtb` (both on the card; the firmware picks one) |
| Ethernet / USB | LAN9514 | LAN7515 (not used by ARM DOS) |

ARM DOS uses only the UART, the SD card and the UEFI firmware, all of which
are the same on both boards, so either should behave the same.
**(unverified: neither has been booted yet.)**

## 10. What to send back

1. `pi3-boot.log` from `screen -L` / picocom, covering the whole boot from
   power-on, for each boot you tried (name them, e.g. `fw-debug.log`,
   `native-debug.log`, `native.log`).
2. Which board (3B or 3B+, printed on the board), the power supply, and the
   SD card's brand and size.
3. Which marker files were on the card, and which image (release tag, or
   `git rev-parse HEAD` plus `make pi-image` / `make pi-image-debug`).
4. If it stopped before any serial output: what the LEDs did and a photo of
   the HDMI screen.
5. The results of the self-test commands in section 8.
