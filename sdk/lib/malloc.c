/* SPDX-License-Identifier: MIT */
/*
 * malloc/free/realloc on DOS memory blocks (48h).
 *
 * 48h hands out owned blocks in 64 KiB granules, at most 16 MiB each and 64
 * blocks for the whole system, so the heap asks for few, growing blocks
 * (256 KiB, then doubling up to 16 MiB) and carves them with an
 * address-ordered free list that coalesces neighbours (in the style of the
 * classic K&R allocator). Every block is released by the kernel when the
 * program ends, so nothing is returned to DOS earlier.
 *
 * Each chunk starts with a 16-byte header; user pointers are 16-byte
 * aligned. Not thread safe (there are no threads).
 */
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <armdos.h>

typedef struct chunk {
    struct chunk *next;         /* free list link (free chunks only) */
    size_t units;               /* chunk size in 16-byte units, header included */
} chunk;

_Static_assert(sizeof(chunk) == 16, "chunk header is 16 bytes");

#define UNIT 16
#define MAX_BLOCK (16ul << 20)  /* 48h limit */
#define FIRST_BLOCK (256ul << 10)

static chunk base;              /* zero-size list head */
static chunk *freep;
static size_t next_block = FIRST_BLOCK;

/* Inserts chunk c into the address-ordered free list, merging neighbours. */
static void insert_free(chunk *c)
{
    chunk *p = freep;
    while (!(c > p && c < p->next)) {
        if (p >= p->next && (c > p || c < p->next))
            break;              /* at the wrap-around point */
        p = p->next;
    }
    if (c + c->units == p->next) {
        c->units += p->next->units;
        c->next = p->next->next;
    } else {
        c->next = p->next;
    }
    if (p + p->units == c) {
        p->units += c->units;
        p->next = c->next;
    } else {
        p->next = c;
    }
    freep = p;
}

static int grow(size_t units)
{
    size_t need = units * UNIT;
    size_t size = next_block;
    if (size < need)
        size = (need + 0xffff) & ~(size_t)0xffff;
    if (size > MAX_BLOCK) {
        if (need > MAX_BLOCK)
            return 0;
        size = MAX_BLOCK;
    }
    void *block = dos_alloc(size);
    if (!block) {
        /* Memory is tight: try exactly what this request needs. */
        size = (need + 0xffff) & ~(size_t)0xffff;
        block = dos_alloc(size);
        if (!block)
            return 0;
    } else if (next_block < MAX_BLOCK) {
        next_block *= 2;
    }
    chunk *c = block;
    c->units = size / UNIT;
    insert_free(c);
    return 1;
}

void *malloc(size_t size)
{
    if (size == 0)
        size = 1;
    if (size > MAX_BLOCK) {
        errno = ENOMEM;
        return NULL;
    }
    size_t units = (size + UNIT - 1) / UNIT + 1;
    if (!freep) {
        base.next = freep = &base;
        base.units = 0;
    }
    for (int attempt = 0; attempt < 2; attempt++) {
        chunk *prev = freep;
        for (chunk *c = prev->next;; prev = c, c = c->next) {
            if (c->units >= units) {
                if (c->units == units) {
                    prev->next = c->next;
                } else {
                    /* Hand out the tail; the head stays on the list. */
                    c->units -= units;
                    c += c->units;
                    c->units = units;
                }
                freep = prev;
                c->next = NULL;
                return c + 1;
            }
            if (c == freep)
                break;          /* wrapped around: nothing fits */
        }
        if (!grow(units))
            break;
    }
    errno = ENOMEM;
    return NULL;
}

void free(void *ptr)
{
    if (!ptr)
        return;
    insert_free((chunk *)ptr - 1);
}

void *calloc(size_t count, size_t size)
{
    if (size && count > SIZE_MAX / size) {
        errno = ENOMEM;
        return NULL;
    }
    void *p = malloc(count * size);
    if (p)
        memset(p, 0, count * size);
    return p;
}

void *realloc(void *ptr, size_t size)
{
    if (!ptr)
        return malloc(size);
    if (size == 0) {
        free(ptr);
        return NULL;
    }
    chunk *c = (chunk *)ptr - 1;
    size_t have = (c->units - 1) * UNIT;
    if (size <= have) {
        size_t units = (size + UNIT - 1) / UNIT + 1;
        if (c->units - units >= 2) {    /* give back a useful tail */
            chunk *tail = c + units;
            tail->units = c->units - units;
            c->units = units;
            insert_free(tail);
        }
        return ptr;
    }
    void *n = malloc(size);
    if (!n)
        return NULL;
    memcpy(n, ptr, have);
    free(ptr);
    return n;
}
