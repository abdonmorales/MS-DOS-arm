# Native AArch64 DOS ABI, version 1

This ABI adapts selected DOS 4.0 public operations to flat pointers and AAPCS64.
It does not run x86 DOS binaries or recreate segment registers, interrupt 21h,
the original PSP, or DOS memory-control blocks. Runtime services require UEFI
Boot Services; programs run at the firmware's privilege level in one address
space. Resource ownership provides cleanup, not memory isolation.

## Program entry and API discovery

Programs are position-independent AArch64 PE32+ UEFI applications (machine
`0xaa64`, optional-header magic `0x20b`, subsystem 10), conventionally named
`.EXE`. Their entry receives `x0=EFI image handle`, `x1=EFI system table`.
Obtain `EFI_LOADED_IMAGE_PROTOCOL` for the handle through `HandleProtocol`.
Its `LoadOptionsSize` is at byte 48 and `LoadOptions` at 56. The DOS loader
installs this 64-byte descriptor:

| Offset | Value |
| --- | --- |
| 0 | Eight signature bytes `ARMDOS64` |
| 8 | ABI version, u64 = 1 |
| 16 | Descriptor size, u64 = 64 |
| 24 | AAPCS64 DOS service function pointer |
| 32 | Pointer to NUL-terminated ASCII command tail |
| 40 | Pointer to double-NUL-terminated environment (`COMSPEC`, `PATH`) |
| 48 | Pointer to the runtime's current directory string |
| 56 | Child's EFI image handle |

Validate the signature/version before using pointers. Keep the function pointer
in a callee-saved register; invoke it with `blr`. Set `w8` to the function number.
Arguments use `x0` onward, as listed below. Preserve AAPCS64 callee-saved
registers and 16-byte stack alignment. All structures are little endian.
The descriptor and its borrowed pointers are valid only during the launch.
[programs/native.S](programs/native.S) is a standalone executable example.

Unless specified otherwise, `x1=0` means success; `x1=1` means error with a DOS
error code in `x0`. Calls may clobber `x0`–`x18`, condition flags and vector
registers allowed by AAPCS64. Unlisted functions return error 1. No flags are
silently accepted for sharing, locking, devices or unsupported subfunctions.

## Dispatched functions

These 57 numbers are implemented to the limits below; this count does not
measure completion of the original operating system.

