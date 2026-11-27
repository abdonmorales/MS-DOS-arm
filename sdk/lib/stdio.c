/* SPDX-License-Identifier: MIT */
/*
 * Buffered streams on DOS handles.
 *
 * A stream's buffer holds raw file bytes; text-mode translation (CR LF on
 * output, CR dropped and Ctrl-Z as end of file on input) happens while
 * bytes move between the caller and that buffer. So ftell() is always the
 * raw handle position minus what is buffered and not yet consumed, or plus
 * what is buffered and not yet written, and fseek() can go anywhere a later
 * ftell() reported.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <armdos.h>

#define F_READ    0x01
#define F_WRITE   0x02
#define F_TEXT    0x04
#define F_APPEND  0x08
#define F_EOF     0x10
#define F_ERR     0x20
#define F_LINEBUF 0x40
#define F_UNBUF   0x80
#define F_OWNBUF  0x100         /* buffer came from malloc */
#define F_INUSE   0x200
#define F_DEVICE  0x400

struct __armdos_file {
    int handle;
    int flags;
    unsigned char *buf;
    size_t size;
    size_t pos;                 /* reading: next byte; writing: bytes queued */
    size_t len;                 /* reading: bytes valid */
    int mode;                   /* 0 idle, F_READ or F_WRITE: what buf holds */
    int ungot;                  /* ungetc() character or EOF */
};

static FILE files[FOPEN_MAX];
static unsigned char std_bufs[3][BUFSIZ];
FILE *stdin = &files[0];
FILE *stdout = &files[1];
FILE *stderr = &files[2];

static void setup(FILE *f, int handle, int flags, unsigned char *buf, size_t size)
{
    memset(f, 0, sizeof *f);
    f->handle = handle;
    f->flags = flags | F_INUSE;
    f->buf = buf;
    f->size = size;
    f->ungot = EOF;
    long info = dos_ioctl_get_info(handle);
    if (info > 0 && (info & DOS_DEV_ISDEV))
        f->flags |= F_DEVICE;
}

void __armdos_stdio_init(void)
{
    setup(stdin, DOS_STDIN, F_READ | F_TEXT, std_bufs[0], BUFSIZ);
    setup(stdout, DOS_STDOUT, F_WRITE | F_TEXT, std_bufs[1], BUFSIZ);
    setup(stderr, DOS_STDERR, F_WRITE | F_TEXT | F_UNBUF, std_bufs[2], BUFSIZ);
    /* Interactive output appears line by line; redirected output is fully
     * buffered (one 40h call per kilobyte instead of per line). */
    if (stdout->flags & F_DEVICE)
        stdout->flags |= F_LINEBUF;
}

/* Writes the queued output bytes. */
static int flush_write(FILE *f)
{
    size_t done = 0;
    while (done < f->pos) {
        long n = dos_write(f->handle, f->buf + done, f->pos - done);
        if (n <= 0) {
            if (n < 0)
                __armdos_seterrno(n);
            else
                errno = ENOSPC;     /* DOS reports a full disk as a short write */
            f->flags |= F_ERR;
            f->pos = 0;
            f->mode = 0;
            return EOF;
        }
        done += (size_t)n;
    }
    f->pos = 0;
    f->mode = 0;
    return 0;
}

/* Gives back read-ahead: moves the handle to the logical position. */
static int drop_read(FILE *f)
{
    long unread = (long)(f->len - f->pos);
    f->pos = f->len = 0;
    f->mode = 0;
    if (f->ungot != EOF) {
        unread++;
        f->ungot = EOF;
    }
    if (unread && !(f->flags & F_DEVICE) && dos_seek(f->handle, -unread, DOS_SEEK_CUR) < 0)
        return EOF;
    return 0;
}

int fflush(FILE *f)
{
    if (!f) {
        int r = 0;
        for (int i = 0; i < FOPEN_MAX; i++)
            if ((files[i].flags & F_INUSE) && fflush(&files[i]))
                r = EOF;
        return r;
    }
    if (f->mode == F_WRITE)
        return flush_write(f);
    if (f->mode == F_READ)
        return drop_read(f);
    return 0;
}

void __armdos_stdio_flush_all(void)
{
    for (int i = 0; i < FOPEN_MAX; i++)
        if ((files[i].flags & F_INUSE) && files[i].mode == F_WRITE)
            flush_write(&files[i]);
}

