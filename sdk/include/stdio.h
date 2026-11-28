/* SPDX-License-Identifier: MIT */
/*
 * Buffered stdio over DOS handles. Streams are text mode unless the mode
 * string contains 'b': "\n" is written as CR LF, CR is dropped on input and
 * Ctrl-Z ends a text file. No floating-point conversions in printf.
 */
#ifndef _ARMDOS_STDIO_H
#define _ARMDOS_STDIO_H
#include <stddef.h>
#include <stdarg.h>
#ifdef __cplusplus
extern "C" {
#endif
#define EOF (-1)
#define BUFSIZ 1024
#define FOPEN_MAX 20
#define FILENAME_MAX 128
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#define _IOFBF 0
#define _IOLBF 1
#define _IONBF 2

typedef struct __armdos_file FILE;
typedef long fpos_t;
extern FILE *stdin, *stdout, *stderr;

FILE *fopen(const char *restrict path, const char *restrict mode);
FILE *fdopen(int handle, const char *mode);
FILE *freopen(const char *restrict path, const char *restrict mode, FILE *restrict f);
int fclose(FILE *f);
int fflush(FILE *f);
int setvbuf(FILE *restrict f, char *restrict buf, int mode, size_t size);
void setbuf(FILE *restrict f, char *restrict buf);
size_t fread(void *restrict buf, size_t size, size_t count, FILE *restrict f);
size_t fwrite(const void *restrict buf, size_t size, size_t count, FILE *restrict f);
int fgetc(FILE *f);
int getc(FILE *f);
int getchar(void);
int ungetc(int c, FILE *f);
char *fgets(char *restrict s, int size, FILE *restrict f);
int fputc(int c, FILE *f);
int putc(int c, FILE *f);
int putchar(int c);
int fputs(const char *restrict s, FILE *restrict f);
int puts(const char *s);
int fseek(FILE *f, long offset, int whence);
long ftell(FILE *f);
void rewind(FILE *f);
int fgetpos(FILE *restrict f, fpos_t *restrict pos);
int fsetpos(FILE *f, const fpos_t *pos);
int feof(FILE *f);
int ferror(FILE *f);
void clearerr(FILE *f);
int fileno(FILE *f);
int remove(const char *path);
int rename(const char *from, const char *to);
void perror(const char *s);

int printf(const char *restrict fmt, ...) __attribute__((format(printf, 1, 2)));
int fprintf(FILE *restrict f, const char *restrict fmt, ...) __attribute__((format(printf, 2, 3)));
int sprintf(char *restrict s, const char *restrict fmt, ...) __attribute__((format(printf, 2, 3)));
int snprintf(char *restrict s, size_t n, const char *restrict fmt, ...) __attribute__((format(printf, 3, 4)));
int vprintf(const char *restrict fmt, va_list ap);
int vfprintf(FILE *restrict f, const char *restrict fmt, va_list ap);
int vsprintf(char *restrict s, const char *restrict fmt, va_list ap);
int vsnprintf(char *restrict s, size_t n, const char *restrict fmt, va_list ap);
#ifdef __cplusplus
}
#endif
#endif
