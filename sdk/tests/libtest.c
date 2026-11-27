/* SPDX-License-Identifier: MIT */
/*
 * LIBTEST.EXE: libarmdos checks that run inside ARM DOS (tools/sdk_test.py).
 * Prints "LIBTEST PASS n" or a "FAIL:" line per broken check, and leaves
 * LIBTEST.OUT (text) and LIBTEST.BIN (binary) for the host to verify.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <armdos.h>

const char *__armdos_progname = "LIBTEST";

static int checks, failures;

#define CHECK(cond) check((cond), #cond, __LINE__)
static void check(int ok, const char *what, int line)
{
    checks++;
    if (!ok) {
        failures++;
        printf("FAIL: line %d: %s\n", line, what);
    }
}

static void test_printf(void)
{
    char buf[256];
#define CASE(expected, ...) \
    snprintf(buf, sizeof buf, __VA_ARGS__); \
    checks++; \
    if (strcmp(buf, expected)) { \
        failures++; \
        printf("FAIL: printf %s gave [%s], want [%s]\n", #__VA_ARGS__, buf, expected); \
    }
#include "printf_cases.h"
#undef CASE
    /* Truncation and return values. */
    CHECK(snprintf(buf, 4, "%s", "abcdef") == 6 && !strcmp(buf, "abc"));
    CHECK(snprintf(NULL, 0, "%d", 12345) == 5);
    CHECK(sprintf(buf, "%s-%d", "x", 7) == 3 && !strcmp(buf, "x-7"));
    int n = 0;
    snprintf(buf, sizeof buf, "abc%n", &n);
    CHECK(n == 3);
}

static int cmp_int(const void *a, const void *b)
{
    int x = *(const int *)a, y = *(const int *)b;
    return (x > y) - (x < y);
}

static void test_string_stdlib(void)
{
    char buf[64];
    CHECK(strlen("hello") == 5);
    CHECK(strcmp("abc", "abd") < 0 && strcmp("b", "a") > 0 && !strcmp("x", "x"));
    CHECK(strncmp("abcx", "abcy", 3) == 0);
    CHECK(strcasecmp("Hello", "hELLO") == 0);
    CHECK(!strcmp(strcat(strcpy(buf, "foo"), "bar"), "foobar"));
    CHECK(strchr("hello", 'l') - (const char *)"hello" >= 0);
    CHECK(!strcmp(strrchr("a\\b\\c", '\\'), "\\c"));
    CHECK(!strcmp(strstr("needle in haystack", "hay"), "haystack"));
    CHECK(strspn("aabbc", "ab") == 4 && strcspn("hello", "l") == 2);
    char tok[] = "a, b,,c";
    CHECK(!strcmp(strtok(tok, ", "), "a") && !strcmp(strtok(NULL, ", "), "b") &&
          !strcmp(strtok(NULL, ", "), "c") && strtok(NULL, ", ") == NULL);
    memset(buf, 'x', 10);
    CHECK(buf[0] == 'x' && buf[9] == 'x' && memcmp(buf, "xxxxxxxxxx", 10) == 0);
    strcpy(buf, "0123456789");
    memmove(buf + 2, buf, 5);
    CHECK(!strcmp(buf, "0101234789"));
    memmove(buf, buf + 2, 5);
    CHECK(!memcmp(buf, "01234", 5));
    CHECK(isalpha('a') && !isalpha('1') && isdigit('7') && isspace('\t') &&
          toupper('q') == 'Q' && tolower('Q') == 'q' && isxdigit('F'));
    CHECK(atoi("  -123x") == -123 && atol("99") == 99);
    char *end;
    CHECK(strtol("0x1f", &end, 0) == 31 && *end == '\0');
    CHECK(strtol("077", NULL, 0) == 63 && strtol("z", &end, 36) == 35);
    CHECK(strtoul("12abc", &end, 10) == 12 && !strcmp(end, "abc"));
    errno = 0;
    CHECK(strtol("99999999999999999999", NULL, 10) == LONG_MAX && errno == ERANGE);
    CHECK(strtoll("-9223372036854775808", NULL, 10) == LLONG_MIN);
    CHECK(abs(-5) == 5 && labs(-7L) == 7);
    int v[] = { 5, 3, 9, 1, 7, 2, 8, 6, 4, 0 };
    qsort(v, 10, sizeof v[0], cmp_int);
    int sorted = 1;
    for (int i = 0; i < 10; i++)
        sorted &= v[i] == i;
    CHECK(sorted);
    int key = 7;
    CHECK(bsearch(&key, v, 10, sizeof v[0], cmp_int) == &v[7]);
}

