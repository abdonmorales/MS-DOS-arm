/* SPDX-License-Identifier: MIT */
#ifndef _ARMDOS_STDLIB_H
#define _ARMDOS_STDLIB_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#define RAND_MAX 0x7fffffff
typedef struct { int quot, rem; } div_t;
typedef struct { long quot, rem; } ldiv_t;
void *malloc(size_t size);
void *calloc(size_t count, size_t size);
void *realloc(void *ptr, size_t size);
void free(void *ptr);
__attribute__((noreturn)) void exit(int code);
__attribute__((noreturn)) void _Exit(int code);
__attribute__((noreturn)) void _exit(int code);
__attribute__((noreturn)) void abort(void);
int atexit(void (*fn)(void));
char *getenv(const char *name);
extern char **environ;
int abs(int x);
long labs(long x);
long long llabs(long long x);
div_t div(int a, int b);
ldiv_t ldiv(long a, long b);
int atoi(const char *s);
long atol(const char *s);
long long atoll(const char *s);
long strtol(const char *restrict s, char **restrict end, int base);
unsigned long strtoul(const char *restrict s, char **restrict end, int base);
long long strtoll(const char *restrict s, char **restrict end, int base);
unsigned long long strtoull(const char *restrict s, char **restrict end, int base);
void qsort(void *base, size_t count, size_t size,
           int (*compare)(const void *, const void *));
void *bsearch(const void *key, const void *base, size_t count, size_t size,
              int (*compare)(const void *, const void *));
int rand(void);
void srand(unsigned seed);
/* Runs a program (4Bh) with a command tail; returns its 4Dh status, or -1.
 * There is no command interpreter lookup: give the program's path. */
int spawn(const char *path, const char *tail);
#ifdef __cplusplus
}
#endif
#endif
