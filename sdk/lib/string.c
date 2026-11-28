/* SPDX-License-Identifier: MIT */
/* string.h. The compiler may emit calls to memcpy/memset/memmove/memcmp
 * itself (struct copies), so those four must exist even in tiny programs. */
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <ctype.h>

void *memcpy(void *restrict dst, const void *restrict src, size_t n)
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    /* Word copies when both pointers share alignment. */
    if ((((uintptr_t)d ^ (uintptr_t)s) & 7) == 0) {
        while (n && ((uintptr_t)d & 7)) {
            *d++ = *s++;
            n--;
        }
        uint64_t *dw = (uint64_t *)d;
        const uint64_t *sw = (const uint64_t *)s;
        for (; n >= 32; n -= 32) {
            uint64_t a = sw[0], b = sw[1], c = sw[2], e = sw[3];
            dw[0] = a; dw[1] = b; dw[2] = c; dw[3] = e;
            dw += 4; sw += 4;
        }
        for (; n >= 8; n -= 8)
            *dw++ = *sw++;
        d = (unsigned char *)dw;
        s = (const unsigned char *)sw;
    }
    while (n--)
        *d++ = *s++;
    return dst;
}

void *memmove(void *dst, const void *src, size_t n)
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    if (d == s || n == 0)
        return dst;
    if (d < s || d >= s + n)
        return memcpy(dst, src, n);
    d += n;
    s += n;
    while (n--)
        *--d = *--s;
    return dst;
}

void *memset(void *dst, int c, size_t n)
{
    unsigned char *d = dst;
    while (n && ((uintptr_t)d & 7)) {
        *d++ = (unsigned char)c;
        n--;
    }
    uint64_t w = (unsigned char)c * 0x0101010101010101ull;
    uint64_t *dw = (uint64_t *)d;
    for (; n >= 8; n -= 8)
        *dw++ = w;
    d = (unsigned char *)dw;
    while (n--)
        *d++ = (unsigned char)c;
    return dst;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *x = a, *y = b;
    for (; n; n--, x++, y++)
        if (*x != *y)
            return *x - *y;
    return 0;
}

void *memchr(const void *s, int c, size_t n)
{
    const unsigned char *p = s;
    for (; n; n--, p++)
        if (*p == (unsigned char)c)
            return (void *)p;
    return NULL;
}

size_t strlen(const char *s)
{
    const char *p = s;
    while (*p)
        p++;
    return (size_t)(p - s);
}

size_t strnlen(const char *s, size_t max)
{
    size_t n = 0;
    while (n < max && s[n])
        n++;
    return n;
}

char *strcpy(char *restrict dst, const char *restrict src)
{
    char *d = dst;
    while ((*d++ = *src++))
        ;
    return dst;
}

char *strncpy(char *restrict dst, const char *restrict src, size_t n)
{
    size_t i = 0;
    for (; i < n && src[i]; i++)
        dst[i] = src[i];
    for (; i < n; i++)
        dst[i] = '\0';
    return dst;
}

char *strcat(char *restrict dst, const char *restrict src)
{
    strcpy(dst + strlen(dst), src);
    return dst;
}

char *strncat(char *restrict dst, const char *restrict src, size_t n)
{
    char *d = dst + strlen(dst);
    while (n-- && *src)
        *d++ = *src++;
    *d = '\0';
    return dst;
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return (unsigned char)*a - (unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n)
{
    for (; n; n--, a++, b++) {
        if (*a != *b)
            return (unsigned char)*a - (unsigned char)*b;
        if (!*a)
            break;
    }
    return 0;
}

int strcasecmp(const char *a, const char *b)
{
    int x, y;
    do {
        x = tolower((unsigned char)*a++);
        y = tolower((unsigned char)*b++);
    } while (x && x == y);
    return x - y;
}

int strncasecmp(const char *a, const char *b, size_t n)
{
    for (; n; n--) {
        int x = tolower((unsigned char)*a++);
        int y = tolower((unsigned char)*b++);
        if (x != y)
            return x - y;
        if (!x)
            break;
    }
    return 0;
}

int strcoll(const char *a, const char *b)
{
    return strcmp(a, b);
}

char *strchr(const char *s, int c)
{
    for (;; s++) {
        if (*s == (char)c)
            return (char *)s;
        if (!*s)
            return NULL;
    }
}

char *strrchr(const char *s, int c)
{
    const char *last = NULL;
    for (;; s++) {
        if (*s == (char)c)
            last = s;
        if (!*s)
            return (char *)last;
    }
}

char *strstr(const char *hay, const char *needle)
{
    size_t n = strlen(needle);
    if (!n)
        return (char *)hay;
    for (; *hay; hay++)
        if (*hay == *needle && !strncmp(hay, needle, n))
            return (char *)hay;
    return NULL;
}

size_t strspn(const char *s, const char *accept)
{
    size_t n = 0;
    while (s[n] && strchr(accept, s[n]))
        n++;
    return n;
}

size_t strcspn(const char *s, const char *reject)
{
    size_t n = 0;
    while (s[n] && !strchr(reject, s[n]))
        n++;
    return n;
}

char *strpbrk(const char *s, const char *accept)
{
    s += strcspn(s, accept);
    return *s ? (char *)s : NULL;
}

char *strtok_r(char *restrict s, const char *restrict delim, char **restrict save)
{
    if (!s)
        s = *save;
    if (!s)
        return NULL;
    s += strspn(s, delim);
    if (!*s) {
        *save = NULL;
        return NULL;
    }
    char *end = s + strcspn(s, delim);
    if (*end) {
        *end = '\0';
        *save = end + 1;
    } else {
        *save = NULL;
    }
    return s;
}

char *strtok(char *restrict s, const char *restrict delim)
{
    static char *save;
    return strtok_r(s, delim, &save);
}

char *strdup(const char *s)
{
    size_t n = strlen(s) + 1;
    char *d = malloc(n);
    return d ? memcpy(d, s, n) : NULL;
}

char *strndup(const char *s, size_t n)
{
    n = strnlen(s, n);
    char *d = malloc(n + 1);
    if (!d)
        return NULL;
    memcpy(d, s, n);
    d[n] = '\0';
    return d;
}

char *strupr(char *s)
{
    for (char *p = s; *p; p++)
        *p = (char)toupper((unsigned char)*p);
    return s;
}

char *strlwr(char *s)
{
    for (char *p = s; *p; p++)
        *p = (char)tolower((unsigned char)*p);
    return s;
}
