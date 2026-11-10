# Source synchronization and backup

Implementation contract for #194 / #195. This is an opt-in addition to a
backup set, with **independent backup and synchronization selections**.

## Scope and interface

The editor has a normal Sources section and an optional Keep in sync
section. A set may back up `/workspace` while synchronizing only
`/workspace/shared-notes` with another copy. Selecting a backup source never
selects it for synchronization. Adding a sync folder never replaces,
narrows, moves, or expands the configured backup sources.

The primary action for a configured set is Sync & Back Up. Its preview
summarizes both scopes explicitly. Copy IDs, coordinator identity and
protocol details are implementation state, not required normal setup
fields. Existing backup-only sets retain Back Up Now and their behavior.

Initial support is manual, coordinated by one explicitly identified
computer, for two local directories or one local directory and one SSH
directory. Additional copies and remote-only placement remain later
milestones; this initial implementation does not claim those capabilities.

Each root's parent must be owned and writable by the endpoint user so the
helper can keep private sibling recovery storage on the same filesystem.
Choose a folder inside the user's home or another user-managed directory;
volume roots and folders directly under system-owned parents are refused.
Read-only directory trees can be exported and copied into a writable
replica: new directories stay owner-writable during construction and get
their exact planned modes after descendants are installed. Existing live
directories are never silently made writable. A change beneath an existing
read-only target directory refuses before capture; make that target writable
before retrying. Private staging is made writable only for construction and
cleanup, independently of the live source permissions.

