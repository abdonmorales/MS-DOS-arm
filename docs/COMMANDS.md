# ARM DOS command reference

This is the reference for everything you can type at the ARM DOS prompt:
the commands built into COMMAND, the utilities shipped as native `.EXE`
programs, the batch-file language, `CONFIG.SYS` and the installable
drivers. ARM BASIC has its own page, [BASIC.md](BASIC.md).

ARM DOS follows MS-DOS 4.0. Where it behaves differently, the entry says
so under **Differences**. Some general points first:

- Only native AArch64 programs run. A command name is looked up as typed,
  then as `NAME.EXE`, then as `NAME.BAT`, first in the current directory and
  then in each `PATH` directory. There are no `.COM` programs, and x86
  `.EXE` files are refused as an invalid format.
- Command lines hold up to 255 characters. Paths are limited to 255
  characters too.
- Names with spaces must be quoted: `CD "WORK DIR"`. VFAT long names are
  read and written; a long name gets a `~N` short alias as on Windows.
- Switches start with `/`. COMMAND ends an internal command's name at
  `= / + ; , . \ " [`, so `CD..`, `DIR/W`, `ECHO.` and `PATH=A:\` work as
  in DOS.
- The device names `CON`, `AUX` (also `COM1`), `PRN` (also `LPT1`), `NUL`
  and `CLOCK$` can be used anywhere a file name can, with any extension and
  in any directory.
- There is no `/?` help switch. `HELP` lists the internal commands.

## Redirection and pipes

| Syntax | Meaning |
| --- | --- |
| `command < file` | Standard input from a file |
| `command > file` | Standard output to a file (created or truncated) |
| `command >> file` | Standard output appended to a file |
| `a \| b` | Output of `a` becomes input of `b`; up to 8 stages |

As in COMMAND, a pipe runs each stage in turn through temporary files named
`%PIPEnn.$$$` in the root of the current drive. **Pipes therefore need a
writable current drive.** On the live ISO and the ROM builds, where A: is read-only, change to
the RAM disk first (`B:`) before using a pipe.

```
A:\>echo hello | find "hell"
hello
A:\>sort /r < SORTIN.TXT > SORTED.TXT
```

## Internal commands (COMMAND)

These are built into the shell (`\EFI\BOOT\BOOTAA64.EFI`, which plays the
roles of IO.SYS, MSDOS.SYS and COMMAND.COM).

### CD / CHDIR

```
CD [d:][path]
CD d:
```

Changes the current directory. Without an argument it prints the current
drive and directory; `CD B:` prints the current directory of drive B:
without changing drives. `CD ..` and `CD\` work.

**Differences:** current directories are global to the system, not per
process.

### CHCP

```
CHCP [nnn]
```

Shows the active code page (`Active code page: 437`), or switches to code
page `nnn`. Switching loads the current country's tables for that code page
from `\COUNTRY.SYS`; a code page the file does not have for the current
country prints `Invalid code page`. This replaces the NLSFUNC resident
program, which is built in.

### CLS

Clears the screen (sends the terminal's clear-screen sequence).

### COPY

```
COPY [/A|/B] source[+source...] [destination] [/V]
```

Copies files. Wildcards are allowed in the source, and the destination can
be a directory, a file name or a rename template (`COPY *.TXT *.BAK`).
`a+b c` concatenates. A device can be a source: `COPY CON FILE.TXT` copies
what you type until Ctrl-Z and ENTER.

```
A:\>copy *.BAT B:\
A:\>copy CAT1.TXT+CAT2.TXT ALL.TXT
A:\>copy con NOTE.TXT
```

**Differences:** `/A`, `/B` and `/V` are accepted and ignored. Copies are
always binary, and every write reaches the disk before the call returns
(the FAT layer is write-through), so there is nothing for `/V` to add.

### CTTY

```
CTTY device
```

Moves standard input, output and error to another character device, for
example `CTTY AUX`; `CTTY CON` returns to the console. A name that is not a
character device prints `Invalid device`. On the supported machines AUX is
the same serial UART as the console.

### DATE

```
DATE [date]
```

Without an argument, shows the date and asks for a new one; ENTER keeps it.
The order of the fields follows the country setting (`mm-dd-yy` for
country 001). Years 1980 to 2107 are accepted, as two or four digits (two
digits: 80-99 are 19xx, 00-79 are 20xx).

**Differences:** the date is kept by the kernel from the time it booted;
setting it does not write a hardware clock.

### DEL / ERASE

```
DEL [d:][path]filename [/P]
```

Deletes files. Wildcards are allowed. `DEL directory` means
`DEL directory\*.*`. Deleting `*.*` warns
`All files in directory will be deleted!` and asks `Are you sure (Y/N)?`. `/P` asks
before each file. Read-only files and files that are open cannot be
deleted (`Access denied`).

### DIR

```
DIR [d:][path][filename] [/P] [/W]
```

Lists a directory in the DOS 4.0 layout: volume label and serial number,
then one line per entry, then the file count and free bytes. `/W` lists
names only, five to a line; `/P` pauses after each screen. Other switches
print `Invalid switch`.

### ECHO

```
ECHO [ON|OFF]
ECHO text
ECHO.
```

`ECHO ON` and `ECHO OFF` turn batch-line echoing on and off; `ECHO` alone
prints `ECHO is on.` or `ECHO is off.`; `ECHO text` prints the text;
`ECHO.` prints an empty line (`ECHO.text` prints `text`).

### EXIT

```
EXIT
EXIT /B [n]
```

At the prompt, `EXIT` leaves the shell: in native mode the machine powers
off, in firmware mode control returns to UEFI. If the shell was started by
`SHELL=` from another program, that program continues.

Inside a batch file, `EXIT /B` ends the batch file and `EXIT /B n` also sets
ERRORLEVEL to `n`.

**Differences:** `EXIT /B` comes from later Windows command shells, not
DOS 4.0. Outside a batch file `EXIT /B` behaves like `EXIT` and powers the
machine off.

### FOR, GOTO, CALL, IF, SHIFT, PAUSE, REM

These are mostly used in batch files; see [Batch files](#batch-files). FOR
and IF also work at the prompt.

### HELP

Prints the list of internal commands and a reminder of the redirection
syntax.

```
A:\>help
HELP VER ECHO CLS DIR TYPE DEL ERASE CD MD RD COPY REN DATE TIME VOL
SET PATH PROMPT FOR SHIFT REM CALL GOTO IF PAUSE VERIFY BREAK CTTY CHCP TRUENAME
SELFTEST EXIT. Native ARM64 EXE and BAT files; quote paths containing spaces.
Redirection: < input, > output, >> append, | pipe. A: is the boot volume.
```

**Differences:** MS-DOS 4.0 had no HELP command.

### MD / MKDIR, RD / RMDIR

```
MD [d:]path
RD [d:]path
```

Create and remove a directory. `RD` removes only an empty directory.

### PATH

```
PATH [d:]path[;[d:]path...]
PATH ;
PATH
```

Sets the directories searched for programs and batch files, clears the
list (`PATH ;`), or shows it (`PATH=A:\`, or `No Path`). The default is
`A:\`.

### PAUSE

Prints `Press any key to continue . . .` and waits for a key.

### PROMPT

```
PROMPT [text]
```

Sets the prompt. Without text the default `$P$G` comes back. These codes
are expanded; any other `$x` prints nothing:

| Code | Meaning | Code | Meaning |
| --- | --- | --- | --- |
| `$P` | Current drive and directory | `$G` | `>` |
| `$N` | Current drive | `$L` | `<` |
| `$D` | Date | `$B` | `\|` |
| `$T` | Time | `$Q` | `=` |
| `$V` | Version string | `$$` | `$` |
| `$_` | New line | `$E` | Escape character |
| `$H` | Backspace | | |

With `ANSI.SYS` loaded, `$E[` sequences in the prompt reach it, so
`PROMPT $e[120;"ver";13p$p$g` reassigns the `x` key, as in DOS.

### REN / RENAME

```
REN [d:][path]oldname newname
```

Renames files or directories. The new name is a name only (no drive or
directory) and may be a template: `REN *.TXT *.BAK`, where `?` keeps the
old character and `*` the rest of that part.

### SELFTEST

Runs the built-in self-test of the DOS API against real files on the boot
drive (file and FCB calls, directories and searches, memory, clock and
native processes) and prints `SELFTEST PASS` or `SELFTEST FAIL`. It also
runs at every boot. **ARM DOS addition.**

### SET

```
SET
SET name=value
SET name=
```

Lists the environment, sets a variable, or removes it. The environment
holds up to 4096 bytes (`Out of environment space` beyond that) and is
passed to every program. It starts with `COMSPEC` and `PATH`.

### TIME

```
TIME [hh:mm[:ss[.hh]]]
```

Without an argument, shows the time and asks for a new one; ENTER keeps
it. As with DATE, the time lives in the kernel and is not written to a
hardware clock.

### TRUENAME

```
TRUENAME [path]
```

Prints the fully qualified name of a path after SUBST, JOIN and ASSIGN,
upper case (`A:\DIR\FILE.TXT`, or `A:/NUL` for a device). This was an
undocumented command in DOS 4.0.

### TYPE

```
TYPE [d:][path]filename
```

Writes a file to standard output. One file, no wildcards.

### VER

Prints `ARM DOS Version 4.00 (AArch64), MS-DOS 4.00 API`.

### VERIFY, BREAK

```
VERIFY [ON|OFF]
BREAK [ON|OFF]
```

Show or set the flags. `VERIFY` is kept for compatibility (writes are
always checked by the write-through FAT layer). With `BREAK ON` the kernel
checks for Ctrl-C on every DOS call, not only on console I/O.

### VOL

```
VOL [d:]
```

Shows the volume label and serial number from the drive's boot record.

### Changing drives

Type a drive letter and a colon (`B:`) to make it the current drive.
`Invalid drive specification` means there is no such drive.

## Batch files

A batch file is a text file named `NAME.BAT`; typing `NAME` runs it line by
line. `\AUTOEXEC.BAT` runs at boot. Without it, the shell asks for the
date and time, as COMMAND did.

### Lines

- A line starting with `@` is not echoed even when ECHO is on.
- A line starting with `:` is a label (and is never executed).
- `REM text` is a comment.
- Lines are read one at a time from the file, so a batch file may be
  edited while it runs, as in DOS.

### Replaceable parameters and variables

| Syntax | Expands to |
| --- | --- |
| `%0` | The batch file name as typed |
| `%1` ... `%9` | The arguments |
| `%*` | The whole argument line |
| `%NAME%` | The environment variable `NAME`, or nothing if it is not set |
| `%ERRORLEVEL%` | The current ERRORLEVEL as a decimal number |
| `%%` | A single `%` (so `%%f` in a FOR loop becomes `%f`) |

A `%` without a closing `%` is kept literally, so `ECHO 50% done` prints
`50% done`. Expansion happens only in batch files; at the prompt, `%PATH%`
is printed as typed, as in DOS 4.0. An expanded line is limited to 255
characters.

**Differences:** `%*` and `%ERRORLEVEL%` are additions from later command
shells.

### SHIFT

Moves the parameters down one place: `%0` gets `%1`, ..., `%9` gets the next
argument that did not fit. Use it to process more than nine arguments.

### GOTO

```
GOTO label
GOTO :EOF
```

Continues after the line `:label` (the label is matched without regard to
case). `GOTO :EOF` ends the batch file (an addition from later shells).

### IF

```
IF [NOT] ERRORLEVEL n command
IF [NOT] EXIST filename command
IF [NOT] string1==string2 command
```

`ERRORLEVEL n` is true when the last program's exit code is **n or more**.
`EXIST` tests for a file. The string comparison is exact: case sensitive,
with quotes included, so the usual idiom is `IF "%1"=="" GOTO done`.

### FOR

```
FOR %v IN (set) DO command        (at the prompt)
FOR %%v IN (set) DO command       (in a batch file)
```

Runs the command once for each item of the set, with `%v` replaced by the
item. Items are separated by blanks, commas, semicolons or `=`; an item
with `*` or `?` is replaced by the matching file names. FOR cannot be
nested (`FOR cannot be nested`), as in DOS.

```
A:\>for %f in (*.bat) do echo %f
AUTOEXEC.BAT
CHILD.BAT
```

### CALL and chaining

```
CALL batchfile [arguments]
```

`CALL` runs another batch file and then continues with the next line of the
current one. Up to 16 batch files can be active at once. Naming another
batch file **without** `CALL` transfers control to it: the current file is
not resumed, as in COMMAND.

### ERRORLEVEL

Each program's exit code (the low byte) becomes ERRORLEVEL. A command that
is not found sets it to 1. A program ended by Ctrl-C or a CPU exception
also sets it (see `4Dh` in [ABI.md](../ABI.md) for the termination types).

### Example

```bat
@echo off
rem Print each argument, then report whether a file exists.
:loop
if "%1"=="" goto done
echo arg: %1
shift
goto loop
:done
if exist CONFIG.SYS echo CONFIG.SYS is here
for %%f in (*.TXT) do echo text file: %%f
```

## External utilities

Each utility is a native PE32+ program `NAME.EXE` in the root of the boot
drive. They are re-implementations of the MS-DOS 4.0 utilities in
`src/CMD`, with the same switches unless noted.

### APPEND

```
APPEND [d:]path[;[d:]path...]
APPEND ;
APPEND [/X[:ON|:OFF]] [/PATH:ON|/PATH:OFF] [/E]
```

Sets directories searched for data files that are not found where a
program looked for them. `APPEND ;` clears the list; `APPEND` alone shows
it (`No Append`). `/X:ON` also applies the list to program searches and
execution, `/PATH:OFF` limits it to names without a drive or directory,
`/E` keeps the list in the `APPEND` environment variable.

**Differences:** the state lives in the kernel, so APPEND is not a resident
program, but its setting likewise lasts until changed.

### ASSIGN

```
ASSIGN [x[:]=y[:] [...]]
ASSIGN /STATUS
```

Sends requests for drive x to drive y. `ASSIGN` alone removes every
assignment; `/STATUS` lists them.

### ATTRIB

```
ATTRIB [+R|-R] [+A|-A] [+S|-S] [+H|-H] [d:][path][filename] [/S]
```

Shows or changes the read-only, archive, system and hidden attributes.
Wildcards are allowed; `/S` includes subdirectories. Without a file name it
lists every file in the current directory.

**Differences:** DOS 4.0's ATTRIB handled only R and A; S and H were added
in DOS 5.

### BACKUP

```
BACKUP source d: [/S] [/M] [/A] [/D:date [/T:time]] [/F] [/L[:log]]
```

Copies files into a backup set (`BACKUP.nnn` and `CONTROL.nnn`, the DOS 3.3
format) on drive d:. `/S` includes subdirectories, `/M` only files changed
since the last backup, `/A` adds to an existing set, `/D` and `/T` only
files changed on or after that date and time, `/L` logs to `\BACKUP.LOG`
(or the named file) on the source drive. The archive bit of backed-up files
is cleared. When a target disk is full, BACKUP asks for the next one. On a
RAM disk the set is kept in the root, on other drives in `\BACKUP`.

**Differences:** `/F` is accepted but not needed: the targets are already
formatted.

### BASIC

```
BASIC [file]
```

ARM BASIC. `BASIC PRIMES` loads and runs `PRIMES.BAS`. See
[BASIC.md](BASIC.md).

### CHKDSK

```
CHKDSK [d:][path][filename] [/F] [/V]
```

Checks a FAT volume: walks every directory and FAT chain and reports
cross-linked files, allocation errors and lost chains, then the disk and
memory summary. `/F` fixes errors (lost chains become `FILEnnnn.CHK` files
in the root, or are freed); `/V` lists every file. With a file
specification it also reports whether those files are contiguous.

### COMP

```
COMP [file1] [file2]
```

Compares files byte by byte. `file1` may contain wildcards; `file2` may be
a directory or a template. Missing names are asked for. It shows up to 10
mismatches and then asks `Compare more files (Y/N) ?`.

### DISKCOMP, DISKCOPY

```
DISKCOPY [d1: [d2:]] [/1]
DISKCOMP [d1: [d2:]] [/1] [/8]
```

DISKCOPY copies a whole disk sector by sector to another of the same size
and gives the copy its own volume serial number. DISKCOMP compares two
disks (ignoring the serial number).

**Differences:** as in DOS they work only with removable ("diskette")
drives. Here those are the drives of block device drivers (`RAMDRIVE.SYS`,
`VDISK.SYS`); the boot disk does not qualify. `/1` and `/8` are accepted
and have no effect.

### EDLIN

```
EDLIN [d:][path]filename [/B]
```

The line editor. Commands at the `*` prompt:

| Command | Action |
| --- | --- |
| `[n]` | Edit line n |
| `[n]I` | Insert before line n |
| `[r]L` | List lines |
| `[r]P` | Page through lines |
| `[r]D` | Delete lines |
| `[r][?]Stext` | Search (`?` asks `O.K.?` at each match) |
| `[r][?]Rold^Znew` | Replace |
| `r,n[,c]C` | Copy lines r to before n, c times |
| `r,nM` | Move lines |
| `[n]Tfile` | Insert (transfer) another file |
| `[n]A`, `[n]W` | Append from / write to disk |
| `E` | Save and end (the old file is kept as `NAME.BAK`) |
| `Q` | Quit without saving (`Abort edit (Y/N)?`) |

Line numbers may be `n`, `.` (current), `#` (after the last), `+n` or
`-n`. `/B` treats Ctrl-Z as ordinary text.

**Differences:** the whole file is held in memory, so `A` and `W` only
report.

### FC

```
FC [/A] [/B] [/C] [/L] [/LBn] [/N] [/T] [/W] [/nnnn] file1 file2
```

Compares two files. Text mode (`/L`, the default for most files) compares
lines and resynchronises when `nnnn` lines (default 2) match again; `/A`
abbreviates the output, `/C` ignores case, `/N` shows line numbers, `/T`
keeps tabs, `/W` compresses white space, `/LBn` sets the line buffer.
Binary mode (`/B`, the default for `.EXE`, `.COM`, `.SYS`, `.OBJ`, `.LIB`
and `.BIN` files) lists differing bytes.

### FIND

```
FIND [/V] [/C] [/N] [/I] "string" [[d:][path]filename ...]
```

Prints the lines of each file, or of standard input, that contain the
string. `/V` prints lines without it, `/C` only counts, `/N` adds line
numbers, `/I` ignores case.

**Differences:** `/I` is from DOS 5.

### FORMAT

```
FORMAT d: [/S] [/V[:label]]
```

Writes a new FAT12 or FAT16 file system over the whole device, asks
`Proceed with Format (Y/N)?` and for a volume label (unless `/V:label`
gives it). `/S` then transfers the system (see SYS).

**Differences:** FORMAT cannot create FAT32 (ARM DOS reads and writes FAT32
volumes made elsewhere). The floppy geometry switches `/1 /4 /8 /B /N /T
/F` print `Parameters not supported by drive`. `/SELECT` is an internal
switch used by INSTALL (no questions).

### INSTALL

```
INSTALL [disk] [/Y]
```

Installs ARM DOS on a writable disk, as SELECT did for DOS 4. It lists the
disks the firmware offers (except the one ARM DOS started from), asks which
to use and for confirmation, then writes an MBR with one partition of type
EFh (from 1 MiB, at most 2000 MB), formats it with `FORMAT d: /SELECT
/V:ARMDOS` and copies every file from A: with `XCOPY`, including
`\EFI\BOOT\BOOTAA64.EFI`.

- **Everything on the chosen disk is erased.** ENTER at the disk question,
  or N at the confirmation, leaves it untouched.
- `INSTALL n /Y` uses disk n without asking, for scripts. `/Y` without a
  disk number is refused.
- INSTALL needs UEFI boot services, so it works from the live ISO or any
  firmware-mode boot. Under the native kernel it finds no disks and says
  so.

**ARM DOS addition** (replaces SELECT and FDISK).

### JOIN

```
JOIN d: [d:]path
JOIN d: /D
JOIN
```

Makes drive d: appear as an empty directory of another drive, undoes that
(`/D`), or lists the joins. A joined drive cannot be used by its own
letter.

### LABEL

```
LABEL [d:][label]
```

Shows, sets or deletes a volume label (up to 11 characters). Without a
label it asks for one; ENTER at that prompt removes the current label
after asking `Delete current volume label (Y/N)?`. Both the
root-directory entry and the boot record copy are updated.

### MEM

```
MEM [/PROGRAM | /DEBUG]
```

Shows total memory, available memory and the largest program size. With
`/PROGRAM` or `/DEBUG` it also lists the allocated blocks with their
addresses, sizes and owners.

**Differences:** memory is the kernel's flat 64-bit arena (32 MiB under
QEMU), so there is no conventional, extended or expanded memory to report.

### MORE

```
MORE < file
command | MORE
```

Shows standard input a screen (24 lines) at a time, with `-- More --`
between screens.

### RECOVER

```
RECOVER [d:][path]filename
RECOVER d:
```

For a file, reads every allocation unit, marks unreadable ones as bad,
drops them from the chain and reports how many bytes were recovered. For a
drive, turns every root directory entry into `FILEnnnn.REC`. **Use the
drive form only as a last resort**, as in DOS.

### REPLACE

```
REPLACE [d:][path]filename [d:][path] [/A] [/P] [/R] [/S] [/U] [/W]
```

Replaces files in the target directory with source files of the same name,
or with `/A` adds the source files the target lacks. `/S` searches the
target's subdirectories, `/P` asks first, `/R` also replaces read-only
files, `/U` replaces only older files, `/W` waits for a key first.

### RESTORE

```
RESTORE d: [d:][path]filespec [/S] [/P] [/B:date] [/A:date] [/E:time] [/L:time] [/M] [/N]
```

Restores files from a BACKUP set on drive d:. `/S` includes
subdirectories, `/P` asks before replacing read-only files or files changed
since the backup, `/B` and `/A` restore only files changed on or before /
on or after a date, `/E` and `/L` at or before / at or after a time, `/M`
only files changed since the backup (or deleted), `/N` only files that no
longer exist. Dates, times and attributes come back; missing directories
are created.

### SORT

```
SORT [/R] [/+n] < input > output
```

Sorts lines of standard input, ignoring case, starting at column n (`/+n`).
`/R` reverses the order. Input is limited to 63 KiB, as in DOS.

### SUBST

```
SUBST d: [d:]path
SUBST d: /D
SUBST
```

Makes drive d: refer to a directory, removes that (`/D`), or lists the
substitutions.

### SYS

```
SYS d:
```

Makes a formatted drive bootable by copying the system to it. On ARM DOS
the whole system is one UEFI image, `\EFI\BOOT\BOOTAA64.EFI`, copied from
A:. The drive also needs the utilities to be useful; INSTALL does both.

### TREE

```
TREE [d:][path] [/F] [/A]
```

Draws the directory structure with code page 437 line characters, or plain
ASCII with `/A`. `/F` also lists the files in each directory.

### XCOPY

```
XCOPY source [destination] [/A] [/D:date] [/E] [/M] [/P] [/S] [/V] [/W]
```

Copies files and, with `/S`, directory trees. `/E` also copies empty
directories, `/A` only files with the archive bit set, `/M` the same and
then clears the bit, `/D:mm-dd-yy` only files dated on or after the date,
`/P` asks for each file, `/W` waits for a key first. `/V` is accepted
(writes are always checked). End the destination with `\` to make it a
directory.

### Test programs

The test disk image also carries `NATIVE.EXE` (the boot self-test runs it)
and `DOSTEST.EXE` (an exhaustive test of the DOS function set used by
`make smoke`). They are not meant for everyday use. The live ISO keeps
`NATIVE.EXE` only.

### Not provided

These MS-DOS 4.0 commands drove PC hardware or x86 code and have no ARM DOS
version: DEBUG, EXE2BIN, FDISK and SELECT (use INSTALL), GRAFTABL,
GRAPHICS, DISPLAY.SYS, KEYB, MODE, PRINT, SHARE, FASTOPEN, NLSFUNC,
IFSFUNC, XMA2EMS, XMAEM and SMARTDRV. SHARE's file sharing and locking and
NLSFUNC's code page loading are built into the kernel. See
[PORT_STATUS.md](../PORT_STATUS.md).

## CONFIG.SYS

`\CONFIG.SYS` on the boot drive is read once at boot, before
`AUTOEXEC.BAT`. Lines run in order, except that `INSTALL=` programs run
after all drivers have loaded. A line with an unknown keyword prints
`Unrecognized command in CONFIG.SYS`, and an unknown keyword or bad value
`Error in CONFIG.SYS line n`.

| Directive | Meaning |
| --- | --- |
| `BREAK=ON\|OFF` | Initial BREAK setting |
| `BUFFERS=n` | 1-99. Up to 32 4 KiB sector buffers are actually cached; the value is reported to programs |
| `COUNTRY=nnn[,cp][,file]` | Country code, optional code page and country file (default `A:\COUNTRY.SYS`) |
| `DEVICE=path [args]` | Load an installable driver (up to 11) |
| `FCBS=x,y` | Accepted for compatibility; there are no fixed FCB tables to size |
| `FILES=n` | 8-255; at most 64 files are open at once. The standard devices do not use entries |
| `INSTALL=path [args]` | Run a program after the drivers have loaded |
| `LASTDRIVE=x` | Last drive letter (RAM disks get letters up to it) |
| `REM text` | Comment |
| `SHELL=path [args]` | Sets `COMSPEC`. Naming any program other than the built-in shell (`\EFI\BOOT\BOOTAA64.EFI` or `COMMAND.COM`) runs that program instead of COMMAND and `AUTOEXEC.BAT`; the built-in shell takes over when it exits |
| `STACKS=n,s` | Accepted for compatibility; no interrupt stacks to size |

Example (the live ISO's file):

```
REM CONFIG.SYS for ARM DOS
FILES=40
BUFFERS=20
COUNTRY=001
LASTDRIVE=Z
DEVICE=\RAMDRIVE.SYS 1024 512 112
DEVICE=\ANSI.SYS
```

`COUNTRY.SYS` holds the 46 country and code page pairs of MS-DOS 4.0 (code
pages 437, 850, 860, 862-865 and the DBCS pages 932-938). Without it, the
built-in records for countries 1, 3, 31, 32, 33, 34, 39, 41, 44, 46, 49, 61
and 358 (code page 437) are used.

## Installable drivers

Drivers are native PE32+ images loaded with `DEVICE=`. Writing one is
described in [PROGRAMMING.md](PROGRAMMING.md#writing-an-installable-driver).

### ANSI.SYS

```
DEVICE=\ANSI.SYS
```

The extended console driver. It takes over CON and keeps DOS's meanings
for the escape sequences a program sends:

| Sequence | Meaning |
| --- | --- |
| `ESC[nA`, `ESC[nB`, `ESC[nC`, `ESC[nD` | Cursor up, down, right, left |
| `ESC[r;cH`, `ESC[r;cf` | Cursor position |
| `ESC[2J` | Clear screen and home |
| `ESC[s`, `ESC[u` | Save and restore the cursor position |
| `ESC[6n` | Device status: `ESC[row;colR` is typed back |
| `ESC[=7h`, `ESC[=7l` | Line wrap on / off |
| `ESC[key;...p` | Keyboard reassignment (`ESC[keyp` resets the key) |
| `ESC[...m`, `ESC[K` and others | Passed to the terminal unchanged |

**Differences:** the console is a serial terminal that already understands
VT100, so most sequences pass straight through. The screen is taken as 80
by 25. Only keys the serial line delivers (ASCII) can be reassigned:
extended `0;n` key codes are accepted but a serial terminal never sends
them. Video mode sequences other than line wrap do nothing.

### PRINTER.SYS

```
DEVICE=\PRINTER.SYS [/AUX | /NUL]
```

The printer device. The supported machines have no parallel port, so
PRN goes to the serial line (`/AUX`, the default, the same UART as the
console) or nowhere (`/NUL`, the same as without the driver).

**Differences:** IBM printer code page switching is not provided.

### RAMDRIVE.SYS

```
DEVICE=\RAMDRIVE.SYS [DiskSize SectorSize [NumEntries]] [/E | /A]
```

A RAM disk, formatted FAT12 at boot, on the next free drive letter. Size
in KB (16-4096, default 64), sector size 512 or 1024 (default 512), root
directory entries 2-1024 (default 64). Its contents are lost at power off.

**Differences:** `/E` and `/A` are accepted and ignored: memory is flat, so
there is no extended or expanded memory to choose. 128- and 256-byte
sectors are not supported (the FAT driver needs at least 512).

### VDISK.SYS

```
DEVICE=\VDISK.SYS [bbb] [sss] [ddd] [/E[:m]] [/X[:m]]
```

The IBM virtual disk, with the same limits as RAMDRIVE.SYS (size in KB,
sector size, directory entries; defaults 64 KB, 512, 64). `/E` and `/X` are
accepted and ignored.

### COUNTRY.SYS

Not a driver but a data file, built from the MS-DOS 4.0 `MKCNTRY.ASM`
tables. `COUNTRY=` and `CHCP` read it.

### TESTDRV.SYS

A minimal character device used by the tests (test disk image only). It
installs `UPPER$`: text written to it is read back in upper case. Its
source, `drivers/testdrv.S`, is the smallest driver example.

## Keys

| Key | Effect |
| --- | --- |
| Backspace | Deletes the last character of the line |
| Ctrl-C | At the prompt, discards the line. In a program, ends it (unless it installed a Ctrl-C handler) |
| Ctrl-Z, ENTER | End of file when copying from CON |

**Differences:** the console is a serial terminal. There are no function-key
template editing keys (F1-F6) and no scan codes.
