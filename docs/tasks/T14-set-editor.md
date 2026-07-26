# T14 — Backup Set list & editor, destination editor

**Size:** L · **Model:** Opus (layout latitude) · **Depends on:** T13, T03 · **Milestone:** M3

## Goal
Full CRUD for backup sets and destinations per `docs/ui-spec.md` §Backup Sets — every control, state, warning, and copy string specified there. This is the biggest UI surface; keep subviews small and previewable.

## Create (`App/Sources/Views/Sets/`)
- `SetListView.swift` — list per ui-spec (columns, badges, next-due via ScheduleMath, empty state, add/delete with the exact confirmation copy).
- `SetEditorView.swift` — form sections: name, sources (NSOpenPanel add, nested/duplicate-path inline warnings), excludes, schedule picker (all four kinds with contextual fields + validation ranges from data-model.md invariants), staleness stepper, retention (optional section with the 7/4/12/2 default suggestion + footnote copy), check policy (toggle + slices + footnote).
- `DestinationTable.swift` — per ui-spec: label/repo/kind badge/PRIMARY tag/status dot + last-synced; primary change confirmation copy; add/edit/remove (remove → also delete keychain items via KeychainClient after confirmation "Removes the destination and its saved password from your keychain. The repository itself is not touched.").
- `DestinationEditorView.swift` (sheet) — kind picker driving the three forms per ui-spec (Local w/ iCloud + /Volumes warnings; S3-compatible form assembling `s3:<endpoint>/<bucket>/<prefix>` with read-only assembled-URL display, keys → `KeychainClient.setSecretEnv`; SFTP/REST/Other raw URL + non-secret env table + secret env table). Password SecureField + generate button + the exact safety copy from ui-spec. *Test connection* → `HelperInvoker.probeRepo` (busy spinner, result states incl. exit-10 → prominent *Initialize repository*). *Initialize* → plain init (primary) or `initSecondary` (progress sheet).
- Editing rules: edits operate on a draft copy; Save → `AppConfig.validate()` → `AppModel.saveConfig()`; validation errors surface inline (map `ConfigError` cases to field-level messages).

## Acceptance criteria
- [ ] Manual E2E (document with screenshots in PR): create a set with a temp local primary → Test connection shows "repository does not exist" → Initialize → succeeds (`<repo>/config` exists) → add local secondary → Initialize from primary → succeeds → Back Up Now (T13 toolbar) → run appears; both repos have 1 snapshot.
- [ ] S3 form assembles the documented R2 URL shape; secret fields round-trip through keychain (verify item exists via `security find-generic-password`).
- [ ] Exactly-one-primary is impossible to violate through the UI; deleting the primary destination is blocked with explanation while secondaries exist.
- [ ] iCloud-path and /Volumes notes appear per ui-spec copy.
- [ ] All ui-spec.md copy strings used verbatim.
