/* SPDX-License-Identifier: MIT */
/*
 * printf family: %d %i %u %o %x %X %c %s %p %% and %n, flags "-+ #0",
 * width and precision (also as *), length modifiers hh h l ll z j t.
 * Floating-point conversions are not supported (the library is built with
 * -mgeneral-regs-only); %f/%e/%g/%a print as "?" and consume nothing.
 */
#include <stdio.h>
#include <stdarg.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

typedef struct sink {
    void (*put)(struct sink *, const char *, size_t);
    char *buf;                  /* string sinks */
    size_t cap, len;            /* len counts every byte, even dropped ones */
    FILE *file;
} sink;

static void emit(sink *s, const char *p, size_t n)
{
    if (n)
        s->put(s, p, n);
    s->len += n;
}

static void pad(sink *s, char c, int n)
{
    char block[16];
    memset(block, c, sizeof block);
    while (n > 0) {
        int k = n > 16 ? 16 : n;
        emit(s, block, (size_t)k);
        n -= k;
    }
}

enum { F_MINUS = 1, F_PLUS = 2, F_SPACE = 4, F_HASH = 8, F_ZERO = 16 };

static void format_integer(sink *s, uintmax_t v, int negative, int base,
                           int upper, int flags, int width, int precision,
                           int is_pointer)
{
    char digits[24];
    const char *set = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    int n = 0;
    while (v) {
        digits[n++] = set[v % (unsigned)base];
        v /= (unsigned)base;
    }
    /* Precision: minimum digits; an explicit 0 precision prints nothing
     * for the value 0 (except "%#o", which still shows its 0). */
    int zeros = precision > n ? precision - n : 0;
    if (precision < 0 && n == 0)
        zeros = 1;
    char prefix[3];
    int plen = 0;
    if (negative)
        prefix[plen++] = '-';
    else if (flags & F_PLUS)
        prefix[plen++] = '+';
    else if (flags & F_SPACE)
        prefix[plen++] = ' ';
    if ((flags & F_HASH) || is_pointer) {
        if (base == 16 && (n || is_pointer)) {
            prefix[plen++] = '0';
            prefix[plen++] = upper ? 'X' : 'x';
        } else if (base == 8 && zeros == 0 && (n == 0 || digits[n - 1] != '0')) {
            zeros = 1;
        }
    }
    int body = plen + zeros + n;
    int fill = width > body ? width - body : 0;
    if ((flags & F_ZERO) && !(flags & F_MINUS) && precision < 0) {
        zeros += fill;
        fill = 0;
    }
    if (!(flags & F_MINUS))
        pad(s, ' ', fill);
    emit(s, prefix, (size_t)plen);
    pad(s, '0', zeros);
    char out[24];
    for (int i = 0; i < n; i++)
        out[i] = digits[n - 1 - i];
    emit(s, out, (size_t)n);
    if (flags & F_MINUS)
        pad(s, ' ', fill);
}

