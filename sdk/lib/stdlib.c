/* SPDX-License-Identifier: MIT */
/* stdlib.h: number conversion, sorting, exit handling, environment. */
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <armdos.h>

void __armdos_stdio_flush_all(void);

/* ---- exit ---- */

#define ATEXIT_MAX 32
static void (*atexit_fns[ATEXIT_MAX])(void);
static int atexit_count;

int atexit(void (*fn)(void))
{
    if (atexit_count >= ATEXIT_MAX)
        return -1;
    atexit_fns[atexit_count++] = fn;
    return 0;
}

void exit(int code)
{
    while (atexit_count > 0)
        atexit_fns[--atexit_count]();
    __armdos_stdio_flush_all();
    dos_exit(code);
}

void _Exit(int code) { dos_exit(code); }
void _exit(int code) { dos_exit(code); }

void abort(void)
{
    static const char msg[] = "Abnormal program termination\r\n";
    dos_write(DOS_STDERR, msg, sizeof msg - 1);
    dos_exit(3);
}

/* ---- environment ---- */

char *getenv(const char *name)
{
    size_t n = strlen(name);
    if (!environ || !n)
        return NULL;
    /* COMMAND's SET upper-cases names; compare without case like it does. */
    for (char **e = environ; *e; e++)
        if (!strncasecmp(*e, name, n) && (*e)[n] == '=')
            return *e + n + 1;
    return NULL;
}

/* ---- integers ---- */

int abs(int x) { return x < 0 ? -x : x; }
long labs(long x) { return x < 0 ? -x : x; }
long long llabs(long long x) { return x < 0 ? -x : x; }
div_t div(int a, int b) { div_t r = { a / b, a % b }; return r; }
ldiv_t ldiv(long a, long b) { ldiv_t r = { a / b, a % b }; return r; }

/* Core of strto*: parses an unsigned magnitude; sets *neg; saturates at
 * limit (the largest magnitude allowed for the sign) with ERANGE. */
static unsigned long long parse_number(const char *s, char **end, int base,
                                       int *neg, unsigned long long pos_limit,
                                       unsigned long long neg_limit)
{
    const char *p = s;
    while (isspace((unsigned char)*p))
        p++;
    *neg = 0;
    if (*p == '+' || *p == '-')
        *neg = *p++ == '-';
    if ((base == 0 || base == 16) && p[0] == '0' && (p[1] == 'x' || p[1] == 'X')
        && isxdigit((unsigned char)p[2])) {
        p += 2;
        base = 16;
    } else if (base == 0) {
        base = *p == '0' ? 8 : 10;
    }
    if (base < 2 || base > 36) {
        if (end)
            *end = (char *)s;
        errno = EINVAL;
        return 0;
    }
    unsigned long long limit = *neg ? neg_limit : pos_limit;
    unsigned long long value = 0;
    int any = 0, overflow = 0;
    for (;; p++) {
        int c = (unsigned char)*p, digit;
        if (isdigit(c))
            digit = c - '0';
        else if (isalpha(c))
            digit = tolower(c) - 'a' + 10;
        else
            break;
        if (digit >= base)
            break;
        any = 1;
        if (value > (limit - (unsigned)digit) / (unsigned)base)
            overflow = 1;
        else
            value = value * (unsigned)base + (unsigned)digit;
    }
    if (end)
        *end = (char *)(any ? p : s);
    if (overflow) {
        errno = ERANGE;
        return limit;
    }
    return value;
}

long long strtoll(const char *restrict s, char **restrict end, int base)
{
    int neg;
    unsigned long long v = parse_number(s, end, base, &neg, LLONG_MAX,
                                        (unsigned long long)LLONG_MAX + 1);
    return neg ? (long long)(0 - v) : (long long)v;
}

long strtol(const char *restrict s, char **restrict end, int base)
{
    return (long)strtoll(s, end, base);
}

unsigned long long strtoull(const char *restrict s, char **restrict end, int base)
{
    int neg;
    unsigned long long v = parse_number(s, end, base, &neg, ULLONG_MAX, ULLONG_MAX);
    return neg ? 0 - v : v;
}

unsigned long strtoul(const char *restrict s, char **restrict end, int base)
{
    return (unsigned long)strtoull(s, end, base);
}

int atoi(const char *s) { return (int)strtol(s, NULL, 10); }
long atol(const char *s) { return strtol(s, NULL, 10); }
long long atoll(const char *s) { return strtoll(s, NULL, 10); }

/* ---- sorting ---- */

static void swap_bytes(unsigned char *a, unsigned char *b, size_t n)
{
    while (n--) {
        unsigned char t = *a;
        *a++ = *b;
        *b++ = t;
    }
}

/* Shell sort: no recursion, no extra memory, O(n^1.3)-ish in practice. */
void qsort(void *base, size_t count, size_t size,
           int (*compare)(const void *, const void *))
{
    unsigned char *b = base;
    size_t gap = 1;
    while (gap < count / 3)
        gap = gap * 3 + 1;
    for (; gap > 0; gap /= 3)
        for (size_t i = gap; i < count; i++)
            for (size_t j = i; j >= gap &&
                 compare(b + (j - gap) * size, b + j * size) > 0; j -= gap)
                swap_bytes(b + (j - gap) * size, b + j * size, size);
}

void *bsearch(const void *key, const void *base, size_t count, size_t size,
              int (*compare)(const void *, const void *))
{
    const unsigned char *b = base;
    while (count) {
        const unsigned char *mid = b + (count / 2) * size;
        int c = compare(key, mid);
        if (c == 0)
            return (void *)mid;
        if (c > 0) {
            b = mid + size;
            count -= count / 2 + 1;
        } else {
            count /= 2;
        }
    }
    return NULL;
}

/* ---- random numbers (xorshift; not for cryptography) ---- */

static unsigned long long rand_state = 0x2545f4914f6cdd1dull;

void srand(unsigned seed)
{
    rand_state = seed ? seed * 0x9e3779b97f4a7c15ull : 0x2545f4914f6cdd1dull;
}

int rand(void)
{
    rand_state ^= rand_state << 13;
    rand_state ^= rand_state >> 7;
    rand_state ^= rand_state << 17;
    return (int)(rand_state >> 33);
}

/* ---- processes ---- */

void __armdos_stdio_flush_all(void);

int spawn(const char *path, const char *tail)
{
    __armdos_stdio_flush_all();
    long r = dos_exec(path, tail);
    if (r < 0)
        return __armdos_seterrno(r);
    return dos_child_status();
}