/* Refills the read buffer; returns 0 at end of file or on error. */
static int fill(FILE *f)
{
    if (f->mode == F_WRITE && flush_write(f))
        return 0;
    /* Reading the console: show any pending prompt first. */
    if ((f->flags & F_DEVICE) && stdout->mode == F_WRITE)
        flush_write(stdout);
    long n = dos_read(f->handle, f->buf, f->size);
    if (n < 0) {
        __armdos_seterrno(n);
        f->flags |= F_ERR;
        return 0;
    }
    if (n == 0) {
        f->flags |= F_EOF;
        return 0;
    }
    f->pos = 0;
    f->len = (size_t)n;
    f->mode = F_READ;
    return 1;
}

/* Next raw-translated character, or EOF. */
int fgetc(FILE *f)
{
    if (!(f->flags & F_READ)) {
        f->flags |= F_ERR;
        errno = EBADF;
        return EOF;
    }
    if (f->ungot != EOF) {
        int c = f->ungot;
        f->ungot = EOF;
        return c;
    }
    if (f->flags & F_EOF)
        return EOF;
    for (;;) {
        if (f->mode != F_READ || f->pos >= f->len) {
            if (!fill(f))
                return EOF;
        }
        int c = f->buf[f->pos++];
        if (f->flags & F_TEXT) {
            if (c == '\r')
                continue;
            if (c == 0x1a) {        /* Ctrl-Z ends a text file */
                f->pos--;
                f->flags |= F_EOF;
                return EOF;
            }
        }
        return c;
    }
}

int getc(FILE *f) { return fgetc(f); }
int getchar(void) { return fgetc(stdin); }

int ungetc(int c, FILE *f)
{
    if (c == EOF || f->ungot != EOF)
        return EOF;
    f->ungot = (unsigned char)c;
    f->flags &= ~F_EOF;
    return (unsigned char)c;
}

static int put_raw(FILE *f, unsigned char c)
{
    if (f->pos >= f->size && flush_write(f))
        return EOF;
    f->buf[f->pos++] = c;
    return 0;
}

/* Prepares a stream for output (switching from reading if needed). */
static int start_write(FILE *f)
{
    if (!(f->flags & F_WRITE)) {
        f->flags |= F_ERR;
        errno = EBADF;
        return EOF;
    }
    if (f->mode == F_READ && drop_read(f))
        return EOF;
    if (f->mode != F_WRITE) {
        if ((f->flags & F_APPEND) && dos_seek(f->handle, 0, DOS_SEEK_END) < 0)
            return EOF;
        f->mode = F_WRITE;
        f->pos = 0;
    }
    return 0;
}

/* After a write call: honour unbuffered / line-buffered streams. */
static int end_write(FILE *f, int saw_newline)
{
    if ((f->flags & F_UNBUF) || ((f->flags & F_LINEBUF) && saw_newline))
        return flush_write(f);
    return 0;
}

static size_t write_bytes(FILE *f, const unsigned char *p, size_t n)
{
    if (start_write(f))
        return 0;
    int newline = 0;
    size_t i = 0;
    if (f->flags & F_TEXT) {
        for (; i < n; i++) {
            if (p[i] == '\n') {
                newline = 1;
                if (put_raw(f, '\r'))
                    break;
            }
            if (put_raw(f, p[i]))
                break;
        }
    } else {
        /* Large binary writes skip the buffer. */
        if (n >= f->size) {
            if (f->pos && flush_write(f))
                return 0;
            f->mode = F_WRITE;
            while (i < n) {
                long w = dos_write(f->handle, p + i, n - i);
                if (w <= 0) {
                    if (w < 0)
                        __armdos_seterrno(w);
                    else
                        errno = ENOSPC;
                    f->flags |= F_ERR;
                    break;
                }
                i += (size_t)w;
            }
            return i;
        }
        for (; i < n; i++) {
            if (put_raw(f, p[i]))
                break;
            if (p[i] == '\n')
                newline = 1;
        }
    }
    end_write(f, newline);     /* a failure sets the error flag */
    return i;
}

int fputc(int c, FILE *f)
{
    unsigned char b = (unsigned char)c;
    return write_bytes(f, &b, 1) == 1 && !(f->flags & F_ERR) ? b : EOF;
}

int putc(int c, FILE *f) { return fputc(c, f); }
int putchar(int c) { return fputc(c, stdout); }

