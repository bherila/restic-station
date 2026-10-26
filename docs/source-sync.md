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

Coverage is an exact repository/snapshot/version proof, not last-backup
time. An excluded payload is not covered. Verify protected content through
the existing guarded Restic interfaces before authorizing replacement;
retain enough origin and restore mapping to recover remote-only versions.
Existing verified coverage may be reused when it still proves those exact
versions. Repository retention/purge invariants remain unchanged.
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
the configured secondary repositories. A failed mirror is not full
protection. An unreachable sync peer does not disable ordinary backup of
available local data. Sync, primary backup and each backup mirror have
separate outcomes under one user-facing set.

The final backup must include successful copies to every configured mirror
before cleanup. Protected plaintext payloads and restored verification
copies are then removed through descriptor-relative private-storage
operations. Cancelling an operation before installation also removes its
private verification restores, without changing either source. Captured
versions are checked again first: an unexpected editor
save retains recovery storage and requires attention. Small journals remain
for audit and recovery mapping; live source folders are never cleanup roots.
An interrupted cleanup resumes without replaying synchronization or backup.

Use `sync plan`, `sync apply --preview-token-stdin`, `sync status`, and
`sync recover` on Linux or macOS. A reservation that never entered
installation can be released with `sync recover --cancel-unstarted`, after
both endpoints confirm cancellation. Partly installed work must resume;
reservations never expire. The macOS app presents the same flow under
Sync & Back Up, with an independent Back Up Only action. Scheduled runs
continue backing up the configured sources; synchronization is manual.

## Runtime boundaries and tests

- Refuse missing mounts, root replacement, overlapping copies, unsafe
  relative paths, symlink traversal, unsupported file types and ambiguous
  case/Unicode names before mutation.
- Keep credentials and host identity local; SSH uses pinned host keys and
  bounded connection/keepalive behavior. No shell hooks or arbitrary flags.
- rsync transfers staged payloads; the typed inventory/plan is authoritative.
  Required transfer options must succeed before commit. The child has an
  explicit argument-quoting environment for compatibility with openrsync
  and newer GNU rsync; see the [rsync argument contract](https://www.samba.org/ftp/rsync/rsync.1.html).
- Preserve modes explicitly and verify them after transfer. Ownership is
  not mapped through numeric IDs between different operating systems.
- Installed files keep their source modification time (whole seconds are
  guaranteed; openrsync's protocol 29 does not carry nanoseconds). Times are
  never identity: a time-only change is not a sync change, and transfers
  always copy rather than trusting rsync's size-and-time check. Extended
  attributes and ACLs are not synchronized.
- Keep journal/control state outside managed roots and Restic repositories.
  Never stage plaintext live data into a cloud-sync directory.
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
Existing SSH keys and host aliases supply authentication. Verify the host
key through the usual SSH setup before planning. Use `config import` to
review and apply an edited configuration on Linux; the macOS app exposes
these same selections through folder choosers. Machine identity stays in
host-local `machine.json`, outside the folders being synchronized.