static void test_malloc(void)
{
    /* Many small blocks, freed in an interleaved order, then large ones:
     * the heap must grow past its first 256 KiB DOS block and coalesce. */
    void *p[200];
    for (int i = 0; i < 200; i++) {
        p[i] = malloc((size_t)(i * 37 % 1000) + 1);
        CHECK(p[i] && ((unsigned long)p[i] & 15) == 0);
        if (p[i])
            memset(p[i], i, (size_t)(i * 37 % 1000) + 1);
    }
    int intact = 1;
    for (int i = 0; i < 200; i++)
        intact &= p[i] && ((unsigned char *)p[i])[0] == (unsigned char)i;
    CHECK(intact);
    for (int i = 0; i < 200; i += 2)
        free(p[i]);
    for (int i = 1; i < 200; i += 2)
        free(p[i]);
    char *big = malloc(3u << 20);
    CHECK(big != NULL);
    if (big) {
        big[0] = 1;
        big[(3u << 20) - 1] = 2;
    }
    char *r = malloc(16);
    strcpy(r, "grow me");
    r = realloc(r, 100000);
    CHECK(r && !strcmp(r, "grow me"));
    free(r);
    free(big);
    int *z = calloc(1000, sizeof(int));
    int zero = z != NULL;
    for (int i = 0; z && i < 1000; i++)
        zero &= z[i] == 0;
    CHECK(zero);
    free(z);
    errno = 0;
    CHECK(malloc(64u << 20) == NULL && errno == ENOMEM);
}

static void test_files(void)
{
    /* Text mode: "\n" -> CR LF on disk, back to "\n" when read. */
    FILE *f = fopen("LIBTEST.OUT", "w");
    CHECK(f != NULL);
    if (!f)
        return;
    for (int i = 1; i <= 50; i++)
        fprintf(f, "line %02d: %s\n", i, i % 2 ? "odd" : "even");
    CHECK(ftell(f) == 50 * 16L);     /* 14 or 15 characters + CR LF */
    CHECK(fclose(f) == 0);

    f = fopen("LIBTEST.OUT", "r");
    CHECK(f != NULL);
    if (!f)
        return;
    char line[64];
    int lines = 0, good = 1;
    while (fgets(line, sizeof line, f)) {
        lines++;
        char want[32];
        snprintf(want, sizeof want, "line %02d: %s\n", lines, lines % 2 ? "odd" : "even");
        good &= !strcmp(line, want);
    }
    CHECK(lines == 50 && good);
    CHECK(feof(f) && !ferror(f));
    /* Seek back to a position ftell reported and read again. */
    CHECK(fseek(f, 16 * 9, SEEK_SET) == 0);
    long here = ftell(f);
    CHECK(fgets(line, sizeof line, f) && !strcmp(line, "line 10: even\n"));
    CHECK(here == 144 && ftell(f) == 160);
    CHECK(fseek(f, -16, SEEK_END) == 0 && fgets(line, sizeof line, f) &&
          !strcmp(line, "line 50: even\n"));
    rewind(f);
    CHECK(fgetc(f) == 'l' && ungetc('L', f) == 'L' && fgetc(f) == 'L');
    fclose(f);

    /* Append mode adds at the end. */
    f = fopen("LIBTEST.OUT", "a");
    CHECK(f && fputs("appended\n", f) >= 0 && fclose(f) == 0);

    /* Binary mode: every byte value survives, large and small writes. */
    static unsigned char data[5000];
    for (int i = 0; i < 5000; i++)
        data[i] = (unsigned char)(i * 7 + i / 256);
    f = fopen("LIBTEST.BIN", "wb");
    CHECK(f && fwrite(data, 1, 100, f) == 100 && fwrite(data + 100, 1, 4900, f) == 4900);
    CHECK(f && fclose(f) == 0);
    static unsigned char back[5000];
    f = fopen("LIBTEST.BIN", "rb");
    CHECK(f && fread(back, 1, 10, f) == 10 && fread(back + 10, 1, 6000, f) == 4990);
    CHECK(!memcmp(data, back, 5000));
    if (f) {
        CHECK(fseek(f, 4000, SEEK_SET) == 0 && fgetc(f) == data[4000]);
        fclose(f);
    }
    /* r+ : overwrite in the middle. */
    f = fopen("LIBTEST.BIN", "r+b");
    CHECK(f && fseek(f, 10, SEEK_SET) == 0 && fwrite("ARMDOS", 1, 6, f) == 6);
    if (f) {
        CHECK(fseek(f, 8, SEEK_SET) == 0 && fread(back, 1, 10, f) == 10 &&
              !memcmp(back + 2, "ARMDOS", 6) && back[0] == data[8]);
        fclose(f);
    }

    /* errno from DOS error codes. */
    errno = 0;
    CHECK(fopen("NOSUCH.TXT", "r") == NULL && errno == ENOENT && _doserrno == 2);
    CHECK(fopen("\\NODIR\\X.TXT", "r") == NULL && errno == ENOENT && _doserrno == 3);
    dos_ext_error e;
    CHECK(dos_get_ext_error(&e) == 3);
    CHECK(remove("NOSUCH.TXT") == -1 && errno == ENOENT);
}