int fputs(const char *restrict s, FILE *restrict f)
{
    size_t n = strlen(s);
    return write_bytes(f, (const unsigned char *)s, n) == n && !(f->flags & F_ERR) ? 0 : EOF;
}

int puts(const char *s)
{
    if (fputs(s, stdout) == EOF || fputc('\n', stdout) == EOF)
        return EOF;
    return 0;
}

size_t fwrite(const void *restrict buf, size_t size, size_t count, FILE *restrict f)
{
    if (!size || !count)
        return 0;
    size_t total = size * count;
    return write_bytes(f, buf, total) / size;
}

size_t fread(void *restrict buf, size_t size, size_t count, FILE *restrict f)
{
    if (!size || !count)
        return 0;
    size_t total = size * count, got = 0;
    unsigned char *out = buf;
    if (f->flags & F_TEXT) {
        while (got < total) {
            int c = fgetc(f);
            if (c == EOF)
                break;
            out[got++] = (unsigned char)c;
        }
        return got / size;
    }
    if (!(f->flags & F_READ)) {
        f->flags |= F_ERR;
        return 0;
    }
    if (f->ungot != EOF) {
        out[got++] = (unsigned char)f->ungot;
        f->ungot = EOF;
    }
    while (got < total && !(f->flags & F_EOF)) {
        if (f->mode == F_READ && f->pos < f->len) {
            size_t n = f->len - f->pos;
            if (n > total - got)
                n = total - got;
            memcpy(out + got, f->buf + f->pos, n);
            f->pos += n;
            got += n;
            continue;
        }
        if (total - got >= f->size) {
            /* Large reads go straight into the caller's buffer. */
            if (f->mode == F_WRITE && flush_write(f))
                break;
            f->mode = 0;
            long n = dos_read(f->handle, out + got, total - got);
            if (n < 0) {
                __armdos_seterrno(n);
                f->flags |= F_ERR;
                break;
            }
            if (n == 0) {
                f->flags |= F_EOF;
                break;
            }
            got += (size_t)n;
            continue;
        }
        if (!fill(f))
            break;
    }
    return got / size;
}

char *fgets(char *restrict s, int size, FILE *restrict f)
{
    if (size <= 0)
        return NULL;
    int i = 0;
    while (i < size - 1) {
        int c = fgetc(f);
        if (c == EOF)
            break;
        s[i++] = (char)c;
        if (c == '\n')
            break;
    }
    if (i == 0)
        return NULL;
    s[i] = '\0';
    return s;
}

/* ---- opening and closing ---- */

static int parse_mode(const char *mode, int *flags)
{
    int f = F_TEXT;
    switch (*mode++) {
    case 'r': f |= F_READ; break;
    case 'w': f |= F_WRITE; break;
    case 'a': f |= F_WRITE | F_APPEND; break;
    default: return -1;
    }
    for (; *mode; mode++) {
        if (*mode == '+')
            f |= F_READ | F_WRITE;
        else if (*mode == 'b')
            f &= ~F_TEXT;
        else if (*mode == 't')
            f |= F_TEXT;
    }
    *flags = f;
    return 0;
}

static FILE *alloc_file(void)
{
    for (int i = 3; i < FOPEN_MAX; i++)
        if (!(files[i].flags & F_INUSE))
            return &files[i];
    return NULL;
}

static FILE *open_into(FILE *f, const char *path, const char *mode)
{
    int flags;
    if (parse_mode(mode, &flags)) {
        errno = EINVAL;
        return NULL;
    }
    long h;
    unsigned access = (flags & F_READ) && (flags & F_WRITE) ? DOS_O_RDWR
                    : (flags & F_WRITE) ? DOS_O_WRONLY : DOS_O_RDONLY;
    if (*mode == 'w') {
        h = dos_create(path, 0);            /* read/write, truncated */
    } else if (*mode == 'a') {
        h = dos_open(path, access);
        if (h == -DOSERR_FILE_NOT_FOUND)
            h = dos_create(path, 0);
    } else {
        h = dos_open(path, access);
    }
    if (h < 0) {
        __armdos_seterrno(h);
        return NULL;
    }
    unsigned char *buf = malloc(BUFSIZ);
    if (!buf) {
        dos_close((int)h);
        errno = ENOMEM;
        return NULL;
    }
    setup(f, (int)h, flags | F_OWNBUF, buf, BUFSIZ);
    return f;
}