**Permissions.** Every entry must be owned by the user running sync and
writable by no one else, group included: a sync folder with group or other
write is refused, naming the entry (#197). Group write is common under
umask 002 (the default on distributions with user-private groups, which
create files 0664), and is refused anyway, deliberately. The mode would be
copied to the other computer but not the group, so the copy could end up
writable by whatever group that computer gives new files; a group-writable
parent would let a member move the private recovery storage aside; and a
member could swap an entry between scan and install. The remedy is once,
`chmod -R go-w` on the folder, and creating files with umask 022 afterwards.
Each computer applies the rule to its own folder.

**Size over SSH.** The other computer's helper reads each request from SSH
up to 64 MiB. Only `prepare` carries a copy's full inventory, and a request
names just the entries it replaces or removes, so the limit holds a few
hundred thousand files (roughly 175 bytes each, compactly encoded). Before
#197 each request was pretty-printed, carried the inventory twice, and the
limit was 32 MiB, about 80,000 files. Preview measures the real prepare
request and refuses a folder over the limit, before anything is reserved,
with a message saying so. A helper from before #197 on the other computer
still reads 32 MiB, and the message says that updating it raises the limit.
Local-to-local sync has no such cap.

**Free space.** A first sync of a large folder needs several temporary
copies, so preview estimates the need from the plan and refuses, before
anything is reserved, when a place is known to lack it, naming each place
with the amount needed and the amount free. The estimate counts file bytes
plus ten percent and 64 MiB, per volume: the coordinating computer's
Restic Station data holds the vault and, with protection, two verification
restores (three times the vault; two times without protection), and each
folder's volume holds what that copy exports and receives in its private
sibling storage. Moved-aside versions are renames and need no more. A
computer that cannot report its free space (a helper from before #197, or a
filesystem that will not say) is not blocked, since unknown is not full, and
a plan with nothing to copy needs none. The estimate is made at preview;
space used by something else before apply can still run a sync out of room,
which is recoverable like any interrupted operation.

**Re-enrolling after an identity change.** If a sync folder is restored from
a backup, migrated, or loses its private control directory, sync refuses
("a folder or its settings changed", "identity or coordinating set changed",
or "endpoint state is missing") rather than guess which copy is right. To
start over deliberately: first resolve anything pending (`sync status`;
`sync recover`, or `sync recover --cancel-unstarted`); then, with nothing
running, remove the group's state on the coordinating computer
(`source-sync/<group id>` inside the helper's data directory) and, on each
computer, the folder's private control directory
(`.restic-station-sync-*` beside the folder, which also holds any recovery
copies of replaced files; move out anything you want first, since protection
snapshots remain in the backup repository either way). The next preview is a
first run: identical paths agree, a path on only one copy is offered for
copying, and a path that differs conflicts, so no copy is chosen for you and
nothing is deleted. Make differing files agree, then apply.

**Metadata that is not synchronized.** Contents, types, link targets and
permission bits are carried; extended attributes (Finder tags, quarantine
flags, custom attributes) and ACLs are not, so a synced copy loses them, and
the other copy keeps its own. Modification times are carried in whole seconds
when either computer uses openrsync (protocol 29), which has no sub-second
times. Times never decide a winner either way.

The first version requires `retention: null` and no purge exclusions on a
sync-enabled set. It must exclusively own its backup repositories: no
other set, independently configured computer, external retention tool, or
alternate URL may delete or rewrite its recovery snapshots. Config
validation rejects literal repository sharing across shared URLs and every
machine override, including disabled profiles; it cannot discover aliases
managed outside this configuration. This conservative limit keeps verified
recovery snapshots available across the source commit. Retention-aware
snapshot pins are a later extension, not an implied guarantee today.

## Agreement and first run

The coordinator remembers the last verified common inventory. A scan binds
to the actual root inode and records content hashes, types, link targets
and permissions. Timestamps are scan optimizations, never winner selection.
Changing root identity, configuration, or losing/corrupting a baseline
requires reconciliation; an unreadable directory is never an empty tree.
Each endpoint keeps the previous scan's file digests in its private control
directory (`hashes.json`) and reuses one only while the file's whole stat
stamp (device, inode, size, mode, modification and change time) is
unchanged. A write, truncate, rename or relink moves the change time,
which an ordinary user cannot set back. A file changed within two seconds of
a scan is never recorded, because a coarse-timestamp filesystem could hide a
write in that tick. A missing or unreadable cache means hashing everything.
Inventories of private staging, vaults and verification restores never use
it. Known gaps, shared with git and restic: a writer through a shared memory
map can change contents before the times move, and a clock stepped backwards
(or a network filesystem whose server clock lags) can make a recent change
look settled. Neither can authorize a replacement or deletion, because every
version an operation replaces or deletes is hashed again without the cache
before it is captured; at worst such an edit elsewhere is noticed one sync
later, or the plan refuses until the mapping is released.
Root identity includes filesystem creation metadata as well as device and
inode, so inode reuse cannot disguise a recreated folder as deletion of its
contents. Filesystems/kernels without creation metadata refuse sync; ordinary
backup remains available. Linux uses the birth-time field of `statx`.

On the first run, identical paths already agree and unique new paths can
be offered for copying. Different contents at the same path conflict.
There is no automatically preferred computer. A directory/type conflict
blocks transfers below that path. One-sided deletions after an established
baseline are explicit operations; delete-versus-edit conflicts preserve
both sides. Renames are initially represented as delete/create.

## What a sync covers

A sync covers what the set's backup covers, as far as a path below the sync
folder decides it (#202). An entry the backup excludes, such as a
`__pycache__` named by the global catalogue, is outside the sync: it is not
copied, not counted as a conflict, and never deleted. Each copy keeps its own
version. Without this, a regenerated cache that differed between the copies
was planned like any file, the protection backup left it out, and
verification refused every sync until someone deleted it by hand.

The scope is the backup's own `--exclude` and `--iexclude` lists for this
set on the coordinating computer, after the catalogue patterns held back for
swallowing a source. Only patterns that a relative path decides exactly as
restic does narrow it: literal components, `*`, `?` and `**`, and for the
case-insensitive list ASCII only, folded A–Z only (restic folds with Go's
rules, which differ from Swift's for some letters). Anchored
patterns, environment variables, character classes and escapes are ignored,
which keeps their paths in scope, and any negation anywhere disables the
scope, since a later `!pattern` can re-include what another excluded.
`--exclude-caches`, `--exclude-larger-than` and online-only files cannot be
decided from a path at all. All of these keep the earlier behavior:
protection verification refuses an excluded payload. A pattern is matched
only against components below the sync folder. A run of those is also inside
the live path and the protection vault's path, so whatever the scope leaves
out, both backups leave out too. The other computer's own exclusions play no
part, because only the coordinator backs up the payload.

Both endpoints apply the scope themselves, skipping excluded entries without
reading, hashing or descending into them, and report the topmost ones. The
preview counts them once across both copies (`excluded`) and names the first
ten with `--include-paths` (`excludedPaths`). The plan records the scope,
and each endpoint binds it at prepare, so every later inventory of the
operation means the same thing. The configuration binding does not cover
this host's `global-excludes.json`, so apply derives the scope again and
refuses a changed one as stale, and a resume before installation refuses it
too, naming `--cancel-unstarted`. An endpoint whose helper predates the scope
ignores it, so the coordinator requires each reply to echo it. With anything
excluded, a sync with an older helper on the other computer refuses until
that helper is updated. With nothing excluded, the two still work together
as before.

Two cases would touch an entry the plan cannot see, and both conflict. One
is removing a directory that holds excluded entries on the copy it is
removed from: those entries are not in the protection backup, and removal
would discard them. Such a conflict carries a `reason` naming the entry.
Each endpoint refuses the removal again at prepare and once more at commit,
before anything moves, if such an entry appeared since the preview; the
error names it, and once it is moved out of the folder the operation
resumes. The other is a path whose name differs only by case or
normalization from an excluded entry on either copy, also with a `reason`.
An agreed path that
leaves the scope plans nothing. The next agreement no longer lists it, so if
it returns to scope it is reconciled as on a first run: copied where it is
missing, never deleted.

## Concurrency and durability

The coordinator serializes each group locally. Each endpoint additionally
serializes its root and stores a durable, operation-scoped reservation.
Reservations do not expire automatically: a dead coordinator cannot hand a
partially applied operation to another writer merely because a clock moved.
Recovery must inspect its journal and endpoint receipts. Changing the
coordinator requires explicitly reconciling pending work.

Endpoint commits use retained directory descriptors and no-follow,
relative-path operations. A checked path lookup followed by an unrelated
pathname write is not evidence binding. Before replacing a file, capture
the actual displaced entry in a private recovery location and verify it
against the protected version. Installation must not overwrite an entry
another writer created during that handoff. Unexpected entries remain
recoverable and the run needs attention; they are never unlinked to make a
retry appear successful.

Normal editors do not honor Restic Station's locks. The manual workflow
requires writers to be quiescent during apply; this is not application or
database replication and does not promise a multi-file transaction.
Changes noticed during scanning, protection, transfer or commit invalidate
the corresponding plan. Recovery retains captured versions rather than
assuming a rejected operation left every pathname unchanged.

Write operation intent before changing data, check file and directory
synchronization at authoritative boundaries, and write receipts after
verified installation. An indeterminate result is a recovery state. Advance
only agreement actually verified at both endpoints; never silently discard
a journal or infer success from a child process exit alone.

## Protection without changing the backup selection

The linked set still backs up all its configured sources. Before destructive
replacement, preserve the exact versions at risk from **both** copies.
Private transfer/recovery staging is outside the live sync roots and is
never another ordinary sync source. Protection may include a narrowly
defined internal recovery source in that run's snapshot in addition to
the complete configured source list; it must not turn a small protection
snapshot into an apparent successful backup of the whole set.

Only versions an operation would replace or delete are at risk. A plan
that only creates entries absent from both copies displaces nothing, so it
runs no protection backup or verification restore; each endpoint still
refuses to install any operation that has a prior value without a receipt.
The final backup records and restore-verifies that operation's vault either
way, so such a plan's `recovery.json` first reaches the repository with the
final backup.

Without a protection backup, nothing would test the backup destination
before either copy changed. So before any endpoint prepares, such a plan
asks the primary repository for its identity (`cat config`): no backup, no
restore, no snapshot (#204), bounded at 10 seconds like the reachability
probe. If the repository does not answer with a well-formed ID in time,
apply refuses with `restic_failed`, and neither folder changes. A missing
secret or a restic that cannot launch refuses with its own error instead.
Either way the operation stays in its reservation phase. It can be resumed
once the repository answers, which checks again, or cancelled with
`--cancel-unstarted`, which is the way out when the fix changes settings. The check authorizes nothing; the final backup remains
the proof. Mirrors are not checked up front, and one that is down does not
stop the sync (see below). A plan with protection skips the check, because
its protection backup already exercises the destination before installation.

Coverage is an exact repository/snapshot/version proof, not last-backup
time. An excluded payload is not covered. Verify protected content through
the existing guarded Restic interfaces before authorizing replacement;
retain enough origin and restore mapping to recover remote-only versions.
Existing verified coverage may be reused when it still proves those exact
versions. Repository retention/purge invariants remain unchanged.
Each protection and final backup names the newest snapshot of this host
that covers every configured source as restic's `--parent`. The vault path
is unique per operation, so restic's own host-and-paths match would never
find one and every sync would re-read the whole backup scope. The vault is
never in a parent, so it is always read in full; without a usable parent
the backup still runs, only slower.
The protection receipt records the actual repository ID as well as the
exact snapshot ID and manifest fingerprint. Repository identity must match
before backup and after the verification restore, and both IDs remain bound
to the worker's installation journal across retries.

Every operation's encrypted vault includes a `recovery.json` manifest with
the reviewed roots, origin inventories, hashes and transfer decisions.
Before the final backup it also gains `agreement.json`, containing the last
verified common inventory and both endpoint epochs. That final vault is
restored and verified too, so exclusion of recovery metadata blocks cleanup.
Endpoint workers trust the coordinating helper's restore-verified snapshot
attestation over authenticated SSH. They do not receive passwords or query
repositories themselves. A compromised coordinator or SSH account is
outside this boundary; a snapshot-shaped string alone is not a backup proof.

After reconciliation, back up the resulting data and copy snapshots to
the configured secondary repositories. An unreachable sync peer does not
disable ordinary backup of available local data. Sync, primary backup and
each backup mirror have separate outcomes under one user-facing set.

**The primary is the whole proof (#197).** Protection and the final backup
need the restore-verified primary snapshot and nothing from a mirror: every
run against the primary must succeed, and the verification restore must match.
A mirror that is offline, or whose copy fails, does not stop the sync. The
result carries a `warnings` entry naming it, which says it catches up at the
next ordinary backup (restic copies every snapshot the mirror lacks). The
warning appears in the apply and recover results, in `sync status` while an
operation waits, and in the app's review sheet; a destination's own status
dot already shows it as offline or stale. Nothing is deleted from a mirror
by a sync, and a sync set has no retention, so a mirror that missed a backup
is only less complete, never unsafe. A mirror's folder may be absent, such as
a disk that is not plugged in: preview and apply still check that where it
would be does not overlap a sync folder, through its nearest existing
ancestor, and refuse if a path component exists but cannot be resolved, such
as a dangling symlink.

Protected plaintext payloads and restored verification
copies are removed after the final backup through descriptor-relative
private-storage operations. Cancelling an operation before installation also removes its
private verification restores, without changing either source. Captured
versions are checked again first: an unexpected editor
save retains recovery storage and requires attention. Small journals remain
for audit and recovery mapping; live source folders are never cleanup roots.
An interrupted cleanup resumes without replaying synchronization or backup.

Use `sync plan`, `sync apply --preview-token-stdin`, `sync status`, and
`sync recover` on Linux or macOS. A reservation that never entered
installation can be released with `sync recover --cancel-unstarted`, after
both endpoints confirm cancellation. Partly installed work must resume;
reservations never expire. Until installation starts, a changed config
revision, machine settings file or restic executable refuses resume: cancel
and preview again. Once installation has started, recover resumes despite
such changes, provided this set still has no retention or purge rules and
its sync folder is unchanged; the resumed run binds to the current revision.
A missing rsync names its own way out (`rsync_not_found`): this computer's
is found again on every resume, so install it and resume. The other
computer's prepare reply is kept in the journal and checked before the
protection backup, so a reply that named no rsync is cancelled and
previewed again once rsync is installed there. The macOS app presents the same flow under
Sync & Back Up, with an independent Back Up Only action. Scheduled runs
continue backing up the configured sources; synchronization is manual.

## Runtime boundaries and tests

- Refuse missing mounts, root replacement, overlapping copies, unsafe
  relative paths, symlink traversal, unsupported file types and ambiguous
  case/Unicode names before mutation.
- A sync folder is never a Restic repository, inside one, or a parent of
  one, on either computer. Both endpoints recognize the on-disk layout
  (`config` plus `data/`, `index/`, `keys/` and `snapshots/`; `locks/` is
  optional because copies often exclude it) without reading repository
  contents, so the other computer needs no password to refuse it.
  Repositories replicate through `restic copy`, never through folder sync.
- A sync tree stays on one filesystem. Any directory or file whose device
  differs from its parent's (a mounted volume, bind mount or network mount
  inside the folder) refuses inventory. Otherwise a baseline would include
  the mount's contents, and once it was unmounted the empty mount point
  would plan as deletion on the other copy.
- Keep credentials and host identity local; SSH uses pinned host keys and
  bounded connection/keepalive behavior. No shell hooks or arbitrary flags.
- rsync transfers staged payloads; the typed inventory/plan is authoritative.
  Required transfer options must succeed before commit. The child has an
  explicit argument-quoting environment for compatibility with openrsync
  and newer GNU rsync; see the [rsync argument contract](https://www.samba.org/ftp/rsync/rsync.1.html).
- rsync is required on both computers, like restic on the coordinating one.
  Each side runs the first of its package-manager installs and then the
  system copy (macOS: `/opt/homebrew`, `/usr/local`, `/opt/local`, then
  `/usr/bin`; Linux: `/usr/bin`, `/usr/local/bin`, `/bin`), then `PATH`
  (on the other computer, the SSH session's), whose `--version` reports
  protocol 29 or newer. The other computer's helper
  reports its choice on inventory and prepare replies; transfers name it
  with `--rsync-path`, so it need not be on the SSH session's PATH. Preview
  and apply refuse, before anything is reserved or backed up, when either
  computer has none, and say how to install it there. A helper too old to
  report keeps the earlier behavior of running `rsync` from its PATH.
- Which rsync ran is not evidence and is not bound into previews: a
  different or misbehaving rsync can fail a transfer but cannot authorize
  a replacement, because every staged and installed value is verified
  against the typed inventories.
- Transfers across SSH compress (`--compress`). When the other computer
  receives, its live folder is named as `--copy-dest`. With
  `--ignore-times` that folder is never copied from as "unchanged"; it only
  serves as each path's delta basis, so an edit to a large file sends the
  changed blocks. A receiver follows symlinks to its basis and sends the
  basis's block checksums to the sender, so only the other computer
  offers one, reading its own folder for the coordinator that already holds
  authority over it. This computer never offers its files to the other
  computer as a basis (the class of rsync CVE-2024-12086), so files it
  receives arrive whole. macOS's openrsync ignores a basis as a receiver,
  so a Mac on the other side receives deltas only with GNU rsync installed
  (for example `brew install rsync`), which discovery then prefers.
- Preserve modes explicitly and verify them after transfer. Ownership is
  not mapped through numeric IDs between different operating systems.
- Installed files keep their source modification time (whole seconds are
  guaranteed; openrsync's protocol 29 does not carry nanoseconds). Times are
  never identity: a time-only change is not a sync change, and transfers
  always copy rather than trusting rsync's size-and-time check. Extended
  attributes and ACLs are not synchronized.
- Keep journal/control state outside managed roots and Restic repositories.
  Never stage plaintext live data into a cloud-sync directory. Both sync
  folders refuse cloud storage; a set's encrypted local repository may live
  there (for example in iCloud Drive) and is only checked for overlap.
- Use synthetic local/SSH fixtures. Test both directions, ancestor
  conflicts, backup-exclusion refusal, corrupt/lost state, concurrent
  operations, changes at every handoff, cancellation and crashes before
  and after every durable step. Verify actual recovery with disposable
  Restic repositories before enabling live writes.

## Configuration example

Inside a schema-v6 set whose `sources` includes `/workspace`, the optional
selection is independent:

```json
"syncFolders": [{
  "id": "33333333-3333-4333-8333-333333333333",
  "name": "Shared notes",
  "localPath": "/workspace/shared-notes",
  "peer": {
    "path": "/home/user/shared-notes",
    "sshTarget": "sync.example.test",
    "helperPath": "restic-station-helper"
  },
  "coordinatorMachineId": "laptop"
}]
```

The coordinating computer needs Restic Station, rsync, restic and access to
its configured repositories. The other computer needs rsync and a compatible
helper accessible through SSH; it does not need repository passwords.
macOS includes rsync; minimal Linux installs may not (`sudo dnf install
rsync` or `sudo apt install rsync`).
Existing SSH keys and host aliases supply authentication. Verify the host
key through the usual SSH setup before planning. Use `config import` to
review and apply an edited configuration on Linux; the macOS app exposes
these same selections through folder choosers. Machine identity stays in
host-local `machine.json`, outside the folders being synchronized.