| Function | Arguments | Result / limits |
| --- | --- | --- |
| `01h` | None | `x0` input character, echoed to stdout |
| `02h` | `x0` character | `x0` character after stdout output |
| `06h` | `x0` character, or 255 to poll input | Input: `x0` character, `x2=1` if unavailable, otherwise 0 |
| `07h`, `08h` | None | `x0` input character without echo |
| `09h` | `x0` pointer | Print until `$` or NUL; `x0=24h` |
| `0Ah` | `x0` DOS line buffer | Byte 0 capacity, byte 1 count, bytes 2+ input followed by CR; capacity includes CR |
| `0Bh` | None | `x0=FFh` available, otherwise 0; console polling retains the character |
| `0Ch` | `x0` follow-up function, `x1` its argument | Flush firmware keyboard; optional `01/06/07/08/0A` call |
| `0Dh` | None | Flush all open file objects |
| `0Eh` | `x0` drive, zero based | Only A: (0); result `x0=1` configured drive |
| `0Fh`, `10h` | `x0` standard FCB | Open / close; FCB status below |
| `13h` | `x0` standard FCB | Delete exact filename; no wildcards |
| `14h`, `15h` | `x0` open FCB | Sequential record read / write via DTA |
| `16h` | `x0` standard FCB | Create/truncate, attributes zero |
| `19h` | None | Default drive `x0=0` (A:) |
| `1Ah` | `x0` DTA pointer, `x1` byte capacity | Select transfer/search buffer |
| `21h`, `22h` | `x0` open FCB | Single random record read / write; random index unchanged |
| `23h` | `x0` standard FCB, nonzero record size | Store ceiling(file length / record size) in random record field |
| `24h` | `x0` FCB | Set random record from current block and sequential record |
| `2Ah` | None | `x0` year, `x2` month, `x3` day, `x4` weekday (Sunday=0) |
| `2Bh` | `x0` year, `x1` month, `x2` day | Set runtime date; 1980–2107 with leap-year validation |
| `2Ch` | None | `x0` hour, `x2` minute, `x3` second, `x4` hundredths |
| `2Dh` | `x0` hour, `x1` minute, `x2` second, `x3` hundredths | Set runtime time; does not write firmware clock |
| `2Fh` | None | `x0` DTA pointer, `x2` capacity |
| `30h` | None | `x0=4`, minor version 0, `x2=0`, `x3=FFh`; compatibility state absent |
| `36h` | `x0` drive (0 default, 1 A:) | `x0` firmware unit bytes, `x2` free units, `x3` total units; no fabricated FAT geometry |
| `39h`, `3Ah`, `3Bh` | `x0` path | Create/remove/change directory; removal requires empty, non-root directory |
| `3Ch` | `x0` path, `x1` R/H/S/A attributes | Create/truncate; `x0` handle |
| `3Dh` | `x0` path, `x1` mode 0 read / 1 write / 2 both | `x0` handle; sharing flags rejected |
| `3Eh` | `x0` handle | Close; final reference releases firmware object |
| `3Fh`, `40h` | `x0` handle, `x1` buffer, `x2` byte count | `x0` bytes read/written; zero write truncates/extends at position |
| `41h` | `x0` path | Delete exact file; directories rejected |
| `42h` | `x0` handle, `x1` signed offset, `x2` origin 0/1/2 | `x0` resulting position; negative/overflow rejected; reads beyond EOF return zero |
| `43h` | `x0` path, `x1` get 0/set 1, `x2` attributes | Get returns attributes in `x0`; set accepts R/H/S/A |
| `44h` | `x0` handle, `x1` subfunction 0/6/7 | Device info / input ready / output ready; other subfunctions rejected |
| `45h`, `46h` | `x0` source handle; `46h`: `x1` destination | Duplicate / force duplicate; shared object/position; default console duplication pending |
| `47h` | `x0` output pointer, `x1` capacity | Current path without drive or leading slash; `x0` output pointer |
| `48h` | `x0` byte size | `x0` allocation; 64 slots, 16 MiB maximum request; reserves 64 KiB granules |
| `49h` | `x0` allocation | Free owned arena; interior/unowned/double-free rejected (error 9) |
| `4Ah` | `x0` allocation, `x1` byte size | Resize in place within reserved capacity; error 8 includes capacity in `x2` |
| `4Bh` | `x0` executable path, `x1` command-tail pointer | Load/run native PE; x86/malformed images error 11; no load-only/overlay modes |
| `4Ch` | `x0` exit code | Terminate current child (does not return); root call fails |
| `4Dh` | None | `x0` last child status (exit code low byte, termination type high byte); clears it |
| `4Eh`, `4Fh` | First: `x0` pattern, `x1` attribute mask; next: none | Find via current DTA; error 18 at exhaustion; 16 independent contexts |
| `56h` | `x0` old path, `x1` new path | Firmware rename/move |
| `57h` | `x0` handle, `x1` get 0/set 1, `x2` packed date, `x3` packed time | Get returns packed date/time in `x2/x3`; set validates values |
| `5Bh` | `x0` path, `x1` attributes | Create new, existing path returns error 80; single-task runtime, no concurrent exclusive-open guarantee |
| `68h` | `x0` handle | Flush/commit |

Raw console input ignores scan-only keys, uses ASCII line editing and does not
yet implement DOS Ctrl-C/break trapping. Unredirected `3Fh` input reads an edited
line with CR/LF and a 253-character bound; it does not yet preserve overflow
between small reads. Redirected byte reads use the file API. Standard handles
0/1/2 default to firmware input/output; file redirection and file duplication to
these handles are supported. Default AUX/printer services and console close/
duplication semantics remain incomplete. File operations inherit firmware
access/media restrictions and use a single writable boot volume.

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
padding, FFh failure. Other listed FCB operations use 0/FFh. Extended FCBs,
FCB searches/renames/parse and random block operations remain unimplemented.

The native child starts with a private 280-byte DTA and inherited file
references. On return/4Ch, the parent reclaims child arenas/files/searches and
restores its descriptors, DTA pointer/capacity and process owner. Inherited
objects retain their shared file position. Current-directory changes are global.
Firmware image validation/loading replaces DOS's original MZ/relocation loader.
