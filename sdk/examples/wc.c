/* SPDX-License-Identifier: MIT */
/*
 * WC.EXE: count lines, words and bytes, like the Unix tool, with DOS
 * wildcards. Shows files (fopen/fread/fgets/fprintf), directory searches
 * (4Eh/4Fh), malloc/qsort and printf field widths.
 *
 *   WC [/L] [/O:report] pattern...
 *     /L         also print each file's longest line
 *     /O:file    write the report to a file as well (CR LF lines)
 * Exit code: 0, or 1 if some pattern matched nothing or a file failed.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <armdos.h>

const char *__armdos_progname = "WC";

typedef struct result {
    char name[160];
    unsigned long lines, words, bytes;
    unsigned long longest;      /* longest line, in characters */
} result;

static result *results;
static size_t count, capacity;

static int count_file(const char *path, result *r)
{
    /* Binary mode: count the bytes on disk, CR LF included. */
    FILE *f = fopen(path, "rb");
    if (!f)
        return -1;
    unsigned char buf[2048];
    size_t n, line = 0;
    int in_word = 0;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) {
        r->bytes += n;
        for (size_t i = 0; i < n; i++) {
            int c = buf[i];
            if (c == '\n') {
                r->lines++;
                if (line > r->longest)
                    r->longest = line;
                line = 0;
            } else if (c != '\r') {
                line++;
            }
            if (isspace(c))
                in_word = 0;
            else if (!in_word) {
                in_word = 1;
                r->words++;
            }
        }
    }
    if (line > r->longest)
        r->longest = line;
    int failed = ferror(f);
    fclose(f);
    return failed ? -1 : 0;
}

static result *add_result(void)
{
    if (count == capacity) {
        size_t grown = capacity ? capacity * 2 : 8;
        result *n = realloc(results, grown * sizeof *n);
        if (!n) {
            fprintf(stderr, "WC: out of memory\n");
            exit(2);
        }
        results = n;
        capacity = grown;
    }
    result *r = &results[count++];
    memset(r, 0, sizeof *r);
    return r;
}

static int by_name(const void *a, const void *b)
{
    return strcmp(((const result *)a)->name, ((const result *)b)->name);
}

/* Expands one pattern; the directory part is kept for opening. */
static int expand(const char *pattern)
{
    char dir[160];
    const char *base = pattern;
    for (const char *p = pattern; *p; p++)
        if (*p == '\\' || *p == '/' || *p == ':')
            base = p + 1;
    size_t dlen = (size_t)(base - pattern);
    if (dlen >= sizeof dir - 13) {
        fprintf(stderr, "WC: %s: path too long\n", pattern);
        return -1;
    }
    memcpy(dir, pattern, dlen);
    dir[dlen] = '\0';

    dos_dta dta;
    long rc = dos_find_first(pattern, 0, &dta);
    if (rc < 0) {
        __armdos_seterrno(rc);
        fprintf(stderr, "WC: %s: %s\n", pattern, strerror(errno));
        return -1;
    }
    int status = 0;
    do {
        result *r = add_result();
        snprintf(r->name, sizeof r->name, "%s%s", dir, dta.name);
        if (count_file(r->name, r) < 0) {
            fprintf(stderr, "WC: %s: %s\n", r->name, strerror(errno));
            count--;
            status = -1;
        } else if (r->bytes != dta.size) {
            fprintf(stderr, "WC: %s: size %lu but directory says %llu\n",
                    r->name, r->bytes, (unsigned long long)dta.size);
            status = -1;
        }
    } while (dos_find_next(&dta) == 0);
    return status;
}

static void report(FILE *out, int longest)
{
    unsigned long lines = 0, words = 0, bytes = 0;
    fprintf(out, "%7s %7s %8s  %s\n", "lines", "words", "bytes", "file");
    for (size_t i = 0; i < count; i++) {
        const result *r = &results[i];
        fprintf(out, "%7lu %7lu %8lu  %-12s", r->lines, r->words, r->bytes, r->name);
        if (longest)
            fprintf(out, " (longest line %lu)", r->longest);
        fputc('\n', out);
        lines += r->lines;
        words += r->words;
        bytes += r->bytes;
    }
    fprintf(out, "%7lu %7lu %8lu  total (%zu file%s)\n", lines, words, bytes,
            count, count == 1 ? "" : "s");
}

int main(int argc, char **argv)
{
    int longest = 0, status = 0, patterns = 0;
    const char *output = NULL;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (a[0] == '/' && toupper((unsigned char)a[1]) == 'L' && !a[2]) {
            longest = 1;
        } else if (a[0] == '/' && toupper((unsigned char)a[1]) == 'O' && a[2] == ':') {
            output = a + 3;
        } else if (a[0] == '/') {
            fprintf(stderr, "WC: unknown switch %s\n", a);
            return 2;
        } else {
            patterns++;
            if (expand(a) < 0)
                status = 1;
        }
    }
    if (!patterns) {
        fputs("usage: WC [/L] [/O:report] pattern...\n", stderr);
        return 2;
    }
    qsort(results, count, sizeof *results, by_name);
    report(stdout, longest);
    if (output) {
        FILE *f = fopen(output, "w");
        if (!f || (report(f, longest), fclose(f)) != 0) {
            perror(output);
            return 1;
        }
        printf("Report written to %s\n", output);
    }
    return status;
}
