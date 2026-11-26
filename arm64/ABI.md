# Native AArch64 DOS ABI, version 2

This ABI adapts selected DOS 4.0 public operations to flat pointers and AAPCS64.
It does not run x86 DOS binaries or recreate segment registers, interrupt 21h,
the original PSP, or DOS memory-control blocks. Programs run at the kernel's
privilege level (EL1) in one flat address space, like DOS programs share real
mode. Resource ownership provides cleanup, not memory isolation. A CPU
exception in a program terminates that program (termination type 2).

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
[src/dispatch.S](src/dispatch.S)); numbers above `6Ch` return error 1. A
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
| `0Eh` | `x0` drive, zero based | Only A: (0); result `x0=1` configured drive |
| `0Fh`, `10h` | `x0` FCB | Open / close; FCB status below |
| `11h`, `12h` | `x0` FCB with `?` wildcards | Find first / next 8.3 name in the current directory; result FCB in the DTA |
| `13h` | `x0` FCB with `?` wildcards | Delete every matching file; `x0=0` if any was deleted |
| `14h`, `15h` | `x0` open FCB | Sequential record read / write via DTA |
| `16h` | `x0` FCB | Create/truncate; an extended FCB supplies the attribute |
| `17h` | `x0` FCB: old name at 1, new name at 17 | Rename all matches; `?` in the new name keeps the old character |
| `18h`, `1Dh`, `1Eh`, `20h`, `61h`, `64h`, `6Bh` | None | Reserved (CP/M, network, IFS): `x0=0`, no effect |
| `19h` | None | Default drive `x0=0` (A:) |
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
| `2Bh` | `x0` year, `x1` month, `x2` day | Set runtime date; 1980–2107 with leap-year validation |
| `2Ch` | None | `x0` hour, `x2` minute, `x3` second, `x4` hundredths |
| `2Dh` | `x0` hour, `x1` minute, `x2` second, `x3` hundredths | Set runtime time |
| `2Eh`, `54h` | `2Eh`: `x0` flag | Set / get (`x0`) the verify flag |
| `2Fh` | None | `x0` DTA pointer, `x2` capacity |
| `30h` | None | `x0=4`, minor version 0, `x2=0`, `x3=FFh` |
| `31h` | `x0` exit code, `x1` bytes to keep | Terminate and stay resident: the image and its blocks stay allocated; status type 3 |
| `33h` | `x0` 0 get / 1 set / 2 exchange / 5 boot drive, `x1` value | `x2` BREAK state (or boot drive 1). BREAK ON checks for Ctrl-C on every call |
| `34h` | None | `x0` InDOS byte, `x2` critical-error byte (both 0 while a program runs) |
| `36h` | `x0` drive (0 default, 1 A:) | `x0` unit bytes, `x2` free units, `x3` total units |
| `37h` | `x0` 0 get / 1 set (`x1`) / 2 / 3 | `x2` switch character (`/`); AVAILDEV `x2=FFh` |
| `38h` | `x0` 34-byte buffer, `x1` country (0 current) | Country information; `x0=0` selects country `x1`. `x0=x2` country |
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
| `47h` | `x0` output pointer, `x1` capacity | Current path without drive or leading slash |
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
| `63h` | `x0` subfunction | 0: `x0` empty lead-byte table (no DBCS in code page 437) |
| `65h` | `x0` id, `x1` code page, `x2` country, `x3` buffer, `x4` size | Extended country information and case mapping (below) |
| `66h` | `x0` 1 get / 2 set, `x1` code page | `x2` active, `x3` system code page: 437 only |
| `67h` | `x0` handle count | Up to 32 per process; more returns error 8 |
| `68h`, `6Ah` | `x0` handle | Flush/commit (no-op success on a read-only handle) |
| `69h` | `x0` 0 get / 1 set, `x1` drive, `x2` 25-byte buffer | Media ID: u16 level 0, u32 serial, 11-byte label, 8-byte file system type (from the boot record) |
| `6Ch` | `x0` path, `x1` open mode, `x2` attributes, `x3` action | Extended open/create; `x2` 1 opened, 2 created, 3 replaced |

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
| 08h | `x0` drive: `x0=1` fixed |
| 09h, 0Ah | Remote drive / handle: `x2=0` (local) |
| 0Bh | Sharing retry count: accepted |
| 0Dh | `x0` drive, `x2` 0866h get / 0846h set media ID, `x3` buffer (as `69h`); 0860h, 0861h, 0841h (below) |
| 0Eh, 0Fh | Logical drive map: `x0=0` (one letter per drive) |

### Drive parameter block and list of lists