static int format(sink *s, const char *fmt, va_list ap)
{
    while (*fmt) {
        if (*fmt != '%') {
            const char *start = fmt;
            while (*fmt && *fmt != '%')
                fmt++;
            emit(s, start, (size_t)(fmt - start));
            continue;
        }
        fmt++;
        int flags = 0;
        for (;; fmt++) {
            if (*fmt == '-') flags |= F_MINUS;
            else if (*fmt == '+') flags |= F_PLUS;
            else if (*fmt == ' ') flags |= F_SPACE;
            else if (*fmt == '#') flags |= F_HASH;
            else if (*fmt == '0') flags |= F_ZERO;
            else break;
        }
        int width = 0;
        if (*fmt == '*') {
            width = va_arg(ap, int);
            if (width < 0) {
                flags |= F_MINUS;
                width = -width;
            }
            fmt++;
        } else {
            while (*fmt >= '0' && *fmt <= '9')
                width = width * 10 + (*fmt++ - '0');
        }
        int precision = -1;
        if (*fmt == '.') {
            fmt++;
            precision = 0;
            if (*fmt == '*') {
                precision = va_arg(ap, int);
                if (precision < 0)
                    precision = -1;
                fmt++;
            } else {
                while (*fmt >= '0' && *fmt <= '9')
                    precision = precision * 10 + (*fmt++ - '0');
            }
        }
        /* Length: 0 int, 1 char, 2 short, 3 long, 4 long long, 5 size_t,
         * 6 intmax_t, 7 ptrdiff_t. All 64-bit types except int/char/short. */
        int length = 0;
        switch (*fmt) {
        case 'h':
            length = fmt[1] == 'h' ? 1 : 2;
            fmt += fmt[1] == 'h' ? 2 : 1;
            break;
        case 'l':
            length = fmt[1] == 'l' ? 4 : 3;
            fmt += fmt[1] == 'l' ? 2 : 1;
            break;
        case 'z': length = 5; fmt++; break;
        case 'j': length = 6; fmt++; break;
        case 't': length = 7; fmt++; break;
        case 'L': fmt++; break;
        }
        char conv = *fmt;
        if (!conv)
            break;
        fmt++;
        switch (conv) {
        case 'd':
        case 'i': {
            intmax_t v;
            if (length >= 3)
                v = va_arg(ap, long long);   /* all 64-bit on AArch64 */
            else
                v = va_arg(ap, int);
            if (length == 1)
                v = (signed char)v;
            else if (length == 2)
                v = (short)v;
            uintmax_t mag = v < 0 ? (uintmax_t)0 - (uintmax_t)v : (uintmax_t)v;
            format_integer(s, mag, v < 0, 10, 0, flags, width, precision, 0);
            break;
        }
        case 'u':
        case 'o':
        case 'x':
        case 'X': {
            uintmax_t v;
            if (length >= 3)
                v = va_arg(ap, unsigned long long);
            else
                v = va_arg(ap, unsigned int);
            if (length == 1)
                v = (unsigned char)v;
            else if (length == 2)
                v = (unsigned short)v;
            int base = conv == 'u' ? 10 : conv == 'o' ? 8 : 16;
            format_integer(s, v, 0, base, conv == 'X',
                           flags & ~(F_PLUS | F_SPACE), width, precision, 0);
            break;
        }
        case 'p': {
            uintptr_t v = (uintptr_t)va_arg(ap, void *);
            format_integer(s, v, 0, 16, 0, flags & ~(F_PLUS | F_SPACE | F_HASH),
                           width, precision, 1);
            break;
        }
        case 'c': {
            char c = (char)va_arg(ap, int);
            if (!(flags & F_MINUS))
                pad(s, ' ', width - 1);
            emit(s, &c, 1);
            if (flags & F_MINUS)
                pad(s, ' ', width - 1);
            break;
        }
        case 's': {
            const char *str = va_arg(ap, const char *);
            if (!str)
                str = "(null)";
            size_t n = precision >= 0 ? strnlen(str, (size_t)precision) : strlen(str);
            int fill = width > (int)n ? width - (int)n : 0;
            if (!(flags & F_MINUS))
                pad(s, ' ', fill);
            emit(s, str, n);
            if (flags & F_MINUS)
                pad(s, ' ', fill);
            break;
        }
        case 'n': {
            void *p = va_arg(ap, void *);
            switch (length) {
            case 1: *(signed char *)p = (signed char)s->len; break;
            case 2: *(short *)p = (short)s->len; break;
            case 0: *(int *)p = (int)s->len; break;
            default: *(long long *)p = (long long)s->len; break;
            }
            break;
        }
        case '%':
            emit(s, "%", 1);
            break;
        case 'f': case 'F': case 'e': case 'E': case 'g': case 'G': case 'a': case 'A':
            emit(s, "?", 1);
            break;
        default:
            /* Unknown conversion: print it as written. */
            emit(s, "%", 1);
            emit(s, &conv, 1);
            break;
        }
    }
    return s->len > 0x7fffffff ? -1 : (int)s->len;
}

static void put_string(sink *s, const char *p, size_t n)
{
    if (s->len < s->cap) {
        size_t room = s->cap - s->len;
        memcpy(s->buf + s->len, p, n < room ? n : room);
    }
}

static void put_file(sink *s, const char *p, size_t n)
{
    fwrite(p, 1, n, s->file);
}

int vsnprintf(char *restrict buf, size_t n, const char *restrict fmt, va_list ap)
{
    sink s = { put_string, buf, n ? n - 1 : 0, 0, NULL };
    int r = format(&s, fmt, ap);
    if (n)
        buf[s.len < n - 1 ? s.len : n - 1] = '\0';
    return r;
}

int vsprintf(char *restrict buf, const char *restrict fmt, va_list ap)
{
    return vsnprintf(buf, (size_t)-1 >> 1, fmt, ap);
}

int vfprintf(FILE *restrict f, const char *restrict fmt, va_list ap)
{
    sink s = { put_file, NULL, 0, 0, f };
    int r = format(&s, fmt, ap);
    return ferror(f) ? -1 : r;
}

int vprintf(const char *restrict fmt, va_list ap)
{
    return vfprintf(stdout, fmt, ap);
}

int printf(const char *restrict fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int r = vfprintf(stdout, fmt, ap);
    va_end(ap);
    return r;
}

int fprintf(FILE *restrict f, const char *restrict fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int r = vfprintf(f, fmt, ap);
    va_end(ap);
    return r;
}

int sprintf(char *restrict buf, const char *restrict fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int r = vsprintf(buf, fmt, ap);
    va_end(ap);
    return r;
}

int snprintf(char *restrict buf, size_t n, const char *restrict fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int r = vsnprintf(buf, n, fmt, ap);
    va_end(ap);
    return r;
}
