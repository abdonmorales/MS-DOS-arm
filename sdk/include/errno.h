/* SPDX-License-Identifier: MIT */
/* errno values (numbered as on Linux, so host tools agree). The library
 * maps DOS error codes onto these; _doserrno keeps the original code. */
#ifndef _ARMDOS_ERRNO_H
#define _ARMDOS_ERRNO_H
#ifdef __cplusplus
extern "C" {
#endif
extern int errno;
extern int _doserrno;
/* Sets errno (and _doserrno) from a DOS error code; returns -1. */
int __armdos_seterrno(long doserror);
#define EPERM    1
#define ENOENT   2
#define ESRCH    3
#define EINTR    4
#define EIO      5
#define ENXIO    6
#define E2BIG    7
#define ENOEXEC  8
#define EBADF    9
#define ECHILD  10
#define EAGAIN  11
#define ENOMEM  12
#define EACCES  13
#define EFAULT  14
#define EBUSY   16
#define EEXIST  17
#define EXDEV   18
#define ENODEV  19
#define ENOTDIR 20
#define EISDIR  21
#define EINVAL  22
#define ENFILE  23
#define EMFILE  24
#define ENOTTY  25
#define EFBIG   27
#define ENOSPC  28
#define ESPIPE  29
#define EROFS   30
#define EDOM    33
#define ERANGE  34
#define EDEADLK 35
#define ENOSYS  38
#define ENOTEMPTY 39
#ifdef __cplusplus
}
#endif
#endif
