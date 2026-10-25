#ifndef RESTIC_STATION_POSIX_H
#define RESTIC_STATION_POSIX_H
#include <stdint.h>

/* Atomically move an entry only if the destination does not exist.
 * Relative operands are resolved through retained directory descriptors. */
int rs_sync_rename_exclusive(int source_directory, const char *source,
                             int target_directory, const char *target);

/* Stable directory creation metadata, read through the retained descriptor.
 * Refuses filesystems/kernels that cannot report it. */
int rs_sync_creation_time(int descriptor, int64_t *seconds, int32_t *nanoseconds);

#endif
