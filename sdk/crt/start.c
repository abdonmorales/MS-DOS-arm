/* SPDX-License-Identifier: MIT */
/*
 * C start-up: command tail -> argc/argv, environment block -> environ,
 * stdio set-up, main(), exit() (which flushes and calls 4Ch).
 */
#include <armdos.h>
#include <stdlib.h>
#include <string.h>

extern int main(int argc, char **argv, char **envp);
void __armdos_stdio_init(void);

char **environ;
static char *empty_environ[1];

/* The descriptor carries no program name. A program may define
 * `const char *__armdos_progname = "NAME";` to give argv[0] a value. (A weak
 * definition, not a weak reference: those go through GOT slots.) */
__attribute__((weak)) const char *__armdos_progname = "";

#define MAX_ARGS 64

/*
 * DOS-style splitting, close to what DOS C compilers did: blanks and tabs
 * separate arguments; "double quotes" group (the quotes are removed); \" is
 * a literal quote; other backslashes are kept as they are (paths!).
 */
static int split_tail(char *s, char **argv, int max)
{
    int argc = 0;
    while (*s) {
        while (*s == ' ' || *s == '\t')
            s++;
        if (!*s)
            break;
        char *out = s;
        if (argc < max)
            argv[argc] = out;
        argc++;
        int quoted = 0;
        while (*s && (quoted || (*s != ' ' && *s != '\t'))) {
            if (s[0] == '\\' && s[1] == '"') {
                *out++ = '"';
                s += 2;
            } else if (*s == '"') {
                quoted = !quoted;
                s++;
            } else {
                *out++ = *s++;
            }
        }
        if (*s)
            s++;
        *out = '\0';
    }
    return argc < max ? argc : max;
}

static char **build_environ(const char *block)
{
    if (!block)
        return empty_environ;
    size_t count = 0, bytes = 0;
    /* Bounded: the kernel's block is 4 KiB; refuse anything absurd. */
    const char *p = block;
    while (*p && bytes < 65536) {
        size_t n = strlen(p) + 1;
        bytes += n;
        p += n;
        count++;
    }
    char **env = malloc((count + 1) * sizeof(char *));
    char *copy = malloc(bytes + 1);
    if (!env || !copy)
        return empty_environ;
    memcpy(copy, block, bytes);
    for (size_t i = 0; i < count; i++) {
        env[i] = copy;
        copy += strlen(copy) + 1;
    }
    env[count] = NULL;
    return env;
}

__attribute__((noreturn)) void __armdos_start(const armdos_descriptor *d)
{
    static char *argv_store[MAX_ARGS + 2];
    __armdos_stdio_init();
    environ = build_environ(d->environment);

    const char *tail = d->command_tail ? d->command_tail : "";
    size_t len = strnlen(tail, 1024);
    char *copy = malloc(len + 1);
    int argc = 0;
    argv_store[argc++] = (char *)(__armdos_progname ? __armdos_progname : "");
    if (copy) {
        memcpy(copy, tail, len);
        copy[len] = '\0';
        argc += split_tail(copy, argv_store + 1, MAX_ARGS);
    }
    argv_store[argc] = NULL;
    exit(main(argc, argv_store, environ));
}