FILE *fopen(const char *restrict path, const char *restrict mode)
{
    FILE *f = alloc_file();
    if (!f) {
        errno = EMFILE;
        return NULL;
    }
    return open_into(f, path, mode);
}

FILE *fdopen(int handle, const char *mode)
{
    int flags;
    FILE *f = alloc_file();
    if (!f || parse_mode(mode, &flags)) {
        errno = f ? EINVAL : EMFILE;
        return NULL;
    }
    unsigned char *buf = malloc(BUFSIZ);
    if (!buf) {
        errno = ENOMEM;
        return NULL;
    }
    setup(f, handle, flags | F_OWNBUF, buf, BUFSIZ);
    return f;
}

static int close_stream(FILE *f)
{
    int r = fflush(f);
    if (dos_close(f->handle) < 0)
        r = EOF;
    if (f->flags & F_OWNBUF)
        free(f->buf);
    f->flags = 0;
    return r;
}

int fclose(FILE *f)
{
    if (!f || !(f->flags & F_INUSE))
        return EOF;
    return close_stream(f);
}

FILE *freopen(const char *restrict path, const char *restrict mode, FILE *restrict f)
{
    if (f->flags & F_INUSE)
        close_stream(f);
    return open_into(f, path, mode);
}

int setvbuf(FILE *restrict f, char *restrict buf, int mode, size_t size)
{
    if (f->mode)
        return -1;              /* only before the first I/O */
    f->flags &= ~(F_LINEBUF | F_UNBUF);
    if (mode == _IONBF)
        f->flags |= F_UNBUF;
    else if (mode == _IOLBF)
        f->flags |= F_LINEBUF;
    if (buf && size >= 16) {
        if (f->flags & F_OWNBUF)
            free(f->buf);
        f->flags &= ~F_OWNBUF;
        f->buf = (unsigned char *)buf;
        f->size = size;
    }
    return 0;
}

void setbuf(FILE *restrict f, char *restrict buf)
{
    setvbuf(f, buf, buf ? _IOFBF : _IONBF, BUFSIZ);
}

/* ---- positioning and state ---- */

long ftell(FILE *f)
{
    long pos = dos_seek(f->handle, 0, DOS_SEEK_CUR);
    if (pos < 0) {
        __armdos_seterrno(pos);
        return -1;
    }
    if (f->mode == F_READ)
        pos -= (long)(f->len - f->pos);
    else if (f->mode == F_WRITE)
        pos += (long)f->pos;
    if (f->ungot != EOF)
        pos--;
    return pos;
}

int fseek(FILE *f, long offset, int whence)
{
    if (whence == SEEK_CUR) {
        long here = ftell(f);
        if (here < 0)
            return -1;
        offset += here;
        whence = SEEK_SET;
    }
    if (f->mode == F_WRITE && flush_write(f))
        return -1;
    f->mode = 0;
    f->pos = f->len = 0;
    f->ungot = EOF;
    long r = dos_seek(f->handle, offset, whence);
    if (r < 0) {
        __armdos_seterrno(r);
        return -1;
    }
    f->flags &= ~F_EOF;
    return 0;
}

void rewind(FILE *f)
{
    fseek(f, 0, SEEK_SET);
    f->flags &= ~F_ERR;
}

int fgetpos(FILE *restrict f, fpos_t *restrict pos)
{
    long p = ftell(f);
    if (p < 0)
        return -1;
    *pos = p;
    return 0;
}

int fsetpos(FILE *f, const fpos_t *pos) { return fseek(f, *pos, SEEK_SET); }
int feof(FILE *f) { return (f->flags & F_EOF) != 0; }
int ferror(FILE *f) { return (f->flags & F_ERR) != 0; }
void clearerr(FILE *f) { f->flags &= ~(F_EOF | F_ERR); }
int fileno(FILE *f) { return f->handle; }

int remove(const char *path)
{
    long r = dos_delete(path);
    return r < 0 ? __armdos_seterrno(r) : 0;
}

int rename(const char *from, const char *to)
{
    long r = dos_rename(from, to);
    return r < 0 ? __armdos_seterrno(r) : 0;
}

void perror(const char *s)
{
    if (s && *s) {
        fputs(s, stderr);
        fputs(": ", stderr);
    }
    fputs(strerror(errno), stderr);
    fputc('\n', stderr);
}
