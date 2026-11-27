/* SPDX-License-Identifier: MIT */
/* DOS error codes -> errno, and strerror/perror text. */
#include <errno.h>
#include <string.h>
#include <armdos.h>

int errno;
int _doserrno;

static int map(long code)
{
    switch (code) {
    case DOSERR_INVALID_FUNCTION:   return ENOSYS;
    case DOSERR_FILE_NOT_FOUND:
    case DOSERR_PATH_NOT_FOUND:
    case DOSERR_NO_MORE_FILES:      return ENOENT;
    case DOSERR_TOO_MANY_OPEN:      return EMFILE;
    case DOSERR_ACCESS_DENIED:
    case DOSERR_SHARING:
    case DOSERR_LOCK:
    case DOSERR_CANNOT_MAKE:        return EACCES;
    case DOSERR_INVALID_HANDLE:     return EBADF;
    case DOSERR_NO_MEMORY:          return ENOMEM;
    case DOSERR_INVALID_BLOCK:      return EFAULT;
    case DOSERR_BAD_ENVIRONMENT:    return E2BIG;
    case DOSERR_BAD_FORMAT:         return ENOEXEC;
    case DOSERR_INVALID_DRIVE:      return ENODEV;
    case DOSERR_CURRENT_DIRECTORY:  return EBUSY;
    case DOSERR_NOT_SAME_DEVICE:    return EXDEV;
    case DOSERR_WRITE_PROTECT:      return EROFS;
    case DOSERR_NOT_READY:
    case DOSERR_DISK_CHANGE:        return EIO;
    case DOSERR_FILE_EXISTS:        return EEXIST;
    default:                        return EINVAL;
    }
}

int __armdos_seterrno(long doserror)
{
    if (doserror < 0)
        doserror = -doserror;
    _doserrno = (int)doserror;
    errno = map(doserror);
    return -1;
}

char *strerror(int e)
{
    switch (e) {
    case 0:       return "No error";
    case EPERM:   return "Operation not permitted";
    case ENOENT:  return "No such file or directory";
    case EIO:     return "I/O error";
    case E2BIG:   return "Argument list too long";
    case ENOEXEC: return "Exec format error";
    case EBADF:   return "Bad file handle";
    case ENOMEM:  return "Not enough memory";
    case EACCES:  return "Access denied";
    case EFAULT:  return "Bad address";
    case EBUSY:   return "Resource busy";
    case EEXIST:  return "File exists";
    case EXDEV:   return "Not the same drive";
    case ENODEV:  return "Invalid drive";
    case ENOTDIR: return "Not a directory";
    case EISDIR:  return "Is a directory";
    case EINVAL:  return "Invalid argument";
    case EMFILE:  return "Too many open files";
    case ENOSPC:  return "Disk full";
    case ESPIPE:  return "Illegal seek";
    case EROFS:   return "Write-protected disk";
    case EDOM:    return "Domain error";
    case ERANGE:  return "Result out of range";
    case ENOSYS:  return "Function not supported";
    default:      return "Unknown error";
    }
}