static void test_dos(void)
{
    char buf[128];
    /* Directories: mkdir, chdir, getcwd, rename, find, rmdir. */
    CHECK(dos_mkdir("SDKDIR") == 0);
    CHECK(dos_mkdir("SDKDIR") < 0);
    CHECK(dos_chdir("SDKDIR") == 0);
    CHECK(dos_getcwd(0, buf, sizeof buf) == 0 && !strcmp(buf, "SDKDIR"));
    long h = dos_create("A.TMP", 0);
    CHECK(h >= 0 && dos_write((int)h, "12345", 5) == 5);
    CHECK(dos_seek((int)h, 0, DOS_SEEK_END) == 5 && dos_seek((int)h, 1, DOS_SEEK_SET) == 1);
    CHECK(dos_read((int)h, buf, 10) == 4 && !memcmp(buf, "2345", 4));
    CHECK(dos_ioctl_get_info((int)h) == 0);
    CHECK(dos_close((int)h) == 0 && dos_close((int)h) == -DOSERR_INVALID_HANDLE);
    CHECK(dos_rename("A.TMP", "B.TMP") == 0);
    CHECK(dos_truename("B.TMP", buf) == 0 && !strcmp(buf, "A:\\SDKDIR\\B.TMP"));
    dos_dta dta;
    CHECK(dos_find_first("*.TMP", 0, &dta) == 0 && !strcmp(dta.name, "B.TMP") &&
          dta.size == 5);
    CHECK(dos_find_next(&dta) == -DOSERR_NO_MORE_FILES);
    CHECK(dos_set_attributes("B.TMP", DOS_A_RDONLY) == 0 &&
          dos_get_attributes("B.TMP") == DOS_A_RDONLY);
    CHECK(dos_delete("B.TMP") == -DOSERR_ACCESS_DENIED);
    CHECK(dos_set_attributes("B.TMP", 0) == 0 && dos_delete("B.TMP") == 0);
    CHECK(dos_chdir("\\") == 0 && dos_rmdir("SDKDIR") == 0);
    CHECK(dos_getcwd(0, buf, sizeof buf) == 0 && buf[0] == '\0');
    /* Console handles are devices. */
    CHECK((dos_ioctl_get_info(DOS_STDOUT) & DOS_DEV_ISDEV) != 0);
    /* Memory blocks: allocate, resize within capacity, free. */
    void *m = dos_alloc(1000);
    size_t max = 0;
    CHECK(m != NULL && dos_resize(m, 65536, NULL) == 0);
    CHECK(dos_resize(m, 1 << 20, &max) == -DOSERR_NO_MEMORY && max == 65536);
    CHECK(dos_free(m) == 0 && dos_free(m) == -DOSERR_INVALID_BLOCK);
    /* Time and version. */
    dos_date d;
    dos_time t;
    dos_get_date(&d);
    dos_get_time(&t);
    CHECK(d.year >= 1980 && d.month >= 1 && d.month <= 12 && d.day >= 1 && d.day <= 31);
    CHECK(t.hour < 24 && t.minute < 60 && t.second < 60);
    CHECK(dos_version() == 4);
    CHECK(dos_get_drive() == 0);
    CHECK(getenv("COMSPEC") != NULL && getenv("comspec") == getenv("COMSPEC"));
    CHECK(getenv("NO_SUCH_VARIABLE") == NULL);
}

/* Static data with pointers needs loader fixups (IMAGE_REL_BASED_DIR64). */
static const char *const names[] = { "zero", "one", "two" };
static int (*const fns[])(const void *, const void *) = { cmp_int };

int main(int argc, char **argv)
{
    CHECK(argc == 3 && !strcmp(argv[0], "LIBTEST") && !strcmp(argv[1], "quoted arg") &&
          !strcmp(argv[2], "x\"y"));
    CHECK(!strcmp(names[2], "two") && fns[0] == cmp_int);
    test_printf();
    test_string_stdlib();
    test_malloc();
    test_files();
    test_dos();
    if (failures) {
        printf("LIBTEST FAIL %d of %d\n", failures, checks);
        return 1;
    }
    printf("LIBTEST PASS %d\n", checks);
    return 0;
}
