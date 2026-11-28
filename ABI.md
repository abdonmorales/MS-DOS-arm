# ARM DOS native AArch64 ABI, version 2

This ABI adapts selected DOS 4.0 public operations to flat pointers and AAPCS64.
It does not run x86 DOS binaries or recreate segment registers, interrupt 21h,
the original PSP, or DOS memory-control blocks. Programs run at the kernel's
privilege level (EL1) in one flat address space, like DOS programs share real
mode. Resource ownership provides cleanup, not memory isolation. A CPU
exception in a program terminates that program (termination type 2).

In native mode the kernel uses its own page tables (`src/mmu.S`): kernel code
and read-only data cannot be written, kernel data, the stack and other RAM
cannot be executed, and the first 64 KiB are unmapped so null pointers fault.
The memory arena (program images, drivers, `48h` blocks) stays readable,
writable and executable. A fault prints a one-line description (for example
`Protection fault: null pointer reference`), the registers, and returns to the
parent with type 2. A kernel started at EL2 drops to EL1 first, so native mode
always runs at EL1. Firmware mode keeps the firmware's tables.

Version 2 (this document) drops UEFI from the program interface: the kernel
loads programs itself and passes the descriptor directly.

## Program entry and API discovery

Programs are AArch64 PE32+ images (machine `0xaa64`, optional-header magic
`0x20b`), conventionally named `.EXE`. The kernel copies the headers and
sections into a 64 KiB-aligned block (images use ADRP, so the block keeps
their page offsets), applies `IMAGE_REL_BASED_DIR64` relocations, and calls
the entry point with `x0` = this 64-byte descriptor (`x1` = 0). Returning
from the entry point ends the program with exit code 0.

