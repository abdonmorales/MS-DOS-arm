# ARM BASIC

ARM BASIC (`BASIC.EXE`, source `programs/basic.S`) is a BASIC interpreter
for ARM DOS in the style of the Microsoft BASICs that came with MS-DOS. It
is new code written in AArch64 assembly, not a port of GW-BASIC, and it
covers a deliberately small subset: 64-bit integers and strings, no
floating point, no files, no graphics or sound.

## Starting and leaving

```
BASIC            start with an empty program
BASIC name       load NAME.BAS and run it
```

`Ok` is the prompt. A line that starts with a number is stored in the
program (replacing a line with the same number; a number alone deletes
that line). Any other line runs at once. `SYSTEM` returns to DOS.

```
A:\>basic
ARM BASIC 1.0 for ARM DOS (native AArch64)
64-bit integers and strings. SYSTEM returns to DOS.
Ok
10 FOR I = 1 TO 3: PRINT "ARM"; I: NEXT
RUN
ARM 1
ARM 2
ARM 3
Ok
SAVE "COUNT"
Ok
SYSTEM
```

Ctrl-C stops a running program with `Break in n`. At an `INPUT` prompt it
takes effect when ENTER is pressed.

## Commands

| Command | Action |
| --- | --- |
| `RUN` | Run the program from the first line (variables are cleared) |
| `LIST [m][-n]` | List the program, one line, or a range (`LIST 100-200`, `LIST -50`, `LIST 30-`) |
| `NEW` | Delete the program and variables |
| `LOAD "name"` | Load `NAME.BAS` (a plain text file of numbered lines) |
| `SAVE "name"` | Save the program as plain text; `.BAS` is added when there is no extension |
| `SYSTEM` | Leave BASIC |

Program files are ordinary text, so they can be written with EDLIN or on
the host and copied onto the disk. A line in a file without a line number
is an error (`Direct statement in file`).

## Statements

Several statements can share a line, separated by `:`. Keywords and
variable names may be typed in either case; they are stored in upper case.

| Statement | Notes |
| --- | --- |
| `PRINT` or `?` | Items separated by `;` (no space) or `,` (next 14-column zone); a trailing `;` or `,` suppresses the new line. `TAB(n)` and `SPC(n)` position the output |
| `LET var = expr` | `LET` is optional |
| `INPUT ["prompt";] var[, var...]` | With `;` after the prompt a `? ` follows it; with `,` it does not |
| `IF cond THEN statements [ELSE statements]` | `THEN n` and `ELSE n` jump to line n |
| `GOTO n` | |
| `GOSUB n`, `RETURN` | |
| `ON expr GOTO n1, n2, ...` / `ON expr GOSUB ...` | Value 1 picks the first line; out of range continues with the next statement |
| `FOR var = a TO b [STEP s]`, `NEXT [var]` | |
| `WHILE cond`, `WEND` | |
| `END`, `STOP` | `STOP` prints `Break in n` |
| `REM text` or `' text` | Comment |
| `DIM A(n)`, `DIM A$(n)` | One-dimensional arrays, subscripts 0 to n. An array used without `DIM` has subscripts 0 to 10 |
| `DATA`, `READ var[, ...]`, `RESTORE [n]` | |
| `RANDOMIZE` | Seeds `RND` from the clock |
| `CLS` | Clear the screen |
| `CLEAR` | Clear all variables and arrays |

## Functions

| Function | Result |
| --- | --- |
| `ABS(x)`, `SGN(x)` | Absolute value, sign (-1, 0, 1) |
| `INT(x)` | x (numbers are already integers) |
| `SQR(x)` | Integer square root |
| `RND(n)` | Random integer from 1 to n |
| `LEN(s$)`, `ASC(s$)` | Length, code of the first character |
| `VAL(s$)` | Decimal number at the start of the string |
| `CHR$(n)`, `STR$(x)`, `SPACE$(n)` | |
| `LEFT$(s$, n)`, `RIGHT$(s$, n)`, `MID$(s$, start[, n])` | |
| `INSTR(s$, t$)` | Position of t$ in s$, or 0 |

Numbers print as in GW-BASIC, with a leading space (or `-`) and a
trailing space: `PRINT 3` prints ` 3 `.

## Expressions

Operators, tightest first, as in GW-BASIC:

1. `^` (left to right, so `2^3^2` is 64)
2. unary `-`
3. `*` and `/`
4. `\` (integer division)
5. `MOD`
6. `+` and `-` (`+` also joins strings)
7. `=`, `<>`, `<`, `>`, `<=`, `>=` (numbers or strings)
8. `NOT`
9. `AND`
10. `OR`

Comparisons give -1 for true and 0 for false, and `NOT`, `AND` and `OR`
are bitwise, so they combine conditions as in GW-BASIC. `&Hnnnn` writes a
hexadecimal number in program text.

## Data types and limits

- **Numbers are 64-bit signed integers.** There is no floating point: `/`
  and `\` both divide to an integer, a typed fraction is dropped (`1.5` is
  1), and a result outside the 64-bit range is an `Overflow` error. A
  literal is at most 9223372036854775807; write the most negative number as
  `-9223372036854775807-1` or `&H8000000000000000`.
- **Strings** hold up to 255 bytes. String variables end in `$`.
- Variable names are significant to 14 characters; up to 512 variables and
  arrays. Arrays have one dimension. `DIM` accepts up to 1 Mi elements, but arrays share BASIC's 1 MiB heap, so in practice about 131,000 numeric elements or about 4,000 string elements (256 bytes each) fit before "Out of memory".
- Program lines hold up to 255 bytes; the program up to 64 KiB.
- `FOR`, `GOSUB` and `WHILE` nest up to 64 deep together.

## Errors

Errors use the GW-BASIC messages and name the line: `Syntax error in 20`.
The messages are: Syntax error, RETURN without GOSUB, Out of DATA, Illegal
function call, Out of memory, Undefined line number, Subscript out of
range, Duplicate Definition, Division by zero, Type mismatch, Out of string
space, String too long, NEXT without FOR, WEND without WHILE, WHILE without
WEND, FOR without NEXT, File not found, Direct statement in file, Bad file
name or disk error, Break, Overflow and Line buffer overflow.

## Differences from GW-BASIC

Not provided: floating point and the `!`, `#` and `%` type suffixes,
multi-dimensional arrays, `DEF FN`, `PRINT USING`, file I/O (`OPEN`,
`PRINT #` and so on), `INKEY$`, `EDIT`, `AUTO`, `RENUM`, `DELETE`, `TRON`,
graphics, sound and machine-level access (`PEEK`, `POKE`, `CALL`, `USR`).
`RND(n)` returns an integer from 1 to n instead of a fraction, `INSTR` takes
two arguments (no start position) and `VAL` reads decimal only. Programs
are saved as text, never in the tokenized format.

## Example

`PRIMES.BAS` on the test disk:

```
A:\>basic primes
ARM BASIC 1.0 for ARM DOS (native AArch64)
64-bit integers and strings. SYSTEM returns to DOS.
Primes below 100:
 2  3  5  7  11  13  17  19  23  29  31  37  41  43  47  53  59  61  67  71  73  79  83  89  97
```
