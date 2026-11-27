/* SPDX-License-Identifier: MIT */
/* HELLO.EXE: the smallest useful ARM DOS C program. Prints its arguments,
 * its environment and a few things it asks DOS for. */
#include <stdio.h>
#include <stdlib.h>
#include <armdos.h>

const char *__armdos_progname = "HELLO";

int main(int argc, char **argv, char **envp)
{
    printf("Hello from C on ARM DOS %d.%02d!\n", dos_version() & 0xff,
           dos_version() >> 8);
    printf("argc=%d\n", argc);
    for (int i = 0; i < argc; i++)
        printf("argv[%d]=[%s]\n", i, argv[i]);
    for (char **e = envp; *e; e++)
        printf("env: %s\n", *e);
    const char *path = getenv("PATH");
    printf("PATH is %s\n", path ? path : "(not set)");

    char cwd[128];
    if (dos_getcwd(0, cwd, sizeof cwd) == 0)
        printf("Current directory: %c:\\%s\n", 'A' + dos_get_drive(), cwd);
    dos_date d;
    dos_get_date(&d);
    printf("Date: %04d-%02d-%02d\n", d.year, d.month, d.day);
    return argc > 1 && argv[1][0] == '!' ? 3 : 0;
}
