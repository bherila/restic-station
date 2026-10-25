#ifndef RESTIC_STATION_POSIX_H
#define RESTIC_STATION_POSIX_H

/* Atomically move an entry only if the destination does not exist.
 * Relative operands are resolved through retained directory descriptors. */
int rs_sync_rename_exclusive(int source_directory, const char *source,
                             int target_directory, const char *target);

#endif