| Offset | Value |
| --- | --- |
| 0 | Eight signature bytes `ARMDOS64` |
| 8 | ABI version, u64 = 1 |
| 16 | Descriptor size, u64 = 64 |
| 24 | AAPCS64 DOS service function pointer |
| 32 | Pointer to NUL-terminated ASCII command tail |
| 40 | Pointer to double-NUL-terminated environment (`COMSPEC`, `PATH`) |
| 48 | Pointer to the runtime's current directory string |
| 56 | Process identifier (the image's load address) |

Validate the signature/version before using pointers. Keep the function pointer
in a callee-saved register; invoke it with `blr`. Set `w8` to the function number.
Arguments use `x0` onward, as listed below. Preserve AAPCS64 callee-saved
registers and 16-byte stack alignment. All structures are little endian.
The descriptor and its borrowed pointers are valid only during the launch.
[programs/native.S](programs/native.S) is a standalone executable example.

Unless specified otherwise, `x1=0` means success; `x1=1` means error with a DOS
error code in `x0`. Calls may clobber `x0`–`x18`, condition flags and vector
registers allowed by AAPCS64. All structures are little endian.

## Dispatched functions

Every number from `00h` to `6Ch` is dispatched (DISPATCH.ASM's table, in
[src/dispatch.S](src/dispatch.S)), plus the ARM DOS extension `E0h`; other
numbers above `6Ch` return error 1. A
failing call (`x1=1`) is recorded for `59h`. `tools/unit.py` checks that the
binary's table matches this list.

| Function | Arguments | Result / limits |
| --- | --- | --- |
| `00h` | None | Terminate with exit code 0 (as `4Ch`) |
| `01h` | None | `x0` input character, echoed to stdout |
| `02h` | `x0` character | `x0` character after stdout output |
| `03h` | None | `x0` byte from AUX (the console UART), no echo |
| `04h` | `x0` byte | Write to AUX |
| `05h` | `x0` byte | Write to PRN (discarded unless a printer target is set) |
| `06h` | `x0` character, or 255 to poll input | Input: `x0` character, `x2=1` if unavailable, otherwise 0 |
| `07h`, `08h` | None | `x0` input character without echo |
| `09h` | `x0` pointer | Print until `$` or NUL; `x0=24h` |
| `0Ah` | `x0` DOS line buffer | Byte 0 capacity, byte 1 count, bytes 2+ input followed by CR; capacity includes CR |
| `0Bh` | None | `x0=FFh` available, otherwise 0; console polling retains the character |
| `0Ch` | `x0` follow-up function, `x1` its argument | Flush console type-ahead; optional `01/06/07/08/0A` call |
| `0Dh` | None | Flush all writable open file objects (read-only ones are skipped) |
| `0Eh` | `x0` drive, zero based | Selects it if valid (else keeps the current drive); `x0` number of drives (LASTDRIVE) |
| `0Fh`, `10h` | `x0` FCB | Open / close; FCB status below |
| `11h`, `12h` | `x0` FCB with `?` wildcards | Find first / next 8.3 name in the current directory; result FCB in the DTA |
| `13h` | `x0` FCB with `?` wildcards | Delete every matching file; `x0=0` if any was deleted |
| `14h`, `15h` | `x0` open FCB | Sequential record read / write via DTA |
| `16h` | `x0` FCB | Create/truncate; an extended FCB supplies the attribute |
| `17h` | `x0` FCB: old name at 1, new name at 17 | Rename all matches; `?` in the new name keeps the old character |
| `18h`, `1Dh`, `1Eh`, `20h`, `61h`, `64h`, `6Bh` | None | Reserved (CP/M, network, IFS): `x0=0`, no effect |
| `19h` | None | Current drive in `x0` (0 = A:) |
| `1Ah` | `x0` DTA pointer, `x1` byte capacity | Select transfer/search buffer |
| `1Bh`, `1Ch` | `1Ch`: `x0` drive (0 default, 1 A:) | `x0` sectors per cluster, `x2` bytes per sector, `x3` clusters, `x4` media byte, `x5` pointer to it |
| `1Fh`, `32h` | `32h`: `x0` drive | `x0` native drive parameter block (below) |
| `21h`, `22h` | `x0` open FCB | Single random record read / write; random index unchanged |
| `23h` | `x0` FCB, nonzero record size | Store ceiling(file length / record size) in random record field |
| `24h` | `x0` FCB | Set random record from current block and sequential record |
| `25h`, `35h` | `x0` vector 0–255; `25h`: `x1` handler | Set / get (`x0`) a vector. 23h is called on Ctrl-C; 22h–24h are restored when a child ends |
| `26h`, `55h` | `x0` 64-byte destination | Copy the current descriptor (the PSP of this ABI); `55h` also makes the copy current |
| `27h`, `28h` | `x0` open FCB, `x1` record count | Random block read / write at the random record, which advances; `x2` records moved. `28h` with `x1=0` sets the file size |
| `29h` | `x0` string, `x1` FCB, `x2` control bits 0–3 | Parse a filename into the FCB; `x0` 0 / 1 wildcards / FFh bad drive, `x2` next character |
| `2Ah` | None | `x0` year, `x2` month, `x3` day, `x4` weekday (Sunday=0) |
| `2Bh` | `x0` year, `x1` month, `x2` day | Set date; 1980–2107 with leap-year validation. Also written to the real-time clock (see below) |
| `2Ch` | None | `x0` hour, `x2` minute, `x3` second, `x4` hundredths |
| `2Dh` | `x0` hour, `x1` minute, `x2` second, `x3` hundredths | Set time; also written to the real-time clock |
| `2Eh`, `54h` | `2Eh`: `x0` flag | Set / get (`x0`) the verify flag |
| `2Fh` | None | `x0` DTA pointer, `x2` capacity |
| `30h` | None | `x0=4`, minor version 0, `x2=0`, `x3=FFh` |

| `31h` | `x0` exit code, `x1` bytes to keep | Terminate and stay resident: the image and its blocks stay allocated; status type 3 |
| `33h` | `x0` 0 get / 1 set / 2 exchange / 5 boot drive, `x1` value | `x2` BREAK state (or boot drive 1). BREAK ON checks for Ctrl-C on every call |
| `34h` | None | `x0` InDOS byte, `x2` critical-error byte (both 0 while a program runs) |
| `36h` | `x0` drive (0 default, 1 A:) | `x0` unit bytes, `x2` free units, `x3` total units |
| `37h` | `x0` 0 get / 1 set (`x1`) / 2 / 3 | `x2` switch character (`/`); AVAILDEV `x2=FFh` |
| `38h` | `x0` 34-byte buffer, `x1` country (0 current) | Country information; `x0=0` selects country `x1` (loaded from COUNTRY.SYS if not built in). `x0=x2` country |
| `39h`, `3Ah`, `3Bh` | `x0` path | Create/remove/change directory |
| `3Ch` | `x0` path, `x1` R/H/S/A attributes | Create/truncate; `x0` handle |
| `3Dh` | `x0` path, `x1` open mode | `x0` handle. Mode bits 0–2 access, 4–6 sharing, 7 not inherited (below) |
| `3Eh` | `x0` handle | Close; the final reference releases the object, its sharing entry and locks |
| `3Fh`, `40h` | `x0` handle, `x1` buffer, `x2` byte count | `x0` bytes read/written; zero write truncates/extends at position; locked regions fail with error 33 |
| `41h` | `x0` path | Delete a file; open files and devices fail with error 5 |
| `42h` | `x0` handle, `x1` signed offset, `x2` origin 0/1/2 | `x0` resulting position |
| `43h` | `x0` path, `x1` get 0/set 1, `x2` attributes | Get returns attributes in `x0` |
| `44h` | `x0` handle or drive, `x1` subfunction, `x2`, `x3` | IOCTL 00h–0Fh (below) |
| `45h`, `46h` | `x0` source handle; `46h`: `x1` destination | Duplicate / force duplicate; an unredirected 0–2 duplicates as CON |
| `47h` | `x0` output pointer, `x1` capacity, `x2` drive (0 default, 1 A:) | That drive's current path without drive or leading slash |
| `48h` | `x0` byte size | `x0` allocation; 64 slots, 16 MiB maximum request; 64 KiB granules |
| `49h` | `x0` allocation | Free an owned block (error 9 otherwise) |
| `4Ah` | `x0` allocation, `x1` byte size | Resize in place within reserved capacity; error 8 includes capacity in `x2` |
| `4Bh` | `x0` path, `x1` command tail, `x2` mode | Mode 0 load and run; 1 load only; 3 overlay at `x3` (4 KiB aligned, `x4` bytes). Modes 1/3 return `x0` base, `x2` entry, `x3` size |
| `4Ch` | `x0` exit code | Terminate current child (does not return); root call fails |
| `4Dh` | None | `x0` last child status: exit code low byte, termination type high byte (0 normal, 1 Ctrl-C, 2 exception, 3 resident); clears it |
| `4Eh`, `4Fh` | First: `x0` pattern, `x1` attribute mask; next: none | Find via current DTA; error 18 at exhaustion; 16 independent contexts |
| `50h`, `51h`, `62h` | `50h`: `x0` descriptor (0 clears) | Set / get (`x0`, `x2`) the current descriptor |
| `52h` | None | `x0` list of lists (below) |
| `53h` | `x0` BPB (bytes per sector first), `x1` 64-byte DPB | Build a drive parameter block |
| `56h` | `x0` old path, `x1` new path | Rename/move; open files fail with error 5 |
| `57h` | `x0` handle, `x1` get 0/set 1, `x2` date, `x3` time | Get returns packed date/time in `x2/x3` |
| `58h` | `x0` 0 get / 1 set, `x1` 0 first / 1 best / 2 last fit | Allocation strategy (native arena; firmware mode lets UEFI place pages) |
| `59h` | None | `x0` last error, `x2` class, `x3` suggested action, `x4` locus |
| `5Ah` | `x0` directory buffer (13 spare bytes), `x1` attributes | Create a uniquely named file; name appended to the buffer; `x0` handle |
| `5Bh` | `x0` path, `x1` attributes | Create new; existing path returns error 80 |
| `5Ch` | `x0` 0 lock / 1 unlock, `x1` handle, `x2` offset, `x3` length | Record locks: overlaps fail with 33; unlock must match exactly; 32 locks |
| `5Dh` | `x0` subfunction | 01h commit all; 06h `x0` swappable data area, `x2` size; 0Ah set extended error (`x1` code, `x2` class, `x3` action, `x4` locus); others need a network (error 1) |
| `5Eh`, `5Fh` | `x0` subfunction | No network: `5E00h` returns `x2=0`; `5F02h` returns error 18; others error 1 |
| `60h` | `x0` path, `x1` 128-byte buffer | TRUENAME: `A:\DIR\FILE` upper case, `A:/NUL` for devices |
| `63h` | `x0` subfunction | 0: `x0` the lead-byte ranges of the code page (empty for 437 and 850) |
| `65h` | `x0` id, `x1` code page, `x2` country, `x3` buffer, `x4` size | Extended country information and case mapping (below) |
| `66h` | `x0` 1 get / 2 set, `x1` code page | `x2` active, `x3` system code page; set loads the current country's tables in that code page from COUNTRY.SYS (error 2 if it has none) |
| `67h` | `x0` handle count | Up to 32 per process; more returns error 8 |
| `68h`, `6Ah` | `x0` handle | Flush/commit (no-op success on a read-only handle) |
| `69h` | `x0` 0 get / 1 set, `x1` drive, `x2` 25-byte buffer | Media ID: u16 level 0, u32 serial, 11-byte label, 8-byte file system type (from the boot record) |
| `6Ch` | `x0` path, `x1` open mode, `x2` attributes, `x3` action | Extended open/create; `x2` 1 opened, 2 created, 3 replaced |
| `E0h` | `x0` subfunction 0–6 | ARM DOS extension: raw disk services for INSTALL (below) |

Date and time (`src/clock.S`): the clock is loaded from the real-time clock at
boot, and `2Bh`/`2Dh` (so also `DATE`, `TIME` and `CLOCK$` writes) store it
back, so a setting survives a reboot. Native mode on QEMU `virt` uses the
PL031 directly (09010000h, used only when the ACPI OEM ID is QEMU's and the
PrimeCell ID registers match); firmware mode uses UEFI `GetTime`/`SetTime`.
Native mode on other boards (no PL031 at that address) and on the
Raspberry Pi 3 (no battery-backed RTC) keeps the firmware's boot-time value
and nothing persists. The RTC is read as local
time (DOS has no time zones); RTC values before 1980 read as 1980-01-01, and
in native mode dates after 2106-02-07 06:28 (the 32-bit PL031 limit) last
only until reboot; in firmware mode the limit is whatever `SetTime` accepts.
Firmware mode keeps the firmware's own TimeZone/Daylight settings.
Hundredths come from the generic timer and are not stored.

### Disk services (E0h, ARM DOS extension)

DOS reached whole disks through INT 13h; this call stands in for it while
UEFI boot services run (firmware mode, as on the live ISO). A disk is a
firmware Block I/O device that is a whole disk, present, writable, at least
8 MiB, with 512–4096-byte power-of-two blocks and an IoAlign of at most
4 KiB, and provably not the disk ARM DOS booted from: its device path is
readable and not a prefix of the boot partition's. If the boot device's path
cannot be read, no disk is offered. `INSTALL.EXE` is the user.

| `x0` | Arguments | Result |
| --- | --- | --- |
| 0 | None | Finds the disks; `x0` their count |
| 1 | `x1` disk, `x2` 32-byte buffer | u64 block size, u64 blocks, u64 flags (1 removable), u64 0 |
| 2, 3 | `x1` disk, `x2` first block, `x3` blocks, `x4` buffer | Read / write (any alignment; 64 KiB at a time through a kernel buffer). The range must lie on the disk. These bypass the FAT sector cache |
| 4 | `x1` disk, `x2` first block, `x3` blocks | Attaches that range (a partition) as a drive letter, as a block device driver's unit; `x0` the drive (0 = A:). The same range attached again returns its drive (re-reading its boot record); a range overlapping an attached one fails. Up to 4 per boot. The drive cannot reach outside the range, and a boot record claiming more sectors than the range is not mounted. FORMAT then works on it |
| 5 | `x1` disk | Flush the disk's write cache |
| 6 | As 4 | Probe: changes nothing; `x0` the drive 4 would return, or the error it would give |

Under the native kernel the same calls work over the kernel's disk table
(below): the disks are the registered ones other than the boot disk, in
registration order; attached ranges share the table of fixed-disk volumes
mounted at boot (so a disk whose volumes are drive letters cannot be
repartitioned: error 5), drives start at C:, a disk needs no minimum size,
subfunction 5 does nothing (writes are complete when they return) and there
is no MediaId check.

Disk numbers count from 0 in the order of the last subfunction 0 (the
firmware's order). Each disk's MediaId is recorded by subfunction 0 and each
partition's by subfunction 4: a transfer to a different or missing medium
fails with error 34 (invalid disk change), and a write to a now read-only one
with error 19. Other errors: 1 bad subfunction, 15 bad disk number or no
drive letter left, 21 device error, 87 a range outside the disk, 4 no attach
slot or volume left, 5 the range overlaps an attached one, 8 no sector cache.

### Native disk table and fixed-disk drive letters

After `ExitBootServices` the kernel keeps a table of whole disks
([src/blk.S](src/blk.S)). `blk_init` registers the boot disk (virtio-blk)
and every other virtio-blk PCI device; other kernel backends (USB mass
storage) register theirs with `disk_register`, a kernel-internal call:

| Register | `disk_register` argument |
| --- | --- |
| `x0` | `rw` function (below) |
| `x1` | Sector count |
| `x2` | Context, passed back to `rw` in `x4` |
| `x3` | Sector size: 0 (512), or 512–4096, a power of two |
| `x4` | Flags: bit 1 removable (reported by E0h subfunction 1); bit 0 is the boot disk's |

It returns `x0` = the disk number with `x1=0`, or `x1=1` with `x0` 4 (table
full, 8 disks) or 87 (bad argument). Before returning it scans the disk and
mounts its FAT volumes. `rw` is called as `rw(x0 first sector, x1 count,
x2 buffer, w3 0 read / 1 write, x4 context)` and returns `x0=0` or nonzero on
a device error, under AAPCS64 (`x0`–`x18` may be clobbered). The layer
guarantees `count >= 1`, a range on the disk, a 4 KiB-aligned buffer and at
most 64 KiB per call. A write must be complete when `rw` returns; nothing
flushes later.

Scan rules: an MBR's primary partitions of type 01h, 04h, 06h, 0Bh, 0Ch,
0Eh or EFh and the logical drives of an extended partition (05h, 0Fh); with
a protective MBR (EEh), the GPT's EFI System and Basic Data partitions; a
disk whose sector 0 is a FAT boot record is mounted whole. A partition is
mounted only when it lies on the disk and starts with a FAT boot record; on
the boot disk the boot volume itself is skipped. Every field is checked
against the disk size; an EBR chain must move forward and stops after 16
links; at most 128 GPT entries are read (CRCs are not checked).

Drive letters: A: is the boot volume. Fixed-disk volumes take the first free
letter from C: upward, at boot before `CONFIG.SYS`: the boot disk's other
partitions, then each further disk in PCI order, partitions in table order.
B: stays free for the first `CONFIG.SYS` block driver (DOS kept it for the
second floppy); RAMDRIVE and VDISK then take the letters left after the
disks. As for block drivers, letters go past LASTDRIVE when needed. Up to
16 ranges and 16 FAT volumes in all. Each mounted volume is reported at
boot as `Drive C: is disk 1, partition 2` (disk 0 is the boot disk; logical
drives count from 5, GPT entries from 1).

### Devices

`CON`, `AUX` (also `COM1`), `PRN` (also `LPT1`), `NUL` and `CLOCK$` open from
any directory and with any extension, as in DOS. Handles 3 and 4 start as AUX
and PRN. AUX shares the console UART; PRN output is discarded until a printer
target is selected. `CLOCK$` reads and writes six bytes: u16 days since
1980-01-01, minutes, hours, hundredths, seconds. Raw console input ignores
scan-only keys and uses ASCII line editing. Ctrl-C read from the console
calls vector 23h if set (returning `x0=0` continues); otherwise it ends the
running program with termination type 1. At the shell prompt it discards the
line.

### Open modes, sharing and locks

Access is 0 read, 1 write, 2 both. Sharing is 0 compatibility (treated as deny
none), 1 deny all, 2 deny write, 3 deny read, 4 deny none; a conflicting open
fails with error 32. Bit 7 keeps the handle out of child processes. Other bits
fail with error 12. `6Ch` also accepts bits 13–14 (critical-error and
commit-on-write; writes are always flushed). SHARE is built in: deleting or
renaming an open file fails with error 5. Locks belong to an open object and a
process: reads and writes through any other handle or process fail with error 33.
Process exit releases its locks.

### IOCTL (44h)

| Subfunction | Meaning |
| --- | --- |
| 00h | Device information in `x0`/`x2`: files 0; devices 80h plus 40h, 10h CON, 8 CLOCK$, 4 NUL, 2/1 standard output/input; unredirected handles 81h/82h |
| 01h | Set device information from `x2` (devices only; only raw bit 20h changes; DH must be 0) |
| 02h–05h, 0Ch | Control strings: no driver accepts them (error 1) |
| 06h, 07h | Input / output status: `x0=FFh` ready |
| 08h | `x0` drive: `x0=1` fixed (every drive, RAM disks included) |
| 09h, 0Ah | Remote drive / handle: `x2=0` (local) |
| 0Bh | Sharing retry count: accepted |
| 0Dh | `x0` drive, `x2` 0866h get / 0846h set media ID, `x3` buffer (as `69h`); 0860h, 0861h, 0841h, 0840h (below) |
| 0Eh, 0Fh | Logical drive map: `x0=0` (one letter per drive) |

### Drive parameter block and list of lists

The 64-byte DPB keeps the DOS 4.0 layout for bytes 0–32 (drive, unit, bytes
per sector, cluster mask and shift, first FAT sector, FAT count, root entries,
first data sector, highest cluster, sectors per FAT, first root sector,
device pointer 0, media, access flag, next DPB FFFFFFFFh, next free hint, free
count FFFFh unknown; 16-bit fields saturate) and adds 32-bit fields: 40
sectors per FAT, 44 first data sector, 48 highest cluster, 52 root cluster,
56 FAT type (12/16/32), 60 total sectors.

The list of lists (144 bytes): 0 DPB pointer, 8 handle table, 16 CLOCK$
device, 24 CON device, 32 u16 largest sector, 34 u8 block devices, 35 u8
LASTDRIVE, 40 NUL device, 48 current directory string, 56 u64 BUFFERS,
64 u64 FILES, 72 memory block table (the native MCB chain: entries of u64
base, size, reserved capacity, owner; base 0 is unused), 80 its entry count,
88 native arena bytes, 96 free arena bytes (both 0 in firmware mode), 104 the
kernel's owner id, 112 APPEND state (u64 flags: 1 list set, 2 /X, 4 /PATH,
8 /E; then the ASCIIZ path list), 120 environment size, 128 drive table, 136
u64 entries in it (26). Owners are the image base of a program (its
descriptor +56).

Each drive table entry is 512 bytes: 0 flags (1 physical drive, 2 SUBST, 4
joined into another drive), 8 root object (0 when unformatted), 16 FAT volume
slot, 24 the physical drive behind SUBST or JOIN, 32 ASSIGN target + 1 (0
none), 40 block driver `rw` entry (0 for the boot disk), 64 SUBST target or
JOIN host path, 256 the drive's current directory (`\...`). SUBST, JOIN and
ASSIGN edit the table directly, as the DOS utilities edited the CDS. Path
resolution applies ASSIGN, then refuses a joined drive, then resolves `.`,
`..` and the current directory, then SUBST and JOIN prefixes.

IOCTL 0Dh also takes 0860h (`x3` 96-byte buffer: u64 bytes per sector,
sectors per cluster, FAT type, first data sector, clusters, first FAT sector,
sectors per FAT, FAT copies, first root sector, root entries, root cluster,
total sectors of the device; FAT type 0 means unformatted), 0840h (re-read the
boot record after FORMAT),
and 0861h / 0841h, read / write sectors, with `x3` pointing to u64 first
sector (volume relative), count, and buffer. They go through the sector
cache, as INT 25h/26h did for CHKDSK, FORMAT, SYS, LABEL and RECOVER.

### Country information (38h, 65h)

The 38h block is 34 bytes: u16 date format (0 M/D/Y, 1 D/M/Y, 2 Y/M/D),
currency symbol (5 bytes), thousands, decimal, date and time separators
(2 bytes each), currency format, currency digits, time format (0 12-hour,
1 24-hour), four zero bytes where DOS kept a far case-map pointer, data-list
separator, ten reserved bytes. Built in (code page 437): 1, 3, 31, 32, 33,
34, 39, 41, 44, 46, 49, 61 and 358.

`\COUNTRY.SYS` is the DOS 4.0 file, assembled at build time from
`data/country/MKCNTRY.ASM` (the data segment of the MS-DOS 4.0 source) by `tools/mkcntry.py`: 46 country and code
page pairs (437, 850, 860, 862-865 and the DBCS pages 932-938) with their
country information, case maps, file-name characters, collating sequences
and DBCS tables. `COUNTRY=nnn[,cp][,file]` loads from it (default
`A:\COUNTRY.SYS`; without the file the built-in records are used), and `66h`
(`CHCP`) and `38h` reload from it as NLSFUNC did.

`65h` ids: 01h returns id, u16 size 38, u16 country, u16 code page and the 34
bytes (41 bytes, truncated to `x4`); 02h upper case, 04h file-name upper case,
05h file-name characters, 06h collating and 07h DBCS return the id and a u64
pointer to a table that starts with its u16 length (9 bytes). 20h upper-cases
the character `x1` into `x0`; 21h a buffer (`x1`, `x2` bytes); 22h an ASCIIZ
string (`x1`); 23h classifies `x1` as 0 no, 1 yes, 2 neither.

## CONFIG.SYS and installable device drivers

`\CONFIG.SYS` is read once at boot, before `AUTOEXEC.BAT`. Keywords:
`BREAK=ON|OFF`, `BUFFERS=n` (1–99; up to 32 4 KiB sector buffers are cached,
the value is reported by `52h`), `COUNTRY=nnn[,cp][,file]` (from COUNTRY.SYS, below), `DEVICE=path [args]`,
`FCBS=` and `STACKS=` (accepted; no fixed tables to size), `FILES=n` (8–255,
open files at once, at most 64; the standard devices use no entries),
`INSTALL=path [args]` (run after every driver has loaded), `LASTDRIVE=x`,
`REM`, `SHELL=path [args]` (sets `COMSPEC`; anything other than the built-in
COMMAND, `\EFI\BOOT\BOOTAA64.EFI` or a name `COMMAND.COM`, runs instead of
COMMAND and `AUTOEXEC.BAT`, and the built-in shell takes over when it exits).
Unknown keywords and bad values print `Error in CONFIG.SYS line n`.

A `DEVICE=` driver is a native PE32+ image like a program. It stays resident.
Its entry point is called once with `x0` pointing to a 96-byte init request:

| Offset | In/out | Meaning |
| --- | --- | --- |
| 0 | in | `dos_call` entry (same ABI as for programs) |
| 8 | in | ASCIIZ arguments after the driver path (kept while resident) |
| 16 | out | Device name, up to 7 characters, NUL padded |
| 24 | out | `read(x0 buffer, x1 count)` returning `x0` bytes (0 = end of file) |
| 32 | out | `write(x0 buffer, x1 count)` returning `x0` bytes written |
| 40 | out | Device information word (44h/00h); 80h is always set |
| 48 | out | Block device: total sectors (nonzero makes it a drive) |
| 56 | out | Block device: bytes per sector |
| 64 | in | Block device: the drive it will get (0 = A:) |
| 72 | in | `putc(w0 byte)`: the console UART itself |
| 80 | in | `poll()`: the next key from the UART in `x0`, or 0 (non-blocking) |

A block device (RAMDRIVE.SYS, VDISK.SYS) sets +48 and puts
`rw(x0 sector, x1 buffer, x2 count, x3 0 read / 1 write)`, returning `x0=0`
or nonzero on a device error, at +24. It becomes the next free drive letter up to LASTDRIVE; the
kernel mounts its FAT volume (up to 16 volumes) or leaves it for FORMAT.

The entry returns `x1=0` to install or `x1=1` to refuse. A driver named after
a standard device (`CON`, `AUX`, `PRN`, `NUL`, `CLOCK$`) takes over that
device's reads and writes; any other name adds a device that opens like a file
from any directory, with any extension. Up to 11 drivers can be added.
Functions may be left 0 (reads then report end of file, writes discard).

A driver that takes over `CON` (ANSI.SYS) sees every console byte: COMMAND's
output, `02h`, `06h`, `09h` and handle writes all reach its `write`. Its
`read(buffer, 1)` is called for one key at a time and must not block (return
0 when no key is waiting); the kernel keeps doing line editing on top of it.
Such a driver writes to the screen and reads keys through +72 and +80, never
through DOS calls. PRINTER.SYS takes over `PRN` the same way.

## DTA and FCB layout

For searches, the DTA must contain at least 280 bytes: u64 attributes at 0,
u64 size at 8, u16 packed DOS time at 16, u16 date at 18, four reserved bytes at
20, and ASCII filename[256] at 24. `*`/`?` matching is case insensitive;
`*.*` includes extensionless names. Hidden/system/directory entries require
selection bits 2/4/16. Non-ASCII filenames are skipped. Exhaustion or replacement
of a search releases its firmware object; process exit closes owned searches.

FCBs use the standard 37-byte layout, drive 0 (default) or 1 (A:), space-padded
8.3 name fields, current block at 12, record size at 14, file size at 16, date/
time at 20/22, current record at 32, random record at 33. Reserved bytes 24–27
store a handle/signature and must be preserved. Open/create initialize record
size to 128; callers may change it. These calls return `x1=0` with AL-style
status in `x0`: 0 complete, 1 EOF, 2 DTA too small, 3 partial record with zero
padding, FFh failure. Other listed FCB operations use 0/FFh. Every FCB call
accepts an extended FCB (FFh, five reserved bytes, attribute, then the FCB);
the attribute selects hidden, system and directory entries for searches, and
attribute 8 alone finds the volume label. FCB searches see only names with an
8.3 form; a search result is drive byte 1 plus the 32-byte directory entry
(name, attribute, time, date, size; cluster 0), preceded by the 7-byte header
for extended FCBs.

The native child starts with a private 280-byte DTA and inherited file
references. On return/4Ch, the parent reclaims child arenas/files/searches and
restores its descriptors, DTA pointer/capacity and process owner. Inherited
objects retain their shared file position. Current-directory changes are global.
Firmware image validation/loading replaces DOS's original MZ/relocation loader.