The 64-byte DPB keeps the DOS 4.0 layout for bytes 0–32 (drive, unit, bytes
per sector, cluster mask and shift, first FAT sector, FAT count, root entries,
first data sector, highest cluster, sectors per FAT, first root sector,
device pointer 0, media, access flag, next DPB FFFFFFFFh, next free hint, free
count FFFFh unknown; 16-bit fields saturate) and adds 32-bit fields: 40
sectors per FAT, 44 first data sector, 48 highest cluster, 52 root cluster,
56 FAT type (12/16/32), 60 total sectors.

The list of lists (112 bytes): 0 DPB pointer, 8 handle table, 16 CLOCK$
device, 24 CON device, 32 u16 largest sector, 34 u8 block devices, 35 u8
LASTDRIVE, 40 NUL device, 48 current directory string, 56 u64 BUFFERS,
64 u64 FILES, 72 memory block table (the native MCB chain: entries of u64
base, size, reserved capacity, owner; base 0 is unused), 80 its entry count,
88 native arena bytes, 96 free arena bytes (both 0 in firmware mode), 104 the
kernel's owner id. Owners are the image base of a program (its descriptor
+56).

IOCTL 0Dh also takes 0860h (`x3` 88-byte buffer: u64 bytes per sector,
sectors per cluster, FAT type, first data sector, clusters, first FAT sector,
sectors per FAT, FAT copies, first root sector, root entries, root cluster),
and 0861h / 0841h, read / write sectors, with `x3` pointing to u64 first
sector (volume relative), count, and buffer. They go through the sector
cache, as INT 25h/26h did for CHKDSK, FORMAT, SYS, LABEL and RECOVER.

### Country information (38h, 65h)

The 38h block is 34 bytes: u16 date format (0 M/D/Y, 1 D/M/Y, 2 Y/M/D),
currency symbol (5 bytes), thousands, decimal, date and time separators
(2 bytes each), currency format, currency digits, time format (0 12-hour,
1 24-hour), four zero bytes where DOS kept a far case-map pointer, data-list
separator, ten reserved bytes. Countries: 1, 3, 31, 32, 33, 34, 39, 41, 44,
46, 49, 61 and 358, all code page 437 (data from COUNTRY.SYS).

`65h` ids: 01h returns id, u16 size 38, u16 country, u16 code page and the 34
bytes (41 bytes, truncated to `x4`); 02h upper case, 04h file-name upper case,
05h file-name characters, 06h collating and 07h DBCS return the id and a u64
pointer to a table that starts with its u16 length (9 bytes). 20h upper-cases
the character `x1` into `x0`; 21h a buffer (`x1`, `x2` bytes); 22h an ASCIIZ
string (`x1`); 23h classifies `x1` as 0 no, 1 yes, 2 neither.

## CONFIG.SYS and installable device drivers

`\CONFIG.SYS` is read once at boot, before `AUTOEXEC.BAT`. Keywords:
`BREAK=ON|OFF`, `BUFFERS=n` (1–99; up to 32 4 KiB sector buffers are cached,
the value is reported by `52h`), `COUNTRY=nnn` (as `38h`), `DEVICE=path [args]`,
`FCBS=` and `STACKS=` (accepted; no fixed tables to size), `FILES=n` (8–255,
open files at once, at most 64; the standard devices use no entries),
`INSTALL=path [args]` (run after every driver has loaded), `LASTDRIVE=x`,
`REM`, `SHELL=path [args]` (sets `COMSPEC`; anything other than the built-in
COMMAND, `\EFI\BOOT\BOOTAA64.EFI` or a name `COMMAND.COM`, runs instead of
COMMAND and `AUTOEXEC.BAT`, and the built-in shell takes over when it exits).
Unknown keywords and bad values print `Error in CONFIG.SYS line n`.

A `DEVICE=` driver is a native PE32+ image like a program. It stays resident.
Its entry point is called once with `x0` pointing to a 64-byte init request:

| Offset | In/out | Meaning |
| --- | --- | --- |
| 0 | in | `dos_call` entry (same ABI as for programs) |
| 8 | in | ASCIIZ arguments after the driver path (kept while resident) |
| 16 | out | Device name, up to 7 characters, NUL padded |
| 24 | out | `read(x0 buffer, x1 count)` returning `x0` bytes (0 = end of file) |
| 32 | out | `write(x0 buffer, x1 count)` returning `x0` bytes written |
| 40 | out | Device information word (44h/00h); 80h is always set |

The entry returns `x1=0` to install or `x1=1` to refuse. A driver named after
a standard device (`CON`, `AUX`, `PRN`, `NUL`, `CLOCK$`) takes over that
device's reads and writes; any other name adds a device that opens like a file
from any directory, with any extension. Up to 11 drivers can be added.
Functions may be left 0 (reads then report end of file, writes discard).

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
