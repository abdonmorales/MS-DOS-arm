/* SPDX-License-Identifier: MIT */
/* Host check of tests/printf_cases.h against the host C library (sdk_test.py). */
#include <stdio.h>
#include <string.h>
#include <stddef.h>
int main(void)
{
    char buf[256];
    int bad = 0, n = 0;
#define CASE(expected, ...) \
    n++; snprintf(buf, sizeof buf, __VA_ARGS__); \
    if (strcmp(buf, expected)) { printf("host mismatch: %s -> [%s] want [%s]\n", #__VA_ARGS__, buf, expected); bad++; }
#include "printf_cases.h"
    printf("%d host printf cases, %d mismatches\n", n, bad);
    return bad != 0;
}
