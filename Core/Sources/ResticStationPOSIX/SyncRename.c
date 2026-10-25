#include "ResticStationPOSIX.h"
#include <errno.h>
#include <stdio.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#endif

int rs_sync_rename_exclusive(int source_directory, const char *source,
                             int target_directory, const char *target) {
#if defined(__APPLE__)
    return renameatx_np(source_directory, source, target_directory, target,
                        RENAME_EXCL);
#elif defined(__linux__) && defined(SYS_renameat2)
    return (int)syscall(SYS_renameat2, source_directory, source,
                       target_directory, target, 1 /* RENAME_NOREPLACE */);
#else
    errno = ENOTSUP;
    return -1;
#endif
}
