/* SPDX-License-Identifier: MIT */
#ifndef _ARMDOS_STRING_H
#define _ARMDOS_STRING_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
void *memcpy(void *restrict dst, const void *restrict src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
void *memchr(const void *s, int c, size_t n);
size_t strlen(const char *s);
size_t strnlen(const char *s, size_t max);
char *strcpy(char *restrict dst, const char *restrict src);
char *strncpy(char *restrict dst, const char *restrict src, size_t n);
char *strcat(char *restrict dst, const char *restrict src);
char *strncat(char *restrict dst, const char *restrict src, size_t n);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t n);
int strcasecmp(const char *a, const char *b);
int strncasecmp(const char *a, const char *b, size_t n);
#define stricmp strcasecmp
#define strnicmp strncasecmp
int strcoll(const char *a, const char *b);
char *strchr(const char *s, int c);
char *strrchr(const char *s, int c);
char *strstr(const char *hay, const char *needle);
size_t strspn(const char *s, const char *accept);
size_t strcspn(const char *s, const char *reject);
char *strpbrk(const char *s, const char *accept);
char *strtok(char *restrict s, const char *restrict delim);
char *strtok_r(char *restrict s, const char *restrict delim, char **restrict save);
char *strdup(const char *s);
char *strndup(const char *s, size_t n);
char *strupr(char *s);
char *strlwr(char *s);
char *strerror(int errnum);
#ifdef __cplusplus
}
#endif
#endif
