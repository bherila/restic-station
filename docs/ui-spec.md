# UI specification

**This document is macOS-app-only.** Everything below describes `Restic Station.app` — the SwiftUI menu bar app and management window. There is no GUI on Linux; `restic-station-helper`'s CLI is the entire Linux user interface (`docs/linux.md`). Nothing in this file applies to Linux, and nothing on Linux is expected to match anything described here.

This spec fixes **information architecture, controls, states, and copy**. Visual layout, spacing, and composition are left to the implementing agent's judgment — build idiomatic macOS SwiftUI (forms, tables, inspectors, sheets) that would feel at home next to System Settings. Use SF Symbols throughout. Support light + dark mode (automatic — no custom colors that break either).

## Shell

- `NavigationSplitView`. Sidebar sections: **Backup Sets**, **Runs**, **Restore**, **Maintenance**, **Settings** (Settings also reachable via the standard ⌘, Settings scene).
- Window title "Restic Station". Min size ~ 900×560.
- `AppModel` (ObservableObject, injected via environment) owns: `AppConfig` (via ConfigStore), live state (via StateWatcher), and helper invocation. All mutations go config-edit → save → (if schedule-relevant) kickstart tick.

## Menu bar (`MenuBarExtra`, style `.menu`, `isInserted:` bound to `showMenuBarIcon`)

Icon (template, SF Symbols):
- Idle/healthy: `externaldrive.badge.checkmark`
- Running: `externaldrive.badge.timemachine` (any run in flight)
- Warning: `externaldrive.badge.exclamationmark` (last run of any set failed, OR any destination stale, OR a first backup is overdue, OR FDA/agent problem)

