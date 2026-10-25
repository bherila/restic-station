#include "ResticStationPOSIX.h"
#include <errno.h>
#include <stddef.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
/* The static musl SDK does not ship Linux UAPI headers. This is the stable
 * 256-byte statx syscall ABI, with only the requested birth-time fields
 * named. Layout: include/uapi/linux/stat.h in the Linux source tree. */
struct rs_statx_birth {
    uint32_t mask;
    unsigned char prefix[76];
    struct { int64_t seconds; uint32_t nanoseconds; int32_t reserved; } birth;
    unsigned char suffix[160];
};
_Static_assert(sizeof(struct rs_statx_birth) == 256, "statx ABI size");
_Static_assert(offsetof(struct rs_statx_birth, birth) == 0x50, "statx birth offset");
#endif

int rs_sync_creation_time(int descriptor, int64_t *seconds, int32_t *nanoseconds) {
#if defined(__APPLE__)
    struct stat attributes;
    if (fstat(descriptor, &attributes) != 0) return -1;
    *seconds = attributes.st_birthtimespec.tv_sec;
    *nanoseconds = (int32_t)attributes.st_birthtimespec.tv_nsec;
#elif defined(__linux__) && defined(SYS_statx)
    struct rs_statx_birth attributes = {0};
    if (syscall(SYS_statx, descriptor, "", 0x1000 /* AT_EMPTY_PATH */,
                0x800 /* STATX_BTIME */, &attributes) != 0) return -1;
    if (!(attributes.mask & 0x800)) { errno = ENOTSUP; return -1; }
    *seconds = attributes.birth.seconds;
    *nanoseconds = (int32_t)attributes.birth.nanoseconds;
#else
    errno = ENOTSUP;
    return -1;
#endif
    if (*seconds <= 0 || *nanoseconds < 0 || *nanoseconds >= 1000000000) {
        errno = ENOTSUP;
        return -1;
    }
    return 0;
}