Menu content (top to bottom):
1. One line per set (disabled item): `"<SetName> — <relative last backup> <✓|⚠|✕>"`, e.g. "Projects — 2 hours ago ✓". Never run: "Projects — never backed up".
2. If a run is in flight: `"Backing up <SetName>… 42%"` (disabled, updates on menu reopen — NSMenu items don't live-update reliably while open; accepted).
3. Divider. `Back Up Now ▸` submenu with one item per set (disabled while that set is running/busy).
4. Divider. `Open Restic Station` (activates app, opens main window), `Quit Restic Station`.

Quitting the app does NOT stop scheduled backups (they're launchd's job) — the Quit item's tooltip/help says so.

## Backup Sets

**List** (sidebar selection → content): table/list of sets: name, source count, primary destination label + kind icon, schedule summary ("Daily 02:30"), last run status badge, next due time (via ScheduleMath, display only). Toolbar: add set, delete set (confirmation: "Deletes the backup set configuration. Repositories and snapshots are NOT touched."). Empty state: short explainer + "Create your first backup set".

The toolbar's **Effective Plan** sheet lists the union of machine IDs referenced anywhere in `config.json`, plus this host's `machineId`. Picking a machine previews every effective source, schedule, repository URL, enabled destination, and exclusion reason. This is a preview of the shared configuration only; it never changes the host-local `machine.json`.

**Set editor** (form):
- Name.
- **Sources**: list of absolute paths; add via `NSOpenPanel` (directories + files, multi-select), remove; warn inline (yellow) on nested/duplicate paths.
- **Excludes**: editable string list; caption linking restic exclude-pattern syntax (`https://restic.readthedocs.io/en/stable/040_backup.html#excluding-files`).
- **Purge Excludes**: separate editable string list using the same restic exclude-pattern syntax. Empty state: "Nothing is marked for removal from existing snapshots." Footer: "Purge excludes are reserved to remove matching files from existing snapshots. They are also excluded from new backups. Space is not reclaimed until a prune runs." A blank pattern surfaces inline: "Remove the blank pattern — every entry here must be a real path or glob."
- **Schedule**: picker for kind (Every N minutes / Hourly / Daily / Weekly) with contextual fields (N stepper ≥5; minute; hour+minute; weekday+hour+minute).
- **Machine overrides**: choose any known machine profile or add a valid machine ID, then inherit/enable/disable the set and optionally replace its complete sources list or schedule. Replacement arrays are labeled as replace-not-merge. Removing an override restores inheritance.
- **Staleness warning**: stepper, days, default 14.
- **Retention** (optional section, off = never forget): steppers/optional fields for keep-last/hourly/daily/weekly/monthly/yearly; default suggestion when enabling: 7 daily / 4 weekly / 12 monthly / 2 yearly. Footnote: "Applied to the primary after each backup, and mirrored to each secondary after it syncs."
- **Integrity checks** (optional): toggle + slice count (default 20). Footnote: "Weekly `restic check`; over 20 weeks the entire repository's data is read and verified."
- **Destinations**: table (label, repo, kind badge, PRIMARY tag, status dot reachable/offline/stale + "last synced N days ago"). Exactly-one-primary enforced by radio-style selection; changing primary shows an explanatory confirmation (new primary must already contain the data or the next backup re-uploads everything).
  - **Destination editor** (sheet): label; kind picker driving the form:
    - **Machine overrides**: inherit/enable/disable this destination and optionally replace its complete repository URL or non-secret environment dictionary. Secret environment values and passwords stay in the local secret store and are never copied into shared config.
    - *Local folder*: path picker; inline warning if under `~/Library/Mobile Documents` ("iCloud may evict repository files with Optimize Mac Storage — this can corrupt reads; consider a non-synced location. Sync folders replicate deletions — treat this as a convenience copy, not your only backup."); note when under `/Volumes` ("Removable volume — will be skipped when not mounted" — for secondaries this is normal).
    - *S3-compatible*: endpoint URL (placeholder `https://<accountid>.r2.cloudflarestorage.com` / empty = AWS), bucket, path prefix, region (optional, "auto" hint for R2), Access Key ID (→ keychain env blob), Secret Access Key (SecureField → keychain env blob). The form assembles `repoURL = s3:<endpoint>/<bucket>/<prefix>`; show the assembled URL read-only.
    - *SFTP / REST / Other*: raw repo URL field + free-form non-secret env key/value table + secret env key/value table (values in SecureFields → keychain blob). Caption: "Anything restic accepts after `-r`." SFTP additionally offers remote maintenance settings and a *Test remote maintenance* action; remote prune is opt-in and uses SSH stdin for the password.
    - Repository password: SecureField + "generate" button (32 random chars) + **prominent copy**: "Store this password somewhere safe outside this Mac. Without it the backup is unreadable. Restic Station keeps it in your login keychain only."
    - Buttons: *Test connection* (probe-repo via helper; spinner → reachable/version or error), *Initialize repository* (primary: plain init; secondary: init --from-repo primary --copy-chunker-params via helper `init-secondary`, progress sheet). If probe says "repo does not exist" (exit 10), surface Initialize prominently.
  - Adding a secondary when it's not initialized → offer initialization; a secondary that was never initialized shows an error badge.

## Runs

- **List**: newest-first, grouped by `groupId` (a scheduled run shows backup + its copies/prunes nested). Columns: time, set, kind icon, destination, status badge, duration, data added. Filter bar: set, kind, status. A `running` run shows a progress bar fed by `current-run-<setId>.json`.
- **Detail**: metadata header (status, trigger, snapshot id monospaced+copyable, files new/changed/unmodified, data added (packed), total processed, duration); scrolling monospaced log view — tail -f while running (re-read on StateWatcher events), full content when finished. "Reveal log in Finder" button.
- Toolbar: **Back Up Now** (per-set picker or context), disabled with explanation while that set is busy.

## Restore

Flow: pick destination (any repo, incl. secondaries — grouped picker "Set ▸ Destination") → snapshot list (`snapshots --json`, newest first: time, short id, paths summary, data added; copied snapshots show "mirrored" badge via `original`) → **browser**: lazy expandable tree starting at `/` via `ls --json` (folder icons, name, size, mtime; expand loads children on demand); multi-select; breadcrumb path.
- **Search** field above the browser: runs `find --json` (default: within the selected snapshot; toggle "search all snapshots"); results list (path, size, snapshot) → select for restore.
- **Restore action** (sheet):
  - Target: "Original location" or "Choose folder…" (NSOpenPanel).
  - Overwrite mode picker mapping to `--overwrite`: Always / Only if changed / Only if newer / Never overwrite. Default **Always**.
  - If target = original location: warning banner "Files at the original location will be overwritten." + inline suggestion with button: "Consider backing up first — Back Up Now". Restoring to a chosen empty folder shows no warning.
  - Runs helper `restore`; progress from status NDJSON; completion shows files/bytes restored + "Reveal in Finder".
- **Mount** section: if macFUSE present (`/Library/Filesystems/macfuse.fs`): "Mount snapshot browser" button → `restic mount` child process, path shown + "Show in Finder" + "Unmount". If absent: disabled card: "Mounting requires macFUSE (macfuse.github.io). You can browse and restore without it." Mount is per-destination, one at a time.

## Maintenance

Per set (picker or sections):
- **Repository size cards** per destination: raw-data total_size ("on disk"), restore-size ("protected data"), snapshot count; Refresh button (stats are cached in-memory per app session, cheap staleness).
- **Retention and space**: shows the set's policy (edit jumps to set editor); **Preview cleanup** (forget --dry-run → keep/remove table); **Apply retention now** is **disabled in this build** (containment for #111/#82 — see below); its affordance is greyed with the posture explanation both as tooltip and as a visible caption in the section. When re-enabled it presents a confirmation listing counts from a dry-run first ("This will permanently delete N snapshots from <dest>."; then helper `run-set --kind prune`). **Reclaim space** first runs an unrecorded read-only `maintenance prune --dry-run` and then, in the same destructive-confirmation flow, runs `maintenance prune`; it never changes retention and is available even when the set has no `RetentionPolicy`. A destination under `~/Library/Mobile Documents` repeats the iCloud warning: fully materialize every pack locally before pruning, because prune downloads and re-uploads rewritten packs. When `purgeExcludes` are pending, an orange purge-plan warning names the pending destinations and explains that rewrite removes historical file data but reclaiming pack space is a separate step.

> **Manual retention apply is contained.** `ManualRetentionApplyAvailability.isEnabled` is `false`, and the helper refuses `run-set --kind prune` before it builds a context — no config load, no restic hashing, no secret read, no lock, no run record, no subprocess. Core's `BackupEngine.runPrune` refuses independently for direct callers. The reason: the manual path proves mirror freshness from a persisted wall-clock comparison (#111) and forwards no exact keep/remove plan to the helper (#82), so it can apply a policy to repository state the operator never reviewed. Scheduled retention inside `runSet` has neither defect — it prunes a mirror only when *this run's* copy to it succeeded, and it orders secondaries before the primary — and stays enabled. **Preview cleanup remains available; it is read-only.** The cost is timing, not capability: a behind mirror was already refused by the manual path's own freshness guard, and a caught-up one is cleaned after its next successful scheduled copy. Re-enabling is the joint acceptance criterion for #111 and #82.

- **Integrity**: last check result + date per destination; **Check now** (structure-only toggle vs with-data-slice); shows slice cursor progress "verified slices 7/20".
- **Staleness**: per-destination "last synced" with stale highlighting.
- **Unlock**: small footer utility "Repository reports locked? Remove stale locks" → helper runs `restic unlock` (safe: only removes locks of dead processes).

## Settings

- **General**: show menu-bar icon toggle; launch at login note (the *agent* runs regardless; this is only about the app UI).
- **restic binary**: discovered path + version chip; "Locate manually…" file picker; states: OK (green, "restic 0.18.1"), too old (yellow, "0.16 found — 0.17+ required"), missing (red, "Install with `brew install restic`").
- **Permissions & background**:
  - FDA card: two badges — App: granted/denied; Background agent: granted/denied/unknown (from `fda-check.json`; "Re-check" button kickstarts the helper). "Open Full Disk Access settings" button (deep link). Help disclosure with the fallback instructions (add helper binary manually — path shown, copyable).
  - Background agent card: SMAppService status (Enabled → "Remove" button / Requires approval → "Open Login Items settings" button / Not registered → "Enable" button). Removal is refused while a backup is in flight. A pre-registration `.notFound` is presented as Not registered when the embedded plist is present; a genuinely missing plist remains Not found with reinstall guidance. Caption: "Runs backups on schedule even when Restic Station is closed."

## Onboarding (first launch, no config)

Sheet/wizard, 4 steps, skippable except where noted: 1) Welcome + restic discovery (blocks if restic missing — install instructions); 2) Enable background agent (SMAppService register + approval guidance); 3) Grant Full Disk Access (both probes, live-updating badges); 4) "Create your first backup set" → opens set editor. Re-runnable from Settings → "Setup assistant…".

## Copy/tone rules

Plain, specific, no jargon-for-jargon's-sake; restic terms (snapshot, repository, prune) are used and briefly explained in captions on first use per screen. Destructive confirmations state exactly what is and is not deleted. Every error surfaced to the user includes: what failed (set/destination), the mapped reason (from ResticError), and one next step.
